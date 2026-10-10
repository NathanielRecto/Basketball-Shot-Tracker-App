// Port of Python_Raw/src/shottracker/geometry.py (fit + helpers) and types.py (BallObs).
// Every formula keeps the Python's operation order so results match bit for bit (golden tests).

/// One tracked ball position in frame pixels.
public struct BallObs: Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public var diameter: Double

    public init(t: Double, x: Double, y: Double, diameter: Double = 0) {
        self.t = t
        self.x = x
        self.y = y
        self.diameter = diameter
    }
}

/// (t, x, y) point of a flight.
public struct Sample: Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

/// sqrt(dx*dx + dy*dy), spelled out like the Python `geometry.dist` (not hypot, which rounds differently).
public func dist(_ dx: Double, _ dy: Double) -> Double {
    (dx * dx + dy * dy).squareRoot()
}

/// Projectile model fitted against time: x(tau) = xA*tau + xB, y(tau) = c2*tau^2 + c1*tau + c0, tau = t - t0.
public struct FlightFit: Equatable, Sendable {
    public var t0: Double
    public var xA: Double
    public var xB: Double
    public var c2: Double
    public var c1: Double
    public var c0: Double
    public var rms: Double
    public var n: Int

    /// y points down, so gravity must show up as positive curvature.
    public var isPhysical: Bool { c2 > 0 }

    public func xAt(_ t: Double) -> Double {
        xA * (t - t0) + xB
    }

    public func yAt(_ t: Double) -> Double {
        let tau = t - t0
        return c2 * tau * tau + c1 * tau + c0
    }

    public func velocityAt(_ t: Double) -> (vx: Double, vy: Double) {
        let tau = t - t0
        return (xA, 2 * c2 * tau + c1)
    }

    /// Time at which the descending branch reaches `y` (nil if never).
    public func timeAtY(_ y: Double) -> Double? {
        if c2 <= 0 { return nil }
        let disc = c1 * c1 - 4 * c2 * (c0 - y)
        if disc < 0 { return nil }
        return t0 + (-c1 + disc.squareRoot()) / (2 * c2)
    }
}

private func det3(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double,
                  _ g: Double, _ h: Double, _ i: Double) -> Double {
    a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
}

/// Least squares from the normal equations, plain sums in sample order and Cramer's rule (Python `fit_flight`).
public func fitFlight(_ samples: [Sample], minPoints: Int = 4) -> FlightFit? {
    if samples.count < minPoints { return nil }
    let t0 = samples[0].t
    let pts = samples.map { (tau: $0.t - t0, x: $0.x, y: $0.y) }
    if pts[pts.count - 1].tau - pts[0].tau <= 0 { return nil }
    let n = Double(pts.count)
    var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, sx = 0.0, stx = 0.0, sy = 0.0, sty = 0.0, stty = 0.0
    for p in pts {
        let tau = p.tau, t2 = tau * tau
        s1 += tau
        s2 += t2
        s3 += t2 * tau
        s4 += t2 * t2
        sx += p.x
        stx += tau * p.x
        sy += p.y
        sty += tau * p.y
        stty += t2 * p.y
    }
    let den = n * s2 - s1 * s1
    let det = det3(s4, s3, s2, s3, s2, s1, s2, s1, n)
    if den == 0 || det == 0 { return nil }
    let a = (n * stx - s1 * sx) / den
    let b = (sx - a * s1) / n
    let c2 = det3(stty, s3, s2, sty, s2, s1, sy, s1, n) / det
    let c1 = det3(s4, stty, s2, s3, sty, s1, s2, sy, n) / det
    let c0 = det3(s4, s3, stty, s3, s2, sty, s2, s1, sy) / det
    if ![a, b, c2, c1, c0].allSatisfy(\.isFinite) { return nil }
    var sq = 0.0
    for p in pts {
        let ex = p.x - (a * p.tau + b)
        let ey = p.y - ((c2 * p.tau + c1) * p.tau + c0)
        sq += ex * ex + ey * ey
    }
    return FlightFit(t0: t0, xA: a, xB: b, c2: c2, c1: c1, c0: c0, rms: (sq / n).squareRoot(), n: pts.count)
}

/// Python's `f"{x:.{digits}f}"` (with `forceSign`, `f"{x:+.{digits}f}"`): the exact binary value rounded half to
/// even, and "-" for negative zero. Used for numbers inside decision-log messages, which must match exactly.
public func pyFixed(_ x: Double, _ digits: Int, forceSign: Bool = false) -> String {
    precondition((0...3).contains(digits), "pyFixed handles 0-3 decimals")
    if !x.isFinite { return x.isNaN ? "nan" : (x < 0 ? "-inf" : (forceSign ? "+inf" : "inf")) }
    let negative = x.sign == .minus
    let a = abs(x)
    var p10: UInt64 = 1
    for _ in 0..<digits { p10 *= 10 }
    var q: UInt64 = 0
    if a.isNormal {
        let sig = UInt64(a.significandBitPattern) | (1 << 52)  // a = sig * 2^e exactly
        let e = Int(a.exponent) - 52
        if e >= 0 {
            q = (sig << UInt64(e)) * p10  // integers >= 2^52: far larger than anything logged here
        } else {
            let n = sig * p10, k = -e  // n < 2^63
            if k < 64 {
                q = n >> UInt64(k)
                let r = n & ((1 << UInt64(k)) - 1), half: UInt64 = 1 << UInt64(k - 1)
                if r > half || (r == half && q & 1 == 1) { q += 1 }
            }
        }
    }
    var s = String(q)
    if digits > 0 {
        if s.count <= digits { s = String(repeating: "0", count: digits - s.count + 1) + s }
        s.insert(".", at: s.index(s.endIndex, offsetBy: -digits))
    }
    return (negative ? "-" : (forceSign ? "+" : "")) + s
}

/// Python's `str(bool)`.
public func pyBool(_ b: Bool) -> String {
    b ? "True" : "False"
}

/// Index of the first minimum (Python `min(..., key=)` keeps the first of equal keys). `items` must not be empty.
func firstMinIndex<T>(_ items: [T], by key: (T) -> Double) -> Int {
    var best = 0, bestKey = key(items[0])
    for i in items.indices.dropFirst() {
        let k = key(items[i])
        if k < bestKey {
            best = i
            bestKey = k
        }
    }
    return best
}

/// Index of the first maximum (Python `max(..., key=)` keeps the first of equal keys). `items` must not be empty.
func firstMaxIndex<T>(_ items: [T], by key: (T) -> Double) -> Int {
    var best = 0, bestKey = key(items[0])
    for i in items.indices.dropFirst() {
        let k = key(items[i])
        if k > bestKey {
            best = i
            bestKey = k
        }
    }
    return best
}
