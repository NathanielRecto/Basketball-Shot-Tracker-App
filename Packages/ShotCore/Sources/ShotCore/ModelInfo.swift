import Foundation

/// The `<name>.json` written next to the model by Python_Raw/scripts/export_coreml.py.
public struct ModelInfo: Codable, Equatable, Sendable {
    public struct LetterboxInfo: Codable, Equatable, Sendable {
        public var padValue: Int
        public var center: Bool
        public var stride: Int
    }

    public var name: String
    public var weightsSha256: String
    public var inputHw: [Int]
    public var precision: String
    public var classes: [String]
    public var conf: Double
    public var iou: Double
    public var maxDet: Int
    public var letterbox: LetterboxInfo

    public var inputHeight: Int { inputHw[0] }
    public var inputWidth: Int { inputHw[1] }

    public static func load(from data: Data) throws -> ModelInfo {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ModelInfo.self, from: data)
    }

    public var decoder: YOLODecoder { YOLODecoder(classes: classes, conf: conf, iou: iou, maxDet: maxDet) }
}
