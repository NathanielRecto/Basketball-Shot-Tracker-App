import Foundation

/// A recorded session as the Sessions screen shows it (read from its folder's session.json).
struct SessionSummary: Identifiable, Hashable {
    var folder: URL
    var started: Date
    var lens: String
    var seconds: Double
    var shots: [SessionRecorder.Shot]

    var id: URL { folder }
    var videoURL: URL { folder.appendingPathComponent("video.mov") }
    var hasVideo: Bool { FileManager.default.fileExists(atPath: videoURL.path) }
    var made: Int { shots.filter { $0.outcome == "made" }.count }
    var attempts: Int { shots.count }
    var fgText: String { attempts == 0 ? "–" : "\(Int((100 * Double(made) / Double(attempts)).rounded()))%" }

    static func == (a: SessionSummary, b: SessionSummary) -> Bool { a.folder == b.folder }
    func hash(into h: inout Hasher) { h.combine(folder) }
}

/// The recorded sessions in Documents/Sessions (SessionRecorder's folders), newest first.
enum SessionStore {
    static func load() -> [SessionSummary] {
        let fm = FileManager.default
        let root = SessionRecorder.sessionsFolder
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let iso = ISO8601DateFormatter()
        return dirs.compactMap { dir -> SessionSummary? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let log = try? decoder.decode(SessionRecorder.Log.self, from: data) else { return nil }
            return SessionSummary(folder: dir, started: iso.date(from: log.started) ?? .distantPast, lens: log.lens,
                                  seconds: log.frames.last?.t ?? 0, shots: log.shots)
        }
        .sorted { $0.started > $1.started }
    }

    static func delete(_ s: SessionSummary) throws {
        try FileManager.default.removeItem(at: s.folder)
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
