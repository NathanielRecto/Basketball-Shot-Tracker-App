import AVFoundation
import Foundation
import ShotCore

/// Records a session: the camera frames to `video.mov` (HEVC, the frames the detector saw) and, in `session.json`,
/// every frame's ball and rim boxes, the hoop and every shot call, timed from the video's first frame. That is
/// what a live test needs: the video to label blind, the app's calls to score, and the detections so the research
/// repo can replay the exact session (balls use the layout of its debug.json: cx, cy, w, h, conf).
/// Folders go to Documents/Sessions/<date_time>/, visible in the Files app and Apple Devices file sharing.
///
/// `append` runs on the camera queue, `log` on the inference queue, start / stop on the main thread.
final class SessionRecorder: @unchecked Sendable {
    struct Frame: Codable {
        var t: Double
        var balls: [[Double]]  // cx, cy, w, h, conf
        var rims: [[Double]]  // x1, y1, x2, y2, conf
    }

    struct Shot: Codable {
        var tRelease: Double
        var tApex: Double
        var tCross: Double
        var outcome: String
        var reason: String
        var method: String
        var crossOffset: Double
    }

    struct Hoop: Codable {
        var t: Double
        var box: [Double]
    }

    struct Model: Codable {
        var name: String
        var weightsSha256: String
        var precision: String
    }

    struct Log: Codable {
        var format = "shottracker-phone-session/1"
        var video = "video.mov"
        var started: String
        var lens: String
        var frameSize: [Int] = []
        var model: Model
        var conf: Double
        var hoops: [Hoop] = []
        var shots: [Shot] = []
        var frames: [Frame] = []
        var videoFramesDropped = 0  // camera frames the encoder was not ready for
    }

    struct Saved {
        var folder: URL
        var seconds: Double
        var shots: Int
    }

    enum RecorderError: LocalizedError {
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .cannotWrite(let why): "Could not record: \(why)"
            }
        }
    }

    private let lock = NSLock()
    private var folder: URL?
    private var log: Log?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var t0: Double?  // presentation time of the first recorded frame
    private var lastT = 0.0
    private var lastHoop: Box?

    var isRecording: Bool { lock.withLock { log != nil } }

    static var sessionsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sessions")
    }

    /// Starts a session folder; the video file is created with the first frame (its size is known then).
    func start(lens: String, model: ModelInfo) throws -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let now = Date()
        let dir = Self.sessionsFolder.appendingPathComponent(stamp.string(from: now))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.withLock {
            folder = dir
            log = Log(started: ISO8601DateFormatter().string(from: now), lens: lens,
                      model: Model(name: model.name, weightsSha256: model.weightsSha256, precision: model.precision),
                      conf: model.conf)
            writer = nil
            input = nil
            t0 = nil
            lastT = 0
            lastHoop = nil
        }
        return dir
    }

    /// Camera queue: every delivered camera frame goes into the video.
    func append(_ sample: CMSampleBuffer) {
        lock.withLock {
            guard log != nil, let folder else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if writer == nil {
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                do {
                    let wr = try AVAssetWriter(outputURL: folder.appendingPathComponent("video.mov"), fileType: .mov)
                    let inp = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
                    ])
                    inp.expectsMediaDataInRealTime = true
                    guard wr.canAdd(inp) else { return }
                    wr.add(inp)
                    guard wr.startWriting() else { return }
                    wr.startSession(atSourceTime: pts)
                    writer = wr
                    input = inp
                    t0 = pts.seconds
                    log?.frameSize = [w, h]
                } catch {
                    return
                }
            }
            if let input, input.isReadyForMoreMediaData {
                input.append(sample)
            } else {
                log?.videoFramesDropped += 1
            }
        }
    }

    /// Inference queue: the frame's detections, the hoop when it changes, and any shot calls.
    func log(_ out: Detector.Output, _ update: ShotSession.Update) {
        lock.withLock {
            guard log != nil, let t0, out.t >= t0 else { return }
            let t = out.t - t0
            lastT = t
            let balls = out.detections.filter { $0.label == "ball" }
                .map { [$0.box.cx, $0.box.cy, $0.box.width, $0.box.height, $0.conf] }
            let rims = out.detections.filter { $0.label == "rim_only" }
                .map { [$0.box.x1, $0.box.y1, $0.box.x2, $0.box.y2, $0.conf] }
            log?.frames.append(Frame(t: t, balls: balls, rims: rims))
            if let h = update.hoop, h != lastHoop {
                log?.hoops.append(Hoop(t: t, box: [h.x1, h.y1, h.x2, h.y2]))
                lastHoop = h
            }
            for ev in update.events {
                log?.shots.append(Shot(tRelease: ev.tRelease - t0, tApex: ev.tApex - t0, tCross: ev.tCross - t0,
                                       outcome: ev.outcome.rawValue, reason: ev.reason, method: ev.method,
                                       crossOffset: ev.crossOffset))
            }
        }
    }

    /// Finishes the video, writes session.json, and reports where it went (nil if nothing was recorded).
    func stop(completion: @escaping @Sendable (Result<Saved, Error>?) -> Void) {
        let (wr, inp, dir, finished, seconds) = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?, URL?, Log?, Double) in
            defer {
                log = nil
                writer = nil
                input = nil
                folder = nil
                t0 = nil
            }
            return (writer, input, folder, log, lastT)
        }
        guard let dir, let finished else { return completion(nil) }
        let writeLog: @Sendable () -> Void = {
            do {
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                try encoder.encode(finished).write(to: dir.appendingPathComponent("session.json"))
                completion(.success(Saved(folder: dir, seconds: seconds, shots: finished.shots.count)))
            } catch {
                completion(.failure(error))
            }
        }
        guard let wr, let inp else { return writeLog() }  // stopped before the first frame: log only
        inp.markAsFinished()
        wr.finishWriting {
            if wr.status == .failed {
                completion(.failure(RecorderError.cannotWrite(wr.error?.localizedDescription ?? "video failed")))
            } else {
                writeLog()
            }
        }
    }
}
