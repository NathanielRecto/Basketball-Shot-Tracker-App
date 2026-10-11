// Port of Python_Raw/src/shottracker/pipeline.py without pose: detections -> static filter -> ball tracker ->
// shot judge, with a hoop box (found from the rim, or marked by hand).

public struct FrameResult: Sendable {
    public var t: Double
    public var ball: BallObs?
    public var events: [ShotEvent]
}

public final class ShotPipeline {
    public let params: Params
    public private(set) var hoop: Box
    public let staticFilter: StaticSuppressor?
    public let tracker: BallTracker
    public let shots: ShotDetector
    public private(set) var events: [ShotEvent] = []

    public init(hoop: Box, params: Params = .defaults, suppressStatic: Bool = true) {
        self.params = params
        self.hoop = hoop
        staticFilter = suppressStatic ? StaticSuppressor(params.staticFilter) : nil
        tracker = BallTracker(params.tracker)
        shots = ShotDetector(params.shot)
    }

    /// Moves the hoop (the camera moved), only between shots so no call is judged against two hoops.
    /// Python always uses one fixed hoop per video; this is for a phone that is not perfectly still.
    @discardableResult
    public func moveHoop(to box: Box) -> Bool {
        guard shots.isIdle else { return false }
        hoop = box
        return true
    }

    /// One frame's detections (already at or above `params.detector.conf`), in frame pixels.
    public func step(_ t: Double, _ detections: [Detection]) -> FrameResult {
        var dets = detections
        if let staticFilter { dets = staticFilter.filter(t, dets) }
        let ball = tracker.update(t, dets, hoop: hoop)
        if tracker.switched { shots.noteTrackSwitch(t) }
        let found = shots.update(t, ball: ball, hoop: hoop)
        events += found
        return FrameResult(t: t, ball: ball, events: found)
    }
}
