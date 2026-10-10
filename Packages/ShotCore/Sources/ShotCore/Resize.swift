/// Halves a 4-bytes-per-pixel image exactly like OpenCV's `cv2.resize(..., INTER_LINEAR)` at scale 0.5
/// (which OpenCV runs as its fast 2x2 area average): each output byte is `(a + b + c + d + 2) >> 2`.
/// That is the 1920x1080 -> 960x540 step of Ultralytics' letterbox, so the phone feeds the model the same pixels.
///
/// Writes output rows `rows` (so callers can split the work across threads); `width` x `rows` are output pixels.
public func halveRows(
    src: UnsafePointer<UInt8>, srcRowBytes: Int,
    dst: UnsafeMutablePointer<UInt8>, dstRowBytes: Int,
    width: Int, rows: Range<Int>
) {
    for y in rows {
        let r0 = src + 2 * y * srcRowBytes, r1 = r0 + srcRowBytes
        let d = dst + y * dstRowBytes
        for x in 0..<width {
            let s = 8 * x, o = 4 * x
            for c in 0..<4 {
                let sum = UInt16(r0[s + c]) + UInt16(r0[s + 4 + c]) + UInt16(r1[s + c]) + UInt16(r1[s + 4 + c])
                d[o + c] = UInt8((sum + 2) >> 2)
            }
        }
    }
}
