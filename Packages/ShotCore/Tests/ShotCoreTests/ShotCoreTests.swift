import Foundation
import Testing
@testable import ShotCore

@Suite struct LetterboxTests {
    @Test func landscape1080pInto960x544() {
        let lb = Letterbox(srcWidth: 1920, srcHeight: 1080, dstWidth: 960, dstHeight: 544)
        #expect(lb.gain == 0.5)
        #expect(lb.newWidth == 960 && lb.newHeight == 540)
        #expect(lb.padLeft == 0 && lb.padTop == 2)
        #expect(lb.toSource(Box(0, 2, 960, 542)) == Box(0, 0, 1920, 1080))
        #expect(lb.toSource(Box(100, 52, 120, 72)) == Box(200, 100, 240, 140))
    }

    @Test func clipsToTheFrame() {
        let lb = Letterbox(srcWidth: 1920, srcHeight: 1080, dstWidth: 960, dstHeight: 544)
        #expect(lb.toSource(Box(-10, 0, 970, 544)) == Box(0, 0, 1920, 1080))
    }

    @Test func portraitPadsTheSides() {
        let lb = Letterbox(srcWidth: 1080, srcHeight: 1920, dstWidth: 960, dstHeight: 544)
        #expect(lb.newHeight == 544 && lb.newWidth == 306)
        #expect(lb.padTop == 0 && lb.padLeft == 327)
    }
}

/// Builds a channel-major [4 + classes][anchors] head from (cx, cy, w, h, scores) rows.
private func head(_ rows: [(Float, Float, Float, Float, [Float])]) -> [Float] {
    let n = rows.count, nc = rows.first?.4.count ?? 0
    var out = [Float](repeating: 0, count: (4 + nc) * n)
    for (a, r) in rows.enumerated() {
        out[0 * n + a] = r.0
        out[1 * n + a] = r.1
        out[2 * n + a] = r.2
        out[3 * n + a] = r.3
        for k in 0..<nc { out[(4 + k) * n + a] = r.4[k] }
    }
    return out
}

@Suite struct YOLODecoderTests {
    let decoder = YOLODecoder(classes: ["ball", "hoop", "rim_only"], conf: 0.15, iou: 0.7)

    @Test func perClassNMSKeepsTheBestOfEachClass() {
        let out = head([
            (100, 100, 20, 20, [0.80, 0.0, 0.0]),  // ball, suppressed by the next one
            (101, 100, 20, 20, [0.90, 0.0, 0.0]),  // best ball
            (100, 100, 20, 20, [0.10, 0.70, 0.0]),  // hoop on the same spot: other class, kept
            (400, 300, 30, 30, [0.50, 0.0, 0.0]),  // a second, separate ball
        ])
        let d = decoder.decode(out, anchors: 4)
        #expect(d.map(\.label) == ["ball", "hoop", "ball"])
        #expect(d.map(\.conf).map { Float($0) } == [0.90, 0.70, 0.50])
        #expect(d[0].box == Box(91, 90, 111, 110))
    }

    @Test func scoreMustBeAboveConf() {
        let out = head([
            (100, 100, 20, 20, [0.15, 0.0, 0.0]),  // equal to conf: dropped, like Ultralytics (> conf)
            (300, 100, 20, 20, [0.0, 0.0, 0.16]),
        ])
        let d = decoder.decode(out, anchors: 2)
        #expect(d.count == 1 && d[0].label == "rim_only")
    }

    @Test func onlyOverlapAboveTheIoUThresholdIsSuppressed() {
        let out = head([
            (10, 10, 10, 10, [0.9, 0, 0]),
            (15, 10, 10, 10, [0.8, 0, 0]),  // IoU 1/3 with the first: kept
            (11, 10, 10, 10, [0.7, 0, 0]),  // IoU 0.818 with the first: suppressed
        ])
        #expect(decoder.decode(out, anchors: 3).map(\.conf).map { Float($0) } == [0.9, 0.8])
    }

    @Test func capsAtMaxDet() {
        var d = decoder
        d.maxDet = 2
        var rows: [(Float, Float, Float, Float, [Float])] = []
        for i in 0..<5 {
            let x = Float(100 * i + 50), score = 0.5 + Float(i) / 100
            rows.append((x, 50, 10, 10, [score, 0, 0]))
        }
        let out = head(rows)
        #expect(d.decode(out, anchors: 5).count == 2)
    }
}

@Suite struct ModelInfoTests {
    @Test func readsTheExportJSON() throws {
        let json = """
        {"name": "DetectorV2", "weights": "runs/detect/combined_v1/weights/best.pt",
         "weights_sha256": "e90e448a", "input_hw": [544, 960], "precision": "fp16",
         "classes": ["ball", "hoop", "rim_only"], "conf": 0.15, "iou": 0.7, "max_det": 300,
         "letterbox": {"pad_value": 114, "center": true, "stride": 32},
         "output": "[1, 7, anchors]", "versions": {"ultralytics": "8.4.171"}, "date": "2026-10-10"}
        """
        let info = try ModelInfo.load(from: Data(json.utf8))
        #expect(info.inputWidth == 960 && info.inputHeight == 544)
        #expect(info.classes == ["ball", "hoop", "rim_only"])
        #expect(info.letterbox.padValue == 114)
        #expect(info.decoder.conf == 0.15 && info.decoder.maxDet == 300)
    }
}
