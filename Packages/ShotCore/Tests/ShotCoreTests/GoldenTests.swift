import Foundation
import Testing
@testable import ShotCore

/// The Swift port must make exactly the decisions the Python reference made.
///
/// Fixtures/ is Python_Raw/scripts/export_app_fixtures.py's output (manifest.json names the Python commit): per-frame
/// detections in, and what Python decided out (the tracked ball each frame, track switches, every shot call and the
/// decision log). Numbers are compared exactly: a difference means the port's arithmetic differs (often an
/// operation in another order), so fix the port, never loosen the test (Python_Raw/docs/app_port.md).

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

struct GoldenCase: Decodable {
    struct Frame: Decodable {
        struct Expect: Decodable {
            var ball: [Double]?
            var switched: Bool
        }

        var t: Double
        var balls: [[Double]]
        var expect: Expect
    }

    struct Event: Decodable, Equatable {
        var tRelease: Double
        var tApex: Double
        var tCross: Double
        var outcome: String
        var reason: String
        var method: String
        var crossOffset: Double
    }

    struct LogLine: Decodable, Equatable {
        var t: Double
        var message: String

        init(t: Double, message: String) {
            self.t = t
            self.message = message
        }

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            t = try c.decode(Double.self)
            message = try c.decode(String.self)
        }
    }

    struct Expect: Decodable {
        var events: [Event]
        var log: [LogLine]
    }

    var format: String
    var name: String
    var hoop: [Double]
    var frames: [Frame]
    var expect: Expect

    static func load(_ file: String) throws -> GoldenCase {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GoldenCase.self, from: Data(contentsOf: fixtures.appendingPathComponent("golden/\(file)")))
    }
}

/// Replays a case; nil when every frame, shot and log line matched exactly, else the first difference.
func firstDifference(_ c: GoldenCase, params: Params = .defaults) -> (diff: String?, shots: Int) {
    let pipe = ShotPipeline(hoop: Box(c.hoop[0], c.hoop[1], c.hoop[2], c.hoop[3]), params: params)
    var diff: String? = c.format == "shottracker-golden/1" ? nil : "unknown format \(c.format)"
    for (i, f) in c.frames.enumerated() {
        let dets = f.balls.map { Detection(classIndex: 0, label: "ball", conf: $0[4], box: Box($0[0], $0[1], $0[2], $0[3])) }
        let r = pipe.step(f.t, dets)
        if diff == nil {
            let got = r.ball.map { [$0.x, $0.y, $0.diameter] }
            if got != f.expect.ball || pipe.tracker.switched != f.expect.switched {
                diff = "frame \(i) (t=\(f.t)): ball \(String(describing: got)) switched \(pipe.tracker.switched) (port) vs "
                    + "ball \(String(describing: f.expect.ball)) switched \(f.expect.switched) (Python)"
            }
        }
    }
    let events = pipe.events.map {
        GoldenCase.Event(tRelease: $0.tRelease, tApex: $0.tApex, tCross: $0.tCross, outcome: $0.outcome.rawValue,
                         reason: $0.reason, method: $0.method, crossOffset: $0.crossOffset)
    }
    let log = pipe.shots.log.map { GoldenCase.LogLine(t: $0.t, message: $0.message) }
    if diff == nil {
        for (i, (a, b)) in zip(log, c.expect.log).enumerated() where a != b {
            diff = "log[\(i)]: \(a) (port) vs \(b) (Python)"
            break
        }
    }
    if diff == nil && log.count != c.expect.log.count { diff = "log: \(log.count) lines (port) vs \(c.expect.log.count) (Python)" }
    if diff == nil {
        for (i, (a, b)) in zip(events, c.expect.events).enumerated() where a != b {
            diff = "events[\(i)]: \(a) (port) vs \(b) (Python)"
            break
        }
    }
    if diff == nil && events.count != c.expect.events.count {
        diff = "events: \(events.count) (port) vs \(c.expect.events.count) (Python)"
    }
    return (diff, events.count)
}

@Suite struct GoldenTests {
    static let cases = (try? FileManager.default.contentsOfDirectory(atPath: fixtures.appendingPathComponent("golden").path))?
        .filter { $0.hasSuffix(".json") }.sorted() ?? []

    @Test func hasTheGoldenCases() {
        #expect(Self.cases.contains("sim_all_shot_types.json"))
        #expect(Self.cases.count >= 4)
    }

    @Test(arguments: cases)
    func portMatchesPython(_ file: String) throws {
        let c = try GoldenCase.load(file)
        let r = firstDifference(c)
        #expect(r.diff == nil, "\(file): \(r.diff ?? "")")
        #expect(r.shots == c.expect.events.count)
    }

    @Test func noticesAChangedSetting() throws {
        var nudged = Params.defaults
        nudged.shot.makeHalfwidth = 0.01  // every simulated make lands farther from centre than this
        #expect(firstDifference(try GoldenCase.load("sim_all_shot_types.json"), params: nudged).diff != nil)
    }

    @Test func paramsMatchPython() throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("params.json"))
        #expect(try Params.load(from: data) == Params.defaults)
        // Same keys too: a setting added in Python must be added here (decoding ignores unknown keys).
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func keys(_ value: Any) -> [String] { Mirror(reflecting: value).children.compactMap(\.label).map(snake).sorted() }
        #expect(((json["static_filter"] as! [String: Any]).keys.sorted()) == keys(StaticFilterConfig()))
        #expect(((json["tracker"] as! [String: Any]).keys.sorted()) == keys(TrackerConfig()))
        #expect(((json["shot"] as! [String: Any]).keys.sorted()) == keys(ShotConfig()))
    }
}

/// camelCase -> snake_case, the inverse of JSONDecoder's convertFromSnakeCase for these names.
private func snake(_ s: String) -> String {
    var out = ""
    for ch in s {
        if ch.isUppercase {
            out += "_" + ch.lowercased()
        } else {
            out.append(ch)
        }
    }
    return out
}

@Suite struct PyFormatTests {
    @Test func formatsLikePython() {
        #expect(pyFixed(0.125, 2) == "0.12")  // f"{0.125:.2f}": an exact tie, rounded to even
        #expect(pyFixed(0.375, 2) == "0.38")
        #expect(pyFixed(2.5, 0) == "2")
        #expect(pyFixed(-0.04, 1, forceSign: true) == "-0.0")
        #expect(pyFixed(3.14159, 1, forceSign: true) == "+3.1")
        #expect(pyFixed(9.96, 1) == "10.0")
        #expect(pyFixed(0.29, 2) == "0.29")
        #expect(pyFixed(0, 2) == "0.00")
        #expect(pyFixed(0.005, 2) == "0.01")  // 0.005 is stored as 0.005000000000000000104...
        #expect(pyBool(true) == "True" && pyBool(false) == "False")
    }

    @Test func fitsAParabolaExactly() throws {
        // y = 2 tau^2 - 3 tau + 5, x = 4 tau + 1, at tau = 0, 0.5, ..., 2
        let pts = (0...4).map { i -> Sample in
            let tau = Double(i) * 0.5
            return Sample(t: 10 + tau, x: 4 * tau + 1, y: 2 * tau * tau - 3 * tau + 5)
        }
        let f = try #require(fitFlight(pts))
        #expect(abs(f.c2 - 2) < 1e-9 && abs(f.c1 + 3) < 1e-9 && abs(f.c0 - 5) < 1e-9)
        #expect(abs(f.xA - 4) < 1e-9 && abs(f.xB - 1) < 1e-9 && f.rms < 1e-9 && f.isPhysical)
        #expect(fitFlight(Array(pts.prefix(3))) == nil)
    }
}
