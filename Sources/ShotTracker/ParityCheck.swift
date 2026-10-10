import CoreVideo
import Foundation
import ImageIO
import ShotCore

/// Runs the phone's detector on the dev frames from Python_Raw/scripts/export_parity_frames.py and compares its
/// boxes with the PyTorch reference. Results are logged as `PARITY ...` lines (read them with `idevicesyslog`)
/// and returned for the screen. The frames are local only (Resources/Parity, gitignored).
enum ParityCheck {
    struct Reference: Decodable {
        struct Det: Decodable {
            var label: String
            var conf: Double
            var box: [Double]
        }

        struct Frame: Decodable {
            var file: String
            var width: Int
            var height: Int
            var dets: [Det]
        }

        var weightsSha256: String
        var imgsz: Int
        var conf: Double
        var classes: [String]
        var frames: [Frame]
    }

    struct Variant {
        var name: String
        var model: String
        var directory: URL?  // nil = app bundle
        var resize: Detector.Resize
    }

    enum CheckError: LocalizedError {
        case image(String)

        var errorDescription: String? {
            switch self {
            case .image(let why): "Could not read a parity frame: \(why)"
            }
        }
    }

    static var directory: URL? {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Parity")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("reference.json").path) ? dir : nil
    }

    static func run(progress: @escaping @Sendable (String) -> Void) async throws -> [String] {
        guard let dir = directory else { return ["No parity frames in the app (Resources/Parity)."] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let ref = try decoder.decode(Reference.self, from: Data(contentsOf: dir.appendingPathComponent("reference.json")))
        let variants = [
            Variant(name: "fp16 exact", model: "DetectorV2", directory: nil, resize: .exact),
            Variant(name: "fp32 exact", model: "DetectorV2_fp32", directory: dir, resize: .exact),
            Variant(name: "fp16 vImage", model: "DetectorV2", directory: nil, resize: .vImage),
        ]
        var lines = ["\(ref.frames.count) dev frames, PyTorch reference conf \(ref.conf), imgsz \(ref.imgsz)"]
        log("frames=\(ref.frames.count) conf=\(ref.conf) imgsz=\(ref.imgsz) weights=\(ref.weightsSha256.prefix(12))")

        for v in variants {
            progress("Checking \(v.name)…")
            let det: Detector
            do {
                det = try await Detector.load(name: v.model, directory: v.directory)
            } catch {
                lines.append("\(v.name): skipped (\(error.localizedDescription))")
                continue
            }
            if det.info.weightsSha256 != ref.weightsSha256 {
                lines.append("\(v.name): WARNING model weights \(det.info.weightsSha256.prefix(12)) ≠ reference \(ref.weightsSha256.prefix(12))")
            }
            det.resize = v.resize
            var summary = ParitySummary()
            var notes: [String] = []
            var predictMs: [Double] = []
            for f in ref.frames {
                let frame = try pixelBuffer(png: dir.appendingPathComponent("frames").appendingPathComponent(f.file))
                let out = try det.detect(frame)
                predictMs.append(out.predictMs)
                let reference = f.dets.map { d in
                    Detection(classIndex: ref.classes.firstIndex(of: d.label) ?? -1, label: d.label, conf: d.conf,
                              box: Box(d.box[0], d.box[1], d.box[2], d.box[3]))
                }
                let c = FrameComparison.compare(reference: reference, candidate: out.detections)
                summary.add(c)
                for m in c.missed { notes.append("missed \(m.label) \(fmt(m.conf, 2)) in \(f.file)") }
                for e in c.extra { notes.append("extra \(e.label) \(fmt(e.conf, 2)) in \(f.file)") }
                let worst = c.matched.map { "\($0.reference.label) iou=\(fmt($0.iou, 3)) dconf=\(fmt($0.confDelta, 3)) px=\(fmt($0.maxCornerPx, 1))" }
                log("\(v.name) \(f.file) ref=\(reference.count) got=\(out.detections.count) \(worst.joined(separator: "; "))")
            }
            predictMs.sort()
            let line = "\(v.name): ref \(summary.reference) · phone \(summary.candidate) · matched \(summary.matched) · "
                + "missed \(summary.missed.count) · extra \(summary.extra.count) | IoU mean \(fmt(summary.meanIoU, 3)) "
                + "min \(fmt(summary.minIoU, 3)) | Δconf mean \(fmt(summary.meanAbsConf, 3)) max \(fmt(summary.maxAbsConf, 3)) "
                + "| corner max \(fmt(summary.maxCornerPx, 1)) px | model median \(fmt(predictMs[predictMs.count / 2], 0)) ms"
            lines.append(line)
            lines += notes.map { "   \($0)" }
            log("SUMMARY " + line)
            notes.forEach { log("NOTE \(v.name) \($0)") }
        }
        return lines
    }

    private static func log(_ s: String) {
        NSLog("PARITY %@", s)
    }

    private static func fmt(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v)
    }

    /// The PNG's exact pixel values in a BGRA buffer: raw decoded bytes, no colour management or redraw.
    static func pixelBuffer(png url: URL) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CheckError.image("cannot decode \(url.lastPathComponent)")
        }
        let w = image.width, h = image.height, bpp = image.bitsPerPixel / 8, rowBytes = image.bytesPerRow
        let alpha = image.alphaInfo
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        guard image.bitsPerComponent == 8, bpp == 3 || bpp == 4, !little,
              bpp == 3 || alpha == .noneSkipLast || alpha == .last || alpha == .premultipliedLast,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw CheckError.image("unsupported layout \(image.bitsPerPixel) bpp, alpha \(alpha.rawValue), info \(image.bitmapInfo.rawValue)")
        }
        var made: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let status = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &made)
        guard status == kCVReturnSuccess, let pb = made else { throw Detector.DetectorError.pixelBuffer(status) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let dst = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let dstRow = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h {
            let s = bytes + y * rowBytes, d = dst + y * dstRow
            for x in 0..<w {
                let i = x * bpp, o = x * 4
                d[o] = s[i + 2]  // B
                d[o + 1] = s[i + 1]  // G
                d[o + 2] = s[i]  // R
                d[o + 3] = 255
            }
        }
        return pb
    }
}
