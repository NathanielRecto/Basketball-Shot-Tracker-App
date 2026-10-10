import Foundation

// Port of Python_Raw/src/shottracker/shot_logic.py: the IDLE -> FLIGHT -> CONFIRM (/ RATTLE) state machine that
// turns one ball observation per frame into made / missed calls. Read the Python module docstring for the rules;
// this file mirrors it statement by statement (including Python's first-wins min/max and its log formats), so
// the golden tests can demand identical numbers.

public enum Outcome: String, Sendable {
    case made
    case missed
}

public struct ShotEvent: Sendable {
    public var index: Int
    public var outcome: Outcome
    public var reason: String  // through_hoop | rattled_in | off_target | rim_out | rim_bounce | fell_past_rim
    public var method: String  // interpolated | fit | extrapolated | rebound | rattle
    public var tRelease: Double
    public var tApex: Double
    public var tCross: Double
    public var crossOffset: Double  // signed, in hoop half-widths (0 = dead centre)
    public var hoop: Box
    public var trajectory: [Sample]
    public var fit: FlightFit?
    public var releaseAngleDeg: Double?
    public var entryAngleDeg: Double?
}

private func risingOutOfTop(_ a: BallObs, _ b: BallObs) -> Bool {
    if b.t <= a.t { return false }
    let vy = (b.y - a.y) / (b.t - a.t)
    return vy < 0 && b.y + vy * 0.3 < 0
}

private func degrees(_ r: Double) -> Double {
    r * (180.0 / Double.pi)  // CPython: x * (180.0 / pi)
}

private final class Pending {
    var tRelease: Double
    var releaseAngle: Double?
    var fit: FlightFit?
    var tApex: Double
    var tCross: Double
    var xCross: Double
    var offset: Double
    var method: String
    var entryAngle: Double?
    var deadline: Double
    var hoop: Box
    var trajectory: [Sample]
    var rimOut = false
    var bouncedOut = false
    var rattleReason = ""
    var rattleStart = 0.0
    var rattleDeadline = 0.0
    var rattles = 0

    init(tRelease: Double, releaseAngle: Double?, fit: FlightFit?, tApex: Double, tCross: Double, xCross: Double,
         offset: Double, method: String, entryAngle: Double?, deadline: Double, hoop: Box, trajectory: [Sample]) {
        self.tRelease = tRelease
        self.releaseAngle = releaseAngle
        self.fit = fit
        self.tApex = tApex
        self.tCross = tCross
        self.xCross = xCross
        self.offset = offset
        self.method = method
        self.entryAngle = entryAngle
        self.deadline = deadline
        self.hoop = hoop
        self.trajectory = trajectory
    }
}

public final class ShotDetector {
    private enum State {
        case idle, flight, confirm, rattle
    }

    public let cfg: ShotConfig
    public private(set) var discarded = 0
    /// (time, decision) for debugging: arm, abort:<reason>, rim_contact, rattle:<reason>, shot:<outcome>:<reason>, ...
    public private(set) var log: [(t: Double, message: String)] = []

    private var buf: [BallObs] = []
    private var hoop: Box?
    private var state = State.idle
    private var cooldownUntil = -Double.infinity
    private var handT: Double?
    private var armedT = 0.0
    private var apex: BallObs?
    private var descMax: BallObs?
    private var pending: Pending?
    private var count = 0
    private var lastT: Double?
    private var frameDts: [Double] = []  // recent update() intervals (at most 31): the detector's frame rate

    public init(_ cfg: ShotConfig = ShotConfig()) {
        self.cfg = cfg
    }

    // ---- public API -------------------------------------------------------------------

    /// Optional hint from pose estimation: the ball was still in the shooter's hand at `t`.
    public func noteBallInHand(_ t: Double) {
        handT = t
    }

    /// The tracker jumped to a different object: the points so far belong to something else.
    public func noteTrackSwitch(_ t: Double) {
        if state == .idle {
            buf.removeAll()
            log.append((t, "track_switch"))
        }
    }

    public func update(_ t: Double, ball: BallObs?, hoop: Box?) -> [ShotEvent] {
        if let lt = lastT, t > lt {
            frameDts.append(t - lt)
            if frameDts.count > 31 { frameDts.removeFirst() }
        }
        lastT = t
        if let hoop { self.hoop = hoop }
        if let ball { buf.append(ball) }
        while let first = buf.first, t - first.t > cfg.historyS { buf.removeFirst() }
        if self.hoop == nil { return [] }
        switch state {
        case .idle: return idle(t, ball)
        case .flight: return flight(t, ball)
        case .rattle: return rattle(t, ball)
        case .confirm: return confirm(t, ball)
        }
    }

    // ---- helpers ----------------------------------------------------------------------

    private var h: Box { hoop! }

    private func exitedTop() -> Bool {
        if buf.count < 2 { return false }
        return risingOutOfTop(buf[buf.count - 2], buf[buf.count - 1])
    }

    private func backFromTop(_ a: BallObs, _ b: BallObs, _ c: BallObs) -> Bool {
        risingOutOfTop(a, b) && c.t - b.t <= cfg.topExitWaitS && c.y < rimY()
    }

    /// The length unit of every distance setting: hoop_aspect rim widths.
    private func u() -> Double {
        cfg.hoopAspect * h.width
    }

    /// The detector's usual frame interval (median of recent update() intervals); 1/60 s until known.
    private func frameS() -> Double {
        if frameDts.isEmpty { return 1.0 / 60.0 }
        let dts = frameDts.sorted()
        return dts[dts.count / 2]
    }

    private func rimY() -> Double {
        h.y1 + cfg.rimLineFrac * u()
    }

    private func reset(_ t: Double, _ cooldown: Double) {
        state = .idle
        pending = nil
        apex = nil
        descMax = nil
        buf.removeAll()
        cooldownUntil = t + cooldown
    }

    private func abort(_ t: Double, _ reason: String) -> [ShotEvent] {
        discarded += 1
        log.append((t, "abort:\(reason)"))
        reset(t, 0.3)
        return []
    }

    /// Most recent continuous run of observations, trimmed back to where the ball left the hand.
    private func flightPoints(excludeLast: Bool = false) -> [BallObs] {
        let pts = excludeLast ? Array(buf.dropLast()) : buf
        if pts.isEmpty { return [] }
        var start = pts.count - 1
        while start > 0 && (pts[start].t - pts[start - 1].t <= cfg.gapMaxS
            || (start >= 2 && backFromTop(pts[start - 2], pts[start - 1], pts[start]))) {
            start -= 1
        }
        let seg = Array(pts[start...])
        let apexIndex = firstMinIndex(seg) { $0.y }
        // "Held" = moved less than still_speed over one detector frame (the usual update interval).
        let tol = cfg.riseTol * u(), still = cfg.stillSpeed * u() * frameS()
        var j = apexIndex
        while j > 0 {
            let a = seg[j - 1], b = seg[j]
            if a.y < b.y - tol { break }  // it was higher earlier, so this motion began later
            if dist(b.x - a.x, b.y - a.y) < still { break }  // held, not flying
            j -= 1
        }
        return Array(seg[j...])
    }

    /// Release time, release angle, projectile fit and apex time for a flight.
    private func analyse(_ flight: [BallObs]) -> (releaseT: Double, angle: Double?, fit: FlightFit?, tApex: Double) {
        let tApex = flight[firstMinIndex(flight) { $0.y }].t
        var releaseT = flight[0].t
        if let hand = handT, flight[0].t - 0.3 <= hand && hand <= tApex {
            releaseT = max(hand, flight[0].t)
        }
        var pts = flight.filter { $0.t >= releaseT - 1e-9 }.map { Sample(t: $0.t, x: $0.x, y: $0.y) }
        var fit = fitFlight(pts, minPoints: cfg.minFitPoints)
        // Outlier rejection: drop the worst-fitting point and refit until the arc fits cleanly and curves the way
        // gravity does (at most half the points are dropped).
        let trim = cfg.trimRms * u()
        let maxDrop = pts.count / 2
        var dropped = 0
        while let f = fit, f.rms > trim || !f.isPhysical, pts.count > cfg.minFitPoints, dropped < maxDrop {
            let worst = firstMaxIndex(pts) { dist($0.x - f.xAt($0.t), $0.y - f.yAt($0.t)) }
            pts.remove(at: worst)
            dropped += 1
            fit = fitFlight(pts, minPoints: cfg.minFitPoints)
        }
        if let p0 = pts.first, p0.t > releaseT { releaseT = p0.t }
        var angle: Double?
        if let f = fit, f.isPhysical {
            let v = f.velocityAt(f.t0)
            angle = degrees(atan2(-v.vy, abs(v.vx)))
        }
        return (releaseT, angle, fit, tApex)
    }

    private func buildPending(_ flight: [BallObs], _ releaseT: Double, _ relAngle: Double?, _ fit: FlightFit?, _ tApex: Double,
                              _ tCross: Double, _ xCross: Double, _ method: String, _ entry: Double?, _ deadline: Double) -> Pending {
        Pending(tRelease: releaseT, releaseAngle: relAngle, fit: fit, tApex: tApex, tCross: tCross, xCross: xCross,
                offset: (xCross - h.cx) / (h.width / 2), method: method, entryAngle: entry, deadline: deadline, hoop: h,
                trajectory: flight.filter { $0.t >= releaseT - 1e-9 }.map { Sample(t: $0.t, x: $0.x, y: $0.y) })
    }

    // ---- states -----------------------------------------------------------------------

    private func idle(_ t: Double, _ ball: BallObs?) -> [ShotEvent] {
        guard let ball, !(t < cooldownUntil) else { return [] }
        if ball.y < rimY() - cfg.armMargin * u() && abs(ball.x - h.cx) <= cfg.maxDx * h.width {
            state = .flight
            armedT = t
            log.append((t, "arm"))
            apex = ball
            descMax = nil
        }
        return []
    }

    private func flight(_ t: Double, _ ball: BallObs?) -> [ShotEvent] {
        let rimY = rimY()
        if t - armedT > cfg.maxFlightS { return abort(t, "timeout") }
        guard let ball else {
            if let lastB = buf.last, t - lastB.t > cfg.lostS {
                if t - lastB.t <= cfg.topExitWaitS && exitedTop() { return [] }  // high arc above the frame: wait
                return lost(t)
            }
            return []
        }
        if abs(ball.x - h.cx) > cfg.maxDx * h.width { return abort(t, "left_hoop_area") }
        if buf.count >= 2 {
            let prev = buf[buf.count - 2]
            if prev.y < rimY && rimY <= ball.y { return cross(t, prev, ball) }
            let cameDown = buf.count >= 3 && backFromTop(buf[buf.count - 3], prev, ball)
            if ball.t - prev.t > cfg.interpMaxGapS && ball.y < rimY - cfg.reentryMargin * u() && !cameDown {
                let ev = reappearedAbove(t, ball)
                if !ev.isEmpty { return ev }
            }
        }
        if ball.y < apex!.y {
            apex = ball
            descMax = nil
        } else if descMax == nil || ball.y > descMax!.y {
            descMax = ball
        } else {
            let d = descMax!
            if d.y - ball.y > cfg.reboundPx * u()
                && d.y >= rimY - cfg.reboundZone * u()
                && d.y - apex!.y > 0.5 * u()
                && ball.y < rimY {
                return rebound(t)
            }
        }
        return []
    }

    private func cross(_ t: Double, _ prev: BallObs, _ cur: BallObs) -> [ShotEvent] {
        let rimY = rimY()
        let flight = flightPoints()
        if flight.count < 2 || cur.t - flight[0].t < cfg.minFlightS { return abort(t, "short_flight") }
        var (releaseT, relAngle, fit, tApex) = analyse(flight)
        var hitRim = false
        if let f = fit, !f.isPhysical || f.rms > cfg.maxFitRms * u() {
            // A shot off the front rim: if the arc up to where the ball first reached the rim is a parabola,
            // judge it by where it goes from there, like any rim contact.
            if let pre = preContact(flight), pre.count >= cfg.minFitPoints, pre[pre.count - 1].t - pre[0].t >= cfg.minFlightS {
                let a2 = analyse(pre)
                if let f2 = a2.fit, f2.isPhysical, f2.rms <= cfg.maxFitRms * u() {
                    (releaseT, relAngle, fit, tApex, hitRim) = (a2.releaseT, a2.angle, f2, a2.tApex, true)
                    log.append((t, "rim_contact"))
                }
            }
            if !hitRim {
                return abort(t, "not_parabolic(rms=\(pyFixed(f.rms / u(), 2))h,n=\(f.n),physical=\(pyBool(f.isPhysical)))")
            }
        }

        let gap = cur.t - prev.t
        var tC: Double?
        var xC = 0.0
        var method = "interpolated"
        if gap > cfg.interpMaxGapS, let f = fit, !hitRim {  // after a rim contact the arc no longer applies
            if let tc = f.timeAtY(rimY), prev.t - 1e-6 <= tc && tc <= cur.t + 1e-6 {
                (tC, xC, method) = (tc, f.xAt(tc), "fit")
            }
        }
        if tC == nil {
            if gap > cfg.gapMaxS { return abort(t, "gap_too_long") }
            let fr = (rimY - prev.y) / (cur.y - prev.y)
            (tC, xC) = (prev.t + fr * gap, prev.x + fr * (cur.x - prev.x))
        }
        let tCross = tC!
        let vx: Double, vy: Double
        if let f = fit, f.isPhysical, !hitRim {
            (vx, vy) = f.velocityAt(tCross)
        } else {
            (vx, vy) = (cur.x - prev.x, cur.y - prev.y)
        }
        let entry = degrees(atan2(vy, abs(vx)))
        if hitRim { method = "rattle" }

        let pend = buildPending(flight, releaseT, relAngle, fit, tApex, tCross, xC, method, entry, tCross + cfg.confirmS)
        if abs(pend.offset) > cfg.attemptMaxOffset {
            return abort(t, "too_far_from_hoop(offset=\(pyFixed(pend.offset, 1, forceSign: true)))")
        }
        pending = pend
        state = .confirm
        return []
    }

    /// The flight up to the first point where the ball reached the rim (nil if it never came near it).
    private func preContact(_ flight: [BallObs]) -> [BallObs]? {
        let rimY = rimY(), u = u()
        for (k, o) in flight.enumerated()
        where abs(o.x - h.cx) <= h.width && rimY - cfg.rimContactAbove * u <= o.y && o.y <= rimY + cfg.rimContactBelow * u {
            return Array(flight[...k])
        }
        return nil
    }

    /// Ball vanished above the rim line; judge from the fitted arc if it is trustworthy.
    private func lost(_ t: Double) -> [ShotEvent] {
        let rimY = rimY()
        let flight = flightPoints()
        if flight.count < cfg.minFitPoints || flight[flight.count - 1].t - flight[0].t < cfg.minFlightS {
            return abort(t, "lost_too_few_points(n=\(flight.count))")
        }
        let (releaseT, relAngle, fit, tApex) = analyse(flight)
        guard let f = fit, f.isPhysical, !(f.rms > cfg.maxFitRms * u()) else { return abort(t, "lost_bad_fit") }
        let last = flight[flight.count - 1]
        guard let tc = f.timeAtY(rimY), !(tc < last.t), !(tc - last.t > cfg.maxExtrapS) else {
            return abort(t, "lost_no_crossing")
        }
        let v = f.velocityAt(tc)
        let entry = degrees(atan2(v.vy, abs(v.vx)))
        let pend = buildPending(flight, releaseT, relAngle, fit, tApex, tc, f.xAt(tc), "extrapolated", entry,
                                max(tc + cfg.confirmS, t))
        if abs(pend.offset) > cfg.attemptMaxOffset { return abort(t, "lost_too_far_from_hoop") }
        pending = pend
        state = .confirm
        return []
    }

    /// Ball was hidden near the rim and came back above the rim line after the arc said it should have dropped
    /// below it: deflected out.
    private func reappearedAbove(_ t: Double, _ ball: BallObs) -> [ShotEvent] {
        let rimY = rimY()
        let flight = flightPoints(excludeLast: true)
        if flight.count < cfg.minFitPoints { return [] }
        let (releaseT, relAngle, fit, tApex) = analyse(flight)
        guard let f = fit, f.isPhysical, !(f.rms > cfg.maxFitRms * u()) else { return [] }
        guard let tc = f.timeAtY(rimY), !(tc < flight[flight.count - 1].t), !(tc >= ball.t - 0.02) else { return [] }
        let offset = (f.xAt(tc) - h.cx) / (h.width / 2)
        if abs(offset) > cfg.attemptMaxOffset { return [] }
        let pend = buildPending(flight, releaseT, relAngle, fit, tApex, tc, f.xAt(tc), "extrapolated", nil, t)
        return startRattle(t, pend, "rim_bounce")
    }

    /// Ball came down to the rim, then reversed upward without ever passing below it.
    private func rebound(_ t: Double) -> [ShotEvent] {
        let d = descMax!
        let flight = flightPoints().filter { $0.t <= d.t }  // approach only, not the bounce
        if flight.count < 2 { return abort(t, "rebound_too_few_points") }
        let (releaseT, relAngle, fit, tApex) = analyse(flight)
        let offset = (d.x - h.cx) / (h.width / 2)
        if abs(offset) > cfg.attemptMaxOffset { return abort(t, "rebound_too_far_from_hoop") }
        let pend = buildPending(flight, releaseT, relAngle, fit, tApex, d.t, d.x, "rebound", nil, t)
        return startRattle(t, pend, "rim_bounce")
    }

    /// The ball touched the rim and came back up: wait for it to settle before calling the shot.
    private func startRattle(_ t: Double, _ p: Pending, _ reason: String) -> [ShotEvent] {
        p.rattleReason = reason
        p.rattleStart = t
        p.rattleDeadline = t + cfg.rattleS
        p.rattles += 1
        pending = p
        state = .rattle
        log.append((t, "rattle:\(reason)"))
        return []
    }

    private func rattle(_ t: Double, _ ball: BallObs?) -> [ShotEvent] {
        let p = pending!, rimY = rimY()
        if let ball, buf.count >= 2 {
            let prev = buf[buf.count - 2]
            if prev.t >= p.rattleStart && prev.y < rimY && rimY <= ball.y {  // coming down past the rim line
                let f = (rimY - prev.y) / (ball.y - prev.y)
                let tc = prev.t + f * (ball.t - prev.t)
                let off = (prev.x + f * (ball.x - prev.x) - h.cx) / (h.width / 2)
                if abs(off) <= cfg.makeHalfwidth {
                    // Dropped in after the rim: confirm like any crossing (pop-out, net braking).
                    let lastT = p.trajectory.last?.t ?? -Double.infinity
                    p.trajectory += buf.filter { $0.t > lastT }.map { Sample(t: $0.t, x: $0.x, y: $0.y) }
                    p.tCross = tc
                    p.offset = off
                    p.method = "rattle"
                    p.rimOut = false
                    p.xCross = prev.x + f * (ball.x - prev.x)
                    p.bouncedOut = false
                    p.deadline = tc + cfg.confirmS
                    state = .confirm
                    return []
                }
                return rattleMiss(t, tc)
            }
            if abs(ball.x - h.cx) > cfg.rattleMaxDx * h.width { return rattleMiss(t, p.tCross) }
        }
        if t >= p.rattleDeadline { return rattleMiss(t, p.tCross) }
        return []
    }

    private func rattleMiss(_ t: Double, _ tCross: Double) -> [ShotEvent] {
        let p = pending!
        let ev = event(.missed, p.rattleReason, p.method, p.tRelease, p.tApex, tCross, p.offset, p.hoop, p.trajectory,
                       p.fit, p.releaseAngle, p.entryAngle)
        reset(t, cfg.cooldownS)
        return [ev]
    }

    private func confirm(_ t: Double, _ ball: BallObs?) -> [ShotEvent] {
        let p = pending!
        if let ball, ball.t > p.tCross {
            if ball.y < rimY() - cfg.reentryMargin * u() && abs(ball.x - h.cx) <= 1.5 * h.width {
                p.rimOut = true
                if abs(p.offset) <= cfg.makeHalfwidth && p.rattles < cfg.maxRattles {
                    return startRattle(t, p, "rim_out")
                }
                return finish(t)
            }
            if ball.y <= h.y2 && movedBack(p, ball) { p.bouncedOut = true }
        }
        if t >= p.deadline { return finish(t) }
        return []
    }

    /// Least-squares downward speed of (t, y) points, in hoop heights per second.
    private func verticalSpeed(_ pts: [(Double, Double)]) -> Double? {
        guard let s = slope(pts) else { return nil }
        return s / u()
    }

    /// Least-squares d(value)/dt of (t, value) points, in pixels per second (plain loops, like the Python).
    private func slope(_ pts: [(Double, Double)]) -> Double? {
        if pts.count < 2 { return nil }
        var st = 0.0, sy = 0.0
        for q in pts {
            st += q.0
            sy += q.1
        }
        let mt = st / Double(pts.count), my = sy / Double(pts.count)
        var den = 0.0, num = 0.0
        for q in pts {
            let dt = q.0 - mt
            den += dt * dt
            num += dt * (q.1 - my)
        }
        return den == 0 ? nil : num / den
    }

    /// The ball is back towards where it came from by back_out_frac hoop widths since the crossing.
    private func movedBack(_ p: Pending, _ ball: BallObs) -> Bool {
        let pre = p.trajectory.filter { p.tCross - 0.15 <= $0.t && $0.t < p.tCross }
        if pre.count < 2 || pre[pre.count - 1].x == pre[0].x { return false }
        let back = pre[pre.count - 1].x > pre[0].x ? (p.xCross - ball.x) : (ball.x - p.xCross)
        return back / h.width >= cfg.backOutFrac
    }

    /// True when the ball is clearly seen falling after the crossing without being braked by the net.
    private func fellPastRim(_ p: Pending) -> Bool {
        let window = p.trajectory.filter { p.tCross - 0.15 <= $0.t && $0.t < p.tCross }
        let after = buf.filter { p.tCross < $0.t && $0.t <= p.tCross + cfg.netWindowS }
        let pre = window.map { ($0.t, $0.y) }
        let post = after.map { ($0.t, $0.y) }
        if post.count < cfg.netMinPoints || post[post.count - 1].0 - post[0].0 < 0.12 { return false }
        let vPre = verticalSpeed(pre), vPost = verticalSpeed(post)
        let minPre = p.method == "rattle" ? cfg.netMinSpeed : 0.0
        guard let vPre, let vPost, !(vPre <= minPre) else { return false }
        if !(vPost >= cfg.netMinSpeed && vPost >= cfg.netBrakeRatio * vPre) { return false }
        // Caught by the net: a shot reaches the rim moving fast sideways; the net stops that, a ball falling past
        // the rim keeps it.
        let sxPre = slope(window.map { ($0.t, $0.x) }), sxPost = slope(after.map { ($0.t, $0.x) })
        if let sxPre, let sxPost, abs(sxPre) / h.width >= cfg.netCatchMinVx {
            if abs(sxPost) <= cfg.netCatchRatio * abs(sxPre) { return false }
        }
        return true
    }

    private func finish(_ t: Double) -> [ShotEvent] {
        let p = pending!
        let through = abs(p.offset) <= cfg.makeHalfwidth
        let outcome: Outcome, reason: String
        if through && p.rimOut {
            (outcome, reason) = (.missed, "rim_out")
        } else if through && p.bouncedOut {
            (outcome, reason) = (.missed, "rim_bounce")
        } else if through && fellPastRim(p) {
            (outcome, reason) = (.missed, "fell_past_rim")
        } else if through {
            (outcome, reason) = (.made, p.method == "rattle" ? "rattled_in" : "through_hoop")
        } else {
            (outcome, reason) = (.missed, "off_target")
        }
        let ev = event(outcome, reason, p.method, p.tRelease, p.tApex, p.tCross, p.offset, p.hoop, p.trajectory, p.fit,
                       p.releaseAngle, p.entryAngle)
        reset(t, cfg.cooldownS)
        return [ev]
    }

    private func event(_ outcome: Outcome, _ reason: String, _ method: String, _ tRelease: Double, _ tApex: Double,
                       _ tCross: Double, _ offset: Double, _ hoop: Box, _ traj: [Sample], _ fit: FlightFit?,
                       _ rel: Double?, _ entry: Double?) -> ShotEvent {
        count += 1
        log.append((tCross, "shot:\(outcome.rawValue):\(reason)"))
        return ShotEvent(index: count, outcome: outcome, reason: reason, method: method, tRelease: tRelease, tApex: tApex,
                         tCross: tCross, crossOffset: offset, hoop: hoop, trajectory: traj, fit: fit,
                         releaseAngleDeg: rel, entryAngleDeg: entry)
    }
}
