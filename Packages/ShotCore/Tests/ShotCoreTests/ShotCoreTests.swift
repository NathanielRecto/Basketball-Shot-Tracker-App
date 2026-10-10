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

@Suite struct ParityTests {
    func det(_ label: String, _ conf: Double, _ x: Double, _ y: Double, _ s: Double = 20) -> Detection {
        Detection(classIndex: 0, label: label, conf: conf, box: Box(x, y, x + s, y + s))
    }

    @Test func matchesSameLabelByBestIoU() {
        let ref = [det("ball", 0.8, 100, 100), det("rim_only", 0.6, 300, 50, 60)]
        let got = [det("rim_only", 0.62, 301, 50, 60), det("ball", 0.79, 102, 100), det("ball", 0.2, 500, 500)]
        let c = FrameComparison.compare(reference: ref, candidate: got)
        #expect(c.matched.count == 2 && c.missed.isEmpty && c.extra.count == 1)
        let ball = c.matched.first { $0.reference.label == "ball" }!
        #expect(abs(ball.iou - 360.0 / 440.0) < 1e-9)
        #expect(ball.maxCornerPx == 2 && abs(ball.confDelta + 0.01) < 1e-9)
    }

    @Test func differentLabelsOrFarBoxesDoNotMatch() {
        let c = FrameComparison.compare(reference: [det("ball", 0.5, 0, 0)],
                                        candidate: [det("hoop", 0.5, 0, 0), det("ball", 0.5, 15, 15)])
        #expect(c.matched.isEmpty && c.missed.count == 1 && c.extra.count == 2)
    }

    @Test func summaryAddsUp() {
        var s = ParitySummary()
        s.add(FrameComparison.compare(reference: [det("ball", 0.5, 0, 0)], candidate: [det("ball", 0.6, 0, 0)]))
        s.add(FrameComparison.compare(reference: [det("ball", 0.5, 0, 0)], candidate: []))
        #expect(s.frames == 2 && s.reference == 2 && s.candidate == 1 && s.matched == 1 && s.missed.count == 1)
        #expect(s.meanIoU == 1 && abs(s.maxAbsConf - 0.1) < 1e-9)
    }
}

@Suite struct ResizeTests {
    @Test func halvesWithOpenCVRounding() {
        // 4x2 source -> 2x1 output, 4 bytes per pixel.
        let src: [UInt8] = [
            0, 1, 2, 255,   1, 1, 2, 255,   10, 20, 30, 40,   10, 20, 30, 40,
            0, 2, 2, 255,   1, 2, 3, 255,   11, 21, 31, 41,   13, 23, 33, 43,
        ]
        var dst = [UInt8](repeating: 0, count: 8)
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                halveRows(src: s.baseAddress!, srcRowBytes: 16, dst: d.baseAddress!, dstRowBytes: 8, width: 2, rows: 0..<1)
            }
        }
        // (0+1+0+1+2)>>2 = 1, (1+1+2+2+2)>>2 = 2, (2+2+2+3+2)>>2 = 2, 255; (44+2)>>2 = 11, (84+2)>>2 = 21, ...
        #expect(dst == [1, 2, 2, 255, 11, 21, 31, 41])
    }
}

@Suite struct HoopFinderTests {
    @Test func rimPlusNet() {
        // 40 px rim: y1 up 0.05 widths, x2 out 0.02 widths, net down to 1.27 widths below the rim's top.
        #expect(rimToHoop(Box(100, 100, 140, 110)) == Box(100, 98, 140.8, 150.8))
    }

    @Test func biggestRimPerFrameThenMedian() {
        let near = Box(100, 100, 140, 110), far = Box(600, 300, 610, 303)
        let frames: [[Box]] = [
            [far, near],
            [Box(102, 100, 142, 110), far],
            [],  // a player in front of the hoop
            [Box(98, 100, 138, 110)],
            [Box(300, 500, 400, 520)],  // one odd frame: the median ignores it
            [near],
        ]
        let r = hoopFromRims(frames)
        #expect(r.hoop == rimToHoop(near))
        #expect(abs(r.ambiguity! - (10.0 * 3.0) / (40.0 * 10.0)) < 1e-12)  // the far rim is much smaller
    }

    @Test func needsAFewFrames() {
        #expect(hoopFromRims([[Box(0, 0, 10, 10)], [], [Box(0, 0, 10, 10)]]).hoop == nil)
        #expect(hoopFromRims([[Box(0, 0, 10, 10)]]).ambiguity == nil)
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
