/// One detector box, in the pixel space it was decoded in (model input, or the frame after `Letterbox.toSource`).
public struct Detection: Equatable, Sendable {
    public var classIndex: Int
    public var label: String
    public var conf: Double
    public var box: Box

    public init(classIndex: Int, label: String, conf: Double, box: Box) {
        self.classIndex = classIndex
        self.label = label
        self.conf = conf
        self.box = box
    }
}

/// Decodes the raw YOLOv8 head the way Ultralytics `non_max_suppression` does with predict()'s defaults
/// (multi_label off, per-class NMS, max_nms 30000, max_det 300):
/// best class per anchor, keep if its score > conf, greedy NMS within each class (suppress IoU > iou).
public struct YOLODecoder: Sendable {
    public var classes: [String]
    public var conf: Double
    public var iou: Double
    public var maxDet: Int
    public var maxNMS: Int

    public init(classes: [String], conf: Double, iou: Double, maxDet: Int = 300, maxNMS: Int = 30_000) {
        self.classes = classes
        self.conf = conf
        self.iou = iou
        self.maxDet = maxDet
        self.maxNMS = maxNMS
    }

    /// `output` is the head without its batch axis, channel-major: [4 + classes][anchors], channels
    /// cx, cy, w, h (model-input pixels) then one score per class. Returns boxes in model-input pixels,
    /// highest score first.
    public func decode(_ output: [Float], anchors: Int) -> [Detection] {
        output.withUnsafeBufferPointer { decode($0, anchors: anchors) }
    }

    /// Non-generic on purpose: a generic decode called from the app module is not specialised across the module
    /// boundary, so it would read each of the ~75k values through protocol witnesses.
    public func decode(_ output: UnsafeBufferPointer<Float>, anchors: Int) -> [Detection] {
        let nc = classes.count
        precondition(output.count == (4 + nc) * anchors, "output has \(output.count) values, expected \((4 + nc) * anchors)")
        func at(_ channel: Int, _ anchor: Int) -> Float { output[channel * anchors + anchor] }
        // PyTorch compares the float32 scores with conf in float32: a score of Float(0.15) is NOT > 0.15.
        let threshold = Float(conf)

        var candidates: [Detection] = []
        for a in 0..<anchors {
            var best = 0
            var score = at(4, a)
            for k in 1..<max(nc, 1) where at(4 + k, a) > score {
                best = k
                score = at(4 + k, a)
            }
            guard score > threshold else { continue }
            let cx = Double(at(0, a)), cy = Double(at(1, a)), w = Double(at(2, a)), h = Double(at(3, a))
            candidates.append(Detection(classIndex: best, label: classes[best], conf: Double(score),
                                        box: Box(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)))
        }
        candidates.sort { $0.conf > $1.conf }
        if candidates.count > maxNMS { candidates.removeLast(candidates.count - maxNMS) }

        var kept: [Detection] = []
        var suppressed = [Bool](repeating: false, count: candidates.count)
        for i in candidates.indices where !suppressed[i] {
            kept.append(candidates[i])
            if kept.count == maxDet { break }
            for j in (i + 1)..<candidates.count where !suppressed[j]
                && candidates[j].classIndex == candidates[i].classIndex
                && candidates[i].box.iou(candidates[j].box) > iou {
                suppressed[j] = true
            }
        }
        return kept
    }
}
