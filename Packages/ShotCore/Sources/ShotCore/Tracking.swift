// Port of Python_Raw/src/shottracker/tracking.py (StaticSuppressor, BallTracker). HoopLocator is not ported:
// the phone uses a fixed hoop box (found once, or marked by hand), like every evaluation run.

/// Drops "ball" detections that stay in one place (rim brackets, spare balls on the floor); see the Python docstring.
public final class StaticSuppressor {
    public let cfg: StaticFilterConfig
    private var frames: [Double] = []
    private var hist: [(t: Double, x: Double, y: Double)] = []
    private var spots: [(x: Double, y: Double, r: Double, until: Double)] = []

    public init(_ cfg: StaticFilterConfig = StaticFilterConfig()) {
        self.cfg = cfg
    }

    public func filter(_ t: Double, _ detections: [Detection]) -> [Detection] {
        frames.append(t)
        while let f = frames.first, t - f > cfg.windowS { frames.removeFirst() }
        while let h = hist.first, t - h.t > cfg.windowS { hist.removeFirst() }
        for d in detections where d.label == "ball" {
            hist.append((t, d.box.cx, d.box.cy))
        }
        spots = spots.filter { $0.until > t }
        let n = frames.count
        var out: [Detection] = []
        for d in detections {
            if d.label == "ball" {
                let cx = d.box.cx, cy = d.box.cy
                if spots.contains(where: { abs(cx - $0.x) <= $0.r && abs(cy - $0.y) <= $0.r }) { continue }
                let r = cfg.radius * max(d.box.width, d.box.height)
                var seen = Set<Double>()
                for h in hist where abs(h.x - cx) <= r && abs(h.y - cy) <= r {
                    seen.insert(h.t)
                }
                if Double(seen.count) / Double(n) >= cfg.minPresence && seen.max()! - seen.min()! >= cfg.minStaticS {
                    spots.append((cx, cy, r, t + cfg.holdS))
                    continue
                }
            }
            out.append(d)
        }
        return out
    }
}

/// A short side track for a detection the main track did not take.
final class Tracklet {
    var t: Double
    var x: Double
    var y: Double
    var d: Double
    var vx = 0.0
    var vy = 0.0
    var hits = 1

    init(_ t: Double, _ x: Double, _ y: Double, _ d: Double) {
        self.t = t
        self.x = x
        self.y = y
        self.d = d
    }

    func step(_ t: Double, _ x: Double, _ y: Double, _ d: Double) {
        let dt = t - self.t
        let nvx = (x - self.x) / dt, nvy = (y - self.y) / dt
        let a = hits == 1 ? 1.0 : 0.6
        vx = a * nvx + (1 - a) * vx
        vy = a * nvy + (1 - a) * vy
        self.t = t
        self.x = x
        self.y = y
        self.d = d
        hits += 1
    }

    /// Ball diameters per second.
    func speed() -> Double {
        dist(vx, vy) / max(d, 12.0)
    }
}

/// Follows the single ball in play with a constant-velocity gate, side tracks to switch to a released shot,
/// and a wait for a ball that left through the top of the frame (see the Python docstring).
public final class BallTracker {
    public let cfg: TrackerConfig
    public private(set) var switched = false
    private var last: BallObs?
    private var vx = 0.0
    private var vy = 0.0
    private var recent: [(t: Double, x: Double, y: Double)] = []
    private var side: [Tracklet] = []

    public init(_ cfg: TrackerConfig = TrackerConfig()) {
        self.cfg = cfg
    }

    private func exitedTop(_ last: BallObs) -> Bool {
        vy < 0 && last.y + vy * cfg.exitHorizonS < 0
    }

    private func reacquire(_ t: Double, _ last: BallObs, _ balls: [Detection], _ hoop: Box?) -> Detection? {
        let vx = self.vx
        let dt = t - last.t
        let diam = max(last.diameter, 12.0)
        let px = last.x + vx * dt
        let tolX = max(4 * diam, 0.3 * abs(vx) * dt)
        func near(_ x: Double) -> Bool {
            if abs(x - px) <= tolX { return true }
            guard let hoop, (hoop.cx - last.x) * vx > 0 else { return false }  // no hoop, or not heading towards it
            let (lo, hi) = hoop.cx < last.x ? (hoop.x1 - hoop.width, last.x) : (last.x, hoop.x2 + hoop.width)
            return lo <= x && x <= hi
        }
        // It comes back in from above, so it reappears no lower than where it was lost.
        let cands = balls.filter { near($0.box.cx) && $0.box.cy <= last.y + diam }
        if cands.isEmpty { return nil }
        return cands[firstMinIndex(cands) { abs($0.box.cx - px) }]
    }

    private func gate(_ x: Double, _ y: Double, _ d: Double, _ vx: Double, _ vy: Double, _ dt: Double)
        -> (px: Double, py: Double, gate: Double) {
        let diam = max(d, 12.0)
        let gate = max(cfg.minGatePx, cfg.gateDiams * diam) + 0.5 * dist(vx, vy) * dt
        return (x + vx * dt, y + vy * dt, gate)
    }

    private func updateSide(_ t: Double, _ free: [Detection]) {
        side = side.filter { t - $0.t <= cfg.lostS }
        var pairs: [(gap: Double, ki: Int, di: Int)] = []
        for (ki, k) in side.enumerated() {
            let g = gate(k.x, k.y, k.d, k.vx, k.vy, t - k.t)
            for (di, d) in free.enumerated() {
                let gap = dist(d.box.cx - g.px, d.box.cy - g.py)
                if gap <= g.gate { pairs.append((gap, ki, di)) }
            }
        }
        pairs.sort { ($0.gap, $0.ki, $0.di) < ($1.gap, $1.ki, $1.di) }
        var usedK = Set<Int>(), usedD = Set<Int>()
        for p in pairs where !usedK.contains(p.ki) && !usedD.contains(p.di) {
            usedK.insert(p.ki)
            usedD.insert(p.di)
            let d = free[p.di]
            side[p.ki].step(t, d.box.cx, d.box.cy, max(d.box.width, d.box.height))
        }
        for (di, d) in free.enumerated() where !usedD.contains(di) && side.count < cfg.maxTracklets {
            side.append(Tracklet(t, d.box.cx, d.box.cy, max(d.box.width, d.box.height)))
        }
    }

    private func riser(_ t: Double, _ mainSpeed: Double) -> Tracklet? {
        var best: Tracklet?
        for k in side {
            let sp = k.speed()
            if k.t == t && k.hits >= cfg.switchHits && sp >= cfg.switchSpeed && -k.vy >= cfg.switchMinUp * dist(k.vx, k.vy)
                && mainSpeed < cfg.switchRatio * sp && (best == nil || sp > best!.speed()) {
                best = k
            }
        }
        return best
    }

    private func motionConfirmed(_ t: Double, _ balls: [Detection]) -> Detection? {
        // Python sorted(key=-conf) is stable: highest confidence first, ties in detection order.
        let order = balls.indices.sorted { a, b in
            balls[a].conf != balls[b].conf ? balls[a].conf > balls[b].conf : a < b
        }
        for i in order {
            let d = balls[i]
            let size = max(d.box.width, d.box.height, 12.0)
            for r in recent {
                let dt = t - r.t
                if 0 < dt && dt <= cfg.confirmS {
                    let gap = dist(d.box.cx - r.x, d.box.cy - r.y)
                    if cfg.minMove * size <= gap && gap <= cfg.maxSpeed * size * dt {
                        vx = (d.box.cx - r.x) / dt
                        vy = (d.box.cy - r.y) / dt
                        return d
                    }
                }
            }
        }
        return nil
    }

    public func update(_ t: Double, _ detections: [Detection], hoop: Box? = nil) -> BallObs? {
        switched = false
        let balls = detections.filter { $0.label == "ball" }
        while let r = recent.first, t - r.t > cfg.confirmS { recent.removeFirst() }
        if balls.isEmpty { return nil }
        var last = self.last
        if let l = last, cfg.lostS < t - l.t, t - l.t <= cfg.exitWaitS, exitedTop(l) {
            guard let back = reacquire(t, l, balls, hoop) else { return nil }
            vy = 0  // it is coming down now; the gate re-learns the speed
            self.last = BallObs(t: t, x: back.box.cx, y: back.box.cy, diameter: max(back.box.width, back.box.height))
            return self.last
        }
        let best: Detection
        if last == nil || t - last!.t > cfg.lostS {
            let cands = balls.filter { $0.conf >= cfg.initConf }
            if !cands.isEmpty {
                best = cands[firstMaxIndex(cands) { $0.conf }]
                vx = 0
                vy = 0
            } else {
                let confirmed = motionConfirmed(t, balls)
                for d in balls { recent.append((t, d.box.cx, d.box.cy)) }
                guard let confirmed else { return nil }
                best = confirmed
                last = nil  // keep the velocity from the confirming pair
            }
        } else {
            let l = last!
            let dt = t - l.t
            let g = gate(l.x, l.y, l.diameter, vx, vy, dt)
            let diam = max(l.diameter, 12.0)
            var bestIndex: Int?
            var bestScore = 0.0
            for (i, d) in balls.enumerated() {
                let gap = dist(d.box.cx - g.px, d.box.cy - g.py)
                if gap <= g.gate {
                    let score = d.conf / (1.0 + gap / diam)
                    if bestIndex == nil || score > bestScore {
                        bestIndex = i
                        bestScore = score
                    }
                }
            }
            updateSide(t, balls.enumerated().filter { $0.offset != bestIndex }.map(\.element))
            if let r = riser(t, dist(vx, vy) / diam) {
                side.removeAll { $0 === r }
                if let bi = bestIndex {  // the old target becomes a side track
                    let b = balls[bi]
                    let k = Tracklet(l.t, l.x, l.y, l.diameter)
                    k.vx = vx
                    k.vy = vy
                    k.step(t, b.box.cx, b.box.cy, max(b.box.width, b.box.height))
                    side.append(k)
                }
                vx = r.vx
                vy = r.vy
                self.last = BallObs(t: t, x: r.x, y: r.y, diameter: r.d)
                switched = true
                return self.last
            }
            guard let bi = bestIndex else { return nil }
            best = balls[bi]
        }

        let obs = BallObs(t: t, x: best.box.cx, y: best.box.cy, diameter: max(best.box.width, best.box.height))
        if let l = last, 0 < t - l.t, t - l.t <= cfg.lostS {
            let dt = t - l.t
            let nvx = (obs.x - l.x) / dt, nvy = (obs.y - l.y) / dt
            vx = 0.6 * nvx + 0.4 * vx
            vy = 0.6 * nvy + 0.4 * vy
        }
        self.last = obs
        return obs
    }
}
