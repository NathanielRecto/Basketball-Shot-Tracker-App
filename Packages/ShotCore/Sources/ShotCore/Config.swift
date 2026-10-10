import Foundation

// Every setting of the static filter, ball tracker and shot judge, with the Python defaults
// (Python_Raw/src/shottracker/tracking.py, config.py). The golden tests decode Python's params.json and require
// it to equal these defaults, so the two can never drift apart silently. Distances are in rim widths ("hoop
// heights" = hoop_aspect rim widths), times in seconds.

public struct StaticFilterConfig: Codable, Equatable, Sendable {
    public var windowS = 8.0
    public var minPresence = 0.15
    public var radius = 0.6
    public var minStaticS = 3.0
    public var holdS = 30.0

    public init() {}
}

public struct TrackerConfig: Codable, Equatable, Sendable {
    public var initConf = 0.4
    public var lostS = 0.5
    public var gateDiams = 2.5
    public var minGatePx = 25.0
    public var confirmS = 0.15
    public var minMove = 0.3
    public var maxSpeed = 120.0
    public var switchSpeed = 12.0
    public var switchHits = 4
    public var switchRatio = 0.5
    public var maxTracklets = 8
    public var exitWaitS = 1.5
    public var switchMinUp = 0.5
    public var exitHorizonS = 0.3

    public init() {}
}

public struct ShotConfig: Codable, Equatable, Sendable {
    public var rimLineFrac = 0.15
    public var hoopAspect = 1.0
    public var armMargin = 0.15
    public var maxDx = 5.0
    public var historyS = 2.5
    public var gapMaxS = 0.50
    public var maxFlightS = 3.5
    public var lostS = 0.35
    public var topExitWaitS = 1.5
    public var maxExtrapS = 0.8
    public var minFitPoints = 5
    public var maxFitRms = 0.6
    public var trimRms = 0.2
    public var riseTol = 0.15
    public var stillSpeed = 4.8
    public var interpMaxGapS = 0.10
    public var minFlightS = 0.2
    public var makeHalfwidth = 0.75
    public var attemptMaxOffset = 8.0
    public var confirmS = 0.45
    public var netWindowS = 0.25
    public var netMinPoints = 4
    public var netMinSpeed = 3.0
    public var netBrakeRatio = 1.3
    public var backOutFrac = 0.75
    public var netCatchMinVx = 3.0
    public var netCatchRatio = 0.5
    public var rimContactAbove = 0.6
    public var rimContactBelow = 0.2
    public var reentryMargin = 0.25
    public var reboundPx = 0.35
    public var reboundZone = 1.0
    public var cooldownS = 0.7
    public var rattleS = 2.0
    public var rattleMaxDx = 3.0
    public var maxRattles = 2

    public init() {}
}

/// `params.json` from Python_Raw/scripts/export_app_fixtures.py (format "shottracker-params/1").
public struct Params: Codable, Equatable, Sendable {
    public struct DetectorParams: Codable, Equatable, Sendable {
        public var conf = 0.15

        public init() {}
    }

    public var format = "shottracker-params/1"
    public var detector = DetectorParams()
    public var staticFilter = StaticFilterConfig()
    public var tracker = TrackerConfig()
    public var shot = ShotConfig()

    public init() {}

    public static let defaults = Params()

    public static func load(from data: Data) throws -> Params {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Params.self, from: data)
    }
}
