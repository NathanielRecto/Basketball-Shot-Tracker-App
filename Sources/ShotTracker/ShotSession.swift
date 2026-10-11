import ShotCore

/// Live glue between the detector and the shot judge. The hoop comes from the rims the detector sees
/// (`hoopFromRims`, the Python `find_hoop` rim path: the biggest rim, i.e. the nearest hoop, plus its net), over a
/// rolling window of recent frames, so it is found automatically and follows the rim if the phone moves. It only
/// moves between shots (`ShotPipeline.moveHoop`). Every detector frame's ball boxes go through `ShotPipeline`
/// (static filter, tracker, shot judge: golden-tested against the Python). Use from one queue only (inference).
final class ShotSession: @unchecked Sendable {
    struct Update {
        var hoop: Box?
        var ambiguity: Double?
        var sampled: Int  // frames looked at so far while finding the hoop
        var ball: BallObs?
        var events: [ShotEvent]
        var hoopMoved: Bool
    }

    /// Rolling window of detector frames the hoop is measured over (~1.6-2 s at the phone's 22-27 fps).
    static let window = 45
    static let rimConf = 0.25  // as Python's find_hoop
    static let lockFrames = 5  // frames with a rim needed to lock the hoop the first time
    static let followFrames = 15  // ... and to move it later (a player standing in front must not drag it)
    /// The rim must have shifted this many rim widths (centre, top or width) before the hoop follows it;
    /// smaller changes are detection jitter.
    static let moveFrac = 0.15

    let params: Params
    private var rims: [[Box]] = []
    private var pipeline: ShotPipeline?
    private var hoop: Box?
    private var ambiguity: Double?

    init(params: Params = .defaults) {
        self.params = params
    }

    /// Forget the hoop and find it again from scratch (the zoom changed: everything moves at once).
    func refindHoop() {
        rims = []
        pipeline = nil
        hoop = nil
        ambiguity = nil
    }

    /// Start counting again with the same hoop.
    func resetShots() {
        if let hoop { pipeline = ShotPipeline(hoop: hoop, params: params) }
    }

    func feed(_ out: Detector.Output) -> Update {
        rims.append(out.detections.filter { $0.label == "rim_only" && $0.conf >= Self.rimConf }.map(\.box))
        if rims.count > Self.window { rims.removeFirst() }

        guard let pipeline else {
            if rims.count == Self.window {
                let found = hoopFromRims(rims, minFrames: Self.lockFrames)
                if let h = found.hoop {
                    hoop = h
                    ambiguity = found.ambiguity
                    self.pipeline = ShotPipeline(hoop: h, params: params)
                }
            }
            return Update(hoop: hoop, ambiguity: ambiguity, sampled: rims.count, ball: nil, events: [], hoopMoved: false)
        }

        var moved = false
        let found = hoopFromRims(rims, minFrames: Self.followFrames)
        if let h = found.hoop, let current = hoop, Self.shift(from: current, to: h) > Self.moveFrac,
           pipeline.moveHoop(to: h) {
            hoop = h
            ambiguity = found.ambiguity
            moved = true
        }
        let balls = out.detections.filter { $0.label == "ball" && $0.conf >= params.detector.conf }
        let r = pipeline.step(out.t, balls)
        return Update(hoop: hoop, ambiguity: ambiguity, sampled: rims.count, ball: r.ball, events: r.events, hoopMoved: moved)
    }

    /// How far a hoop box moved, in its rim widths: the largest change of centre x, top or width.
    static func shift(from a: Box, to b: Box) -> Double {
        max(abs(b.cx - a.cx), abs(b.y1 - a.y1), abs(b.width - a.width)) / a.width
    }
}
