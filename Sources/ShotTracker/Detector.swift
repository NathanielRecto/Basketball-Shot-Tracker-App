import Accelerate
import CoreML
import CoreVideo
import Foundation
import QuartzCore
import ShotCore

/// Detector v2 in Core ML: letterbox the camera frame like Ultralytics, run the raw head, decode it with
/// `ShotCore.YOLODecoder` (same thresholds and NMS as the Python pipeline). Not thread-safe: use one queue.
final class Detector {
    enum DetectorError: LocalizedError {
        case missingModel(String)
        case unexpectedModel(String)
        case pixelBuffer(CVReturn)
        case scale(vImage_Error)

        var errorDescription: String? {
            switch self {
            case .missingModel(let name): "\(name).mlpackage / \(name).json are not in the app. Run scripts/sync_model.sh and rebuild."
            case .unexpectedModel(let why): "Unexpected model: \(why)"
            case .pixelBuffer(let status): "Could not make the model input (CVReturn \(status))."
            case .scale(let err): "Could not resize the frame (vImage \(err))."
            }
        }
    }

    let info: ModelInfo
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let decoder: YOLODecoder
    private var pool: CVPixelBufferPool?
    private var letterbox: Letterbox?
    private var head: [Float] = []

    /// Milliseconds for the last frame: Core ML prediction only, and the whole `detect` call.
    private(set) var lastPredictMs = 0.0
    private(set) var lastTotalMs = 0.0

    /// Loads `<name>.mlpackage` + `<name>.json` from the app bundle. The package is compiled on the phone
    /// once (no Mac to compile it at build time) and cached in Application Support per weights + precision.
    static func load(name: String = "DetectorV2") async throws -> Detector {
        guard let package = Bundle.main.url(forResource: name, withExtension: "mlpackage"),
              let infoURL = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw DetectorError.missingModel(name)
        }
        let info = try ModelInfo.load(from: Data(contentsOf: infoURL))
        let fm = FileManager.default
        let cache = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let compiled = cache.appendingPathComponent("\(info.name)-\(info.weightsSha256.prefix(12))-\(info.precision).mlmodelc")
        if !fm.fileExists(atPath: compiled.path) {
            let fresh = try await MLModel.compileModel(at: package)
            try? fm.removeItem(at: compiled)
            try fm.moveItem(at: fresh, to: compiled)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try Detector(info: info, model: MLModel(contentsOf: compiled, configuration: config))
    }

    init(info: ModelInfo, model: MLModel) throws {
        let desc = model.modelDescription
        guard let (inName, inDesc) = desc.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = inDesc.imageConstraint else {
            throw DetectorError.unexpectedModel("no image input")
        }
        guard constraint.pixelsWide == info.inputWidth, constraint.pixelsHigh == info.inputHeight else {
            throw DetectorError.unexpectedModel("input \(constraint.pixelsWide)×\(constraint.pixelsHigh), json says \(info.inputWidth)×\(info.inputHeight)")
        }
        guard let outName = desc.outputDescriptionsByName.first(where: { $0.value.type == .multiArray })?.key else {
            throw DetectorError.unexpectedModel("no multi-array output")
        }
        self.info = info
        self.model = model
        inputName = inName
        outputName = outName
        decoder = info.decoder
    }

    /// Detections in `frame` pixels, highest confidence first.
    func detect(_ frame: CVPixelBuffer) throws -> [Detection] {
        let t0 = CACurrentMediaTime()
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        if letterbox?.srcWidth != w || letterbox?.srcHeight != h {
            letterbox = Letterbox(srcWidth: w, srcHeight: h, dstWidth: info.inputWidth, dstHeight: info.inputHeight)
        }
        let lb = letterbox!
        let input = try letterboxed(frame, lb)

        let t1 = CACurrentMediaTime()
        let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)])
        let result = try model.prediction(from: features)
        let t2 = CACurrentMediaTime()
        guard let out = result.featureValue(for: outputName)?.multiArrayValue else {
            throw DetectorError.unexpectedModel("output \(outputName) missing")
        }
        let anchors = try copyHead(out)
        let found = decoder.decode(head, anchors: anchors).map { d -> Detection in
            var d = d
            d.box = lb.toSource(d.box)
            return d
        }
        lastPredictMs = (t2 - t1) * 1000
        lastTotalMs = (CACurrentMediaTime() - t0) * 1000
        return found
    }

    /// Frame scaled into the model input, centred on grey 114 (BGRA; Core ML converts to the model's RGB).
    private func letterboxed(_ frame: CVPixelBuffer, _ lb: Letterbox) throws -> CVPixelBuffer {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: lb.dstWidth,
                kCVPixelBufferHeightKey as String: lb.dstHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else { throw DetectorError.pixelBuffer(status) }
            pool = created
        }
        var made: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &made)
        guard status == kCVReturnSuccess, let dst = made else { throw DetectorError.pixelBuffer(status) }

        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(frame), let dstBase = CVPixelBufferGetBaseAddress(dst) else {
            throw DetectorError.pixelBuffer(kCVReturnInvalidPixelBufferAttributes)
        }
        let dstRow = CVPixelBufferGetBytesPerRow(dst)
        memset(dstBase, Int32(info.letterbox.padValue), dstRow * lb.dstHeight)
        var src = vImage_Buffer(data: srcBase, height: vImagePixelCount(lb.srcHeight), width: vImagePixelCount(lb.srcWidth),
                                rowBytes: CVPixelBufferGetBytesPerRow(frame))
        var out = vImage_Buffer(data: dstBase + lb.padTop * dstRow + lb.padLeft * 4, height: vImagePixelCount(lb.newHeight),
                                width: vImagePixelCount(lb.newWidth), rowBytes: dstRow)
        let err = vImageScale_ARGB8888(&src, &out, nil, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { throw DetectorError.scale(err) }
        return dst
    }

    /// Copies the [1, 4 + classes, anchors] output (any strides, fp16 or fp32) into `head`; returns anchors.
    private func copyHead(_ out: MLMultiArray) throws -> Int {
        let shape = out.shape.map(\.intValue), strides = out.strides.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[1] == 4 + info.classes.count else {
            throw DetectorError.unexpectedModel("output shape \(shape)")
        }
        let channels = shape[1], anchors = shape[2], sc = strides[1], sa = strides[2]
        if head.count != channels * anchors { head = [Float](repeating: 0, count: channels * anchors) }
        switch out.dataType {
        case .float32:
            out.withUnsafeBufferPointer(ofType: Float.self) { p in
                for c in 0..<channels { for a in 0..<anchors { head[c * anchors + a] = p[c * sc + a * sa] } }
            }
        case .float16:
            out.withUnsafeBufferPointer(ofType: Float16.self) { p in
                for c in 0..<channels { for a in 0..<anchors { head[c * anchors + a] = Float(p[c * sc + a * sa]) } }
            }
        default:
            throw DetectorError.unexpectedModel("output data type \(out.dataType.rawValue)")
        }
        return anchors
    }
}
