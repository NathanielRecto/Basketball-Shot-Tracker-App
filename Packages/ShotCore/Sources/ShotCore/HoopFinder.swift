// Port of the rim path of Python_Raw/src/shottracker/calibration.py (`hoop_from_rims`, `rim_to_hoop`): with a fixed
// camera, the hoop the camera is set up for is the nearest one, so its rim looks biggest. Take the biggest
// rim_only box in each frame, the median over frames, and add the hanging net below it.

/// Rim box -> rim + net (the hoop box the shot logic uses), in rim widths: x1, y1, x2 offsets from the rim box and
/// y2 below the rim's top. Learned in Python from hand-marked hoops on the own dev sessions (IoU 0.82-0.93).
public let rimToHoopOffsets = (x1: 0.0, y1: -0.05, x2: 0.02, y2: 1.27)

public func rimToHoop(_ rim: Box) -> Box {
    let w = rim.width, o = rimToHoopOffsets
    return Box(rim.x1 + o.x1 * w, rim.y1 + o.y1 * w, rim.x2 + o.x2 * w, rim.y1 + o.y2 * w)
}

/// numpy.median: the middle value, or the mean of the two middle values.
func median(_ values: [Double]) -> Double {
    let s = values.sorted(), n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// The nearest hoop from per-frame rim boxes, and how ambiguous it was: the area of the second-biggest rim (at
/// least one rim width away) over the chosen one, median over frames that saw two or more. Near 1 = two similar
/// hoops in view, so a person should confirm; nil = only one rim ever seen.
public func hoopFromRims(_ perFrame: [[Box]], minFrames: Int = 3) -> (hoop: Box?, ambiguity: Double?) {
    let seen = perFrame.filter { !$0.isEmpty }
    let biggest = seen.map { $0[firstMaxIndex($0) { $0.width * $0.height }] }
    if biggest.count < minFrames { return (nil, nil) }
    let rim = Box(median(biggest.map(\.x1)), median(biggest.map(\.y1)), median(biggest.map(\.x2)), median(biggest.map(\.y2)))
    var ratios: [Double] = []
    for (rims, top) in zip(seen, biggest) {
        let others = rims.filter { dist($0.cx - top.cx, $0.cy - top.cy) > top.width }.map { $0.width * $0.height }
        if let m = others.max() { ratios.append(m / (top.width * top.height)) }
    }
    return (rimToHoop(rim), ratios.isEmpty ? nil : median(ratios))
}
