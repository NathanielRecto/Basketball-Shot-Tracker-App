import ShotCore

/// Live glue between the detector and the shot judge. First it finds the hoop from the rims seen in the first
/// couple of seconds (`hoopFromRims`, the Python `find_hoop` rim path); then every detector frame's ball boxes go
/// through `ShotPipeline` (static filter, tracker, shot judge: golden-tested against the Python). Use from one
/// queue only (the inference queue).
final class ShotSession: @unchecked Sendable {
    struct Update {
        var hoop: Box?
        var ambiguity: Double?
        var sampled: Int  // frames looked at while finding the hoop
        var ball: BallObs?
        var events: [ShotEvent]
    }

    /// Detector frames to find the hoop from (~2 s at the phone's 22-27 fps). Python samples 60 frames of a video.
    static let findFrames = 45
    static let rimConf = 0.25  // as Python's find_hoop

    let params: Params
    private var rims: [[Box]] = []
    private var pipeline: ShotPipeline?
    private var hoop: Box?
    private var ambiguity: Double?

    init(params: Params = .defaults) {
        self.params = params
    }

    /// Forget the hoop and look for it again (the camera moved, or the lens changed).
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
        guard let pipeline else {
            rims.append(out.detections.filter { $0.label == "rim_only" && $0.conf >= Self.rimConf }.map(\.box))
            if rims.count > Self.findFrames { rims.removeFirst() }  // not found yet: keep looking at the latest frames
            if rims.count == Self.findFrames {
                let found = hoopFromRims(rims)
                if let h = found.hoop {
                    hoop = h
                    ambiguity = found.ambiguity
                    self.pipeline = ShotPipeline(hoop: h, params: params)
                }
            }
            return Update(hoop: hoop, ambiguity: ambiguity, sampled: rims.count, ball: nil, events: [])
        }
        let balls = out.detections.filter { $0.label == "ball" && $0.conf >= params.detector.conf }
        let r = pipeline.step(out.t, balls)
        return Update(hoop: hoop, ambiguity: ambiguity, sampled: rims.count, ball: r.ball, events: r.events)
    }
}
