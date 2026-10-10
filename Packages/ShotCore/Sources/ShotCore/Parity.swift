/// Compares two detectors' boxes on the same image: the phone's Core ML detector against the PyTorch
/// reference (Python_Raw/scripts/export_parity_frames.py).
public struct MatchedPair: Equatable, Sendable {
    public var reference: Detection
    public var candidate: Detection
    public var iou: Double
    /// Largest difference between corresponding box corners, in pixels.
    public var maxCornerPx: Double {
        let r = reference.box, c = candidate.box
        return max(abs(r.x1 - c.x1), abs(r.y1 - c.y1), abs(r.x2 - c.x2), abs(r.y2 - c.y2))
    }
    public var confDelta: Double { candidate.conf - reference.conf }
}

public struct FrameComparison: Equatable, Sendable {
    public var matched: [MatchedPair] = []
    public var missed: [Detection] = []  // reference only
    public var extra: [Detection] = []  // candidate only

    /// Same-label pairs, best IoU first, each box used once; pairs below `minIoU` are not the same object.
    public static func compare(reference: [Detection], candidate: [Detection], minIoU: Double = 0.5) -> FrameComparison {
        var pairs: [(Int, Int, Double)] = []
        for (i, r) in reference.enumerated() {
            for (j, c) in candidate.enumerated() where r.label == c.label {
                let iou = r.box.iou(c.box)
                if iou >= minIoU { pairs.append((i, j, iou)) }
            }
        }
        pairs.sort { $0.2 > $1.2 }
        var usedR = Set<Int>(), usedC = Set<Int>()
        var out = FrameComparison()
        for (i, j, iou) in pairs where !usedR.contains(i) && !usedC.contains(j) {
            usedR.insert(i)
            usedC.insert(j)
            out.matched.append(MatchedPair(reference: reference[i], candidate: candidate[j], iou: iou))
        }
        out.missed = reference.indices.filter { !usedR.contains($0) }.map { reference[$0] }
        out.extra = candidate.indices.filter { !usedC.contains($0) }.map { candidate[$0] }
        return out
    }
}

public struct ParitySummary: Equatable, Sendable {
    public private(set) var frames = 0
    public private(set) var reference = 0
    public private(set) var candidate = 0
    public private(set) var matched = 0
    public private(set) var missed: [Detection] = []
    public private(set) var extra: [Detection] = []
    public private(set) var minIoU = 1.0
    public private(set) var maxAbsConf = 0.0
    public private(set) var maxCornerPx = 0.0
    private var sumIoU = 0.0
    private var sumAbsConf = 0.0

    public init() {}

    public var meanIoU: Double { matched == 0 ? 0 : sumIoU / Double(matched) }
    public var meanAbsConf: Double { matched == 0 ? 0 : sumAbsConf / Double(matched) }

    public mutating func add(_ c: FrameComparison) {
        frames += 1
        reference += c.matched.count + c.missed.count
        candidate += c.matched.count + c.extra.count
        matched += c.matched.count
        missed += c.missed
        extra += c.extra
        for p in c.matched {
            sumIoU += p.iou
            sumAbsConf += abs(p.confDelta)
            minIoU = min(minIoU, p.iou)
            maxAbsConf = max(maxAbsConf, abs(p.confDelta))
            maxCornerPx = max(maxCornerPx, p.maxCornerPx)
        }
    }
}
