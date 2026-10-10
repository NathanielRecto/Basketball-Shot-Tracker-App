/// Axis-aligned box in pixels: (x1, y1) top-left, (x2, y2) bottom-right, like the Python `Box`.
public struct Box: Equatable, Sendable {
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    public var width: Double { x2 - x1 }
    public var height: Double { y2 - y1 }
    public var cx: Double { (x1 + x2) / 2 }
    public var cy: Double { (y1 + y2) / 2 }
    public var area: Double { max(0, width) * max(0, height) }

    /// Intersection over union, the torchvision `box_iou` formula (no +1 on widths).
    public func iou(_ o: Box) -> Double {
        let w = min(x2, o.x2) - max(x1, o.x1)
        let h = min(y2, o.y2) - max(y1, o.y1)
        guard w > 0, h > 0 else { return 0 }
        let inter = w * h
        return inter / (area + o.area - inter)
    }
}

/// Ultralytics `LetterBox` onto a fixed model input: scale to fit, centre, pad with grey 114.
///
/// 1920 x 1080 into 960 x 544 (what `predict(imgsz=960)` uses): gain 0.5, image 960 x 540, 2 rows of
/// padding on top. `toSource` undoes it like Ultralytics `scale_boxes` (subtract pad, divide, clip).
public struct Letterbox: Equatable, Sendable {
    public let srcWidth: Int
    public let srcHeight: Int
    public let dstWidth: Int
    public let dstHeight: Int
    public let gain: Double
    public let newWidth: Int
    public let newHeight: Int
    public let padLeft: Int
    public let padTop: Int

    public init(srcWidth: Int, srcHeight: Int, dstWidth: Int, dstHeight: Int) {
        self.srcWidth = srcWidth
        self.srcHeight = srcHeight
        self.dstWidth = dstWidth
        self.dstHeight = dstHeight
        gain = min(Double(dstHeight) / Double(srcHeight), Double(dstWidth) / Double(srcWidth))
        // Python round() is round-half-to-even.
        newWidth = Int((Double(srcWidth) * gain).rounded(.toNearestOrEven))
        newHeight = Int((Double(srcHeight) * gain).rounded(.toNearestOrEven))
        padLeft = Int((Double(dstWidth - newWidth) / 2 - 0.1).rounded(.toNearestOrEven))
        padTop = Int((Double(dstHeight - newHeight) / 2 - 0.1).rounded(.toNearestOrEven))
    }

    /// Model-input box -> source-frame box, clipped to the frame.
    public func toSource(_ b: Box) -> Box {
        func x(_ v: Double) -> Double { min(max((v - Double(padLeft)) / gain, 0), Double(srcWidth)) }
        func y(_ v: Double) -> Double { min(max((v - Double(padTop)) / gain, 0), Double(srcHeight)) }
        return Box(x(b.x1), y(b.y1), x(b.x2), y(b.y2))
    }
}
