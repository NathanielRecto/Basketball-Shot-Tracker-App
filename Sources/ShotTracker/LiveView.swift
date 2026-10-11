import QuartzCore
import ShotCore
import SwiftUI

/// Frame counts from the camera and inference queues, read once a second on the main thread.
private final class FrameCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, drops = 0, busy = 0, detected = 0

    func frame() { lock.withLock { frames += 1 } }
    func drop() { lock.withLock { drops += 1 } }
    func skip() { lock.withLock { busy += 1 } }
    func detect() { lock.withLock { detected += 1 } }

    func take() -> (frames: Int, drops: Int, busy: Int, detected: Int) {
        lock.withLock {
            defer { frames = 0; drops = 0; busy = 0; detected = 0 }
            return (frames, drops, busy, detected)
        }
    }
}

/// Frames between the two detector stages: one running on the model, one prepared and waiting. A camera frame that
/// finds both taken is skipped, so the model is never idle and never falls behind.
private final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func tryTake() -> Bool {
        lock.withLock {
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func release() { lock.withLock { count -= 1 } }
}

@MainActor
final class LiveModel: ObservableObject {
    @Published var status = "Starting…"
    @Published var detections: [Detection] = []
    @Published var frameSize = CGSize(width: 1920, height: 1080)
    @Published var lens = CameraController.Lens.ultraWide
    @Published var modelName = ""
    @Published var cameraFPS = 0.0
    @Published var detectorFPS = 0.0
    @Published var timings: Detector.Output?
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var parityLines: [String]?
    @Published var parityRunning = false
    // shots
    @Published var hoop: Box?
    @Published var hoopAmbiguity: Double?
    @Published var hoopSampled = 0
    @Published var hoopMoves = 0
    @Published var ball: BallObs?
    @Published var made = 0
    @Published var attempts = 0
    @Published var banner: ShotEvent?

    let camera = CameraController()
    let hasParityFrames = ParityCheck.directory != nil
    private var detector: Detector?
    private let session = ShotSession()  // inference queue only
    private let counts = FrameCounts()
    private let inFlight = InFlight(limit: 2)
    private let inferenceQueue = DispatchQueue(label: "detector.infer", qos: .userInteractive)
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        guard await CameraController.requestAccess() else {
            status = "Camera access is off: Settings → Privacy & Security → Camera → Shot Tracker."
            return
        }
        status = "Preparing the detector (the first launch compiles it)…"
        do {
            let det = try await Detector.load()
            detector = det
            modelName = "\(det.info.name) \(det.info.precision) \(det.info.inputWidth)×\(det.info.inputHeight)"
        } catch {
            status = "Detector: \(error.localizedDescription)"
        }

        let det = detector, counts = counts, inFlight = inFlight, inferenceQueue = inferenceQueue, session = session
        camera.onDrop = { counts.drop() }
        camera.onFrame = { [weak self] frame, t in  // camera queue: stage 1
            counts.frame()
            guard let det else { return }
            guard inFlight.tryTake() else {
                counts.skip()
                return
            }
            do {
                let prepared = try det.prepare(frame, t: t)
                inferenceQueue.async {  // stage 2, then the shot judge (frames stay in order on this serial queue)
                    defer { inFlight.release() }
                    do {
                        let out = try det.infer(prepared)
                        let update = session.feed(out)
                        counts.detect()
                        DispatchQueue.main.async { self?.show(out, update) }
                    } catch {
                        DispatchQueue.main.async { self?.status = "Detect: \(error.localizedDescription)" }
                    }
                }
            } catch {
                inFlight.release()
                DispatchQueue.main.async { self?.status = "Prepare: \(error.localizedDescription)" }
            }
        }
        await switchLens(to: lens)
        lastTick = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func switchLens(to lens: CameraController.Lens) async {
        let changed = lens != self.lens
        self.lens = lens
        do {
            try await camera.start(lens: lens)
            if detector != nil { status = "" }
        } catch {
            status = "Camera: \(error.localizedDescription)"
        }
        if changed { refindHoop() }
    }

    /// Find the hoop from scratch (the lens changed). The count is kept. A phone that merely moves does not need
    /// this: the session follows the rim between shots.
    private func refindHoop() {
        let session = session
        inferenceQueue.async { session.refindHoop() }
        hoop = nil
        hoopAmbiguity = nil
        hoopSampled = 0
        ball = nil
    }

    /// Start counting from zero with the same hoop.
    func resetShots() {
        let session = session
        inferenceQueue.async { session.resetShots() }
        made = 0
        attempts = 0
        banner = nil
    }

    /// Phone detector vs PyTorch on the bundled dev frames (camera paused meanwhile).
    func runParity() {
        guard !parityRunning else { return }
        parityRunning = true
        parityLines = ["Starting…"]
        camera.stop()
        let report: @Sendable (String) -> Void = { [weak self] msg in
            let target = self
            Task { @MainActor in target?.parityLines = [msg] }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let lines: [String]
            do {
                lines = try await ParityCheck.run(progress: report)
            } catch {
                lines = ["Parity check failed: \(error.localizedDescription)"]
            }
            let target = self
            await target?.finishParity(lines)
        }
    }

    private func finishParity(_ lines: [String]) async {
        parityLines = lines
        parityRunning = false
        await switchLens(to: lens)
    }

    private func show(_ out: Detector.Output, _ update: ShotSession.Update) {
        detections = out.detections
        frameSize = out.frameSize
        timings = out
        hoop = update.hoop
        hoopAmbiguity = update.ambiguity
        hoopSampled = update.sampled
        if update.hoopMoved { hoopMoves += 1 }
        ball = update.ball
        for ev in update.events {
            attempts += 1
            if ev.outcome == .made { made += 1 }
            banner = ev
            let index = ev.index
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.banner?.index == index { self?.banner = nil }
            }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime(), dt = max(now - lastTick, 1e-3)
        lastTick = now
        let c = counts.take()
        cameraFPS = Double(c.frames + c.drops) / dt
        detectorFPS = Double(c.detected) / dt
        thermal = ProcessInfo.processInfo.thermalState
    }
}

struct LiveView: View {
    @StateObject private var model = LiveModel()
    /// Boxes, hoop, tracked ball, speed readout and the parity check; off = just the camera, score and calls.
    @AppStorage("showBoxes") private var showBoxes = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                CameraPreview(camera: model.camera)
                if showBoxes {
                    DetectionOverlay(detections: model.detections, hoop: model.hoop, ball: model.ball, frameSize: model.frameSize)
                }
            }
            .aspectRatio(model.frameSize.width / model.frameSize.height, contentMode: .fit)

            VStack {
                HStack(alignment: .top) {
                    if showBoxes {
                        hud
                    } else if model.hoop == nil {
                        Text("Looking for the hoop… keep the rim in view")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                    score
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if let ev = model.banner { banner(ev) }
                    Spacer()
                    controls
                }
            }
            .padding()

            if let lines = model.parityLines {
                parityPanel(lines)
            } else if !model.status.isEmpty {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    .padding(40)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await model.start() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    private var hoopStatus: String {
        guard model.hoop != nil else {
            return "hoop: finding \(model.hoopSampled)/\(ShotSession.window) (keep the rim in view)"
        }
        if let a = model.hoopAmbiguity, a > 0.5 { return "hoop: 2 hoops in view, check the green box" }
        return model.hoopMoves == 0 ? "hoop: following the rim" : "hoop: following the rim (moved \(model.hoopMoves)×)"
    }

    private var hud: some View {
        let byLabel = Dictionary(grouping: model.detections, by: \.label).mapValues(\.count)
        let t = model.timings
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(model.lens.rawValue) · camera \(model.cameraFPS, specifier: "%.0f") fps · detector \(model.detectorFPS, specifier: "%.1f") fps · thermal \(Self.name(model.thermal))")
            if let t {
                Text("prep \(t.prepareMs, specifier: "%.1f") · model \(t.predictMs, specifier: "%.1f") · decode \(t.decodeMs, specifier: "%.1f") · latency \(t.latencyMs, specifier: "%.0f") ms")
            }
            Text("ball \(byLabel["ball"] ?? 0) · rim \(byLabel["rim_only"] ?? 0) · \(hoopStatus)")
            if !model.modelName.isEmpty { Text(model.modelName).foregroundStyle(.white.opacity(0.6)) }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var score: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(model.made) / \(model.attempts)").font(.system(size: 34, weight: .bold, design: .rounded))
            Text(model.attempts == 0 ? "made / shots" : "\(Int((100 * Double(model.made) / Double(model.attempts)).rounded()))%")
                .font(.caption.monospaced())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func banner(_ ev: ShotEvent) -> some View {
        let made = ev.outcome == .made
        return VStack(alignment: .leading, spacing: 0) {
            Text(made ? "MADE" : "MISSED").font(.system(size: 44, weight: .heavy, design: .rounded))
            Text(Self.reasonText(ev.reason)).font(.callout)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background((made ? Color.green : Color.red).opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .transition(.scale.combined(with: .opacity))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { showBoxes.toggle() } label: {
                Label("Boxes", systemImage: showBoxes ? "eye" : "eye.slash")
            }
            .buttonStyle(.bordered)
            .tint(.white)
            Button("Reset") { model.resetShots() }.buttonStyle(.bordered).tint(.white)
            if showBoxes && model.hasParityFrames {
                Button("Check") { model.runParity() }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(model.parityRunning)
            }
            ForEach(CameraController.Lens.allCases) { lens in
                Button(lens.rawValue) { Task { await model.switchLens(to: lens) } }
                    .buttonStyle(.borderedProminent)
                    .tint(lens == model.lens ? .orange : .gray.opacity(0.6))
            }
        }
    }

    static func reasonText(_ reason: String) -> String {
        switch reason {
        case "through_hoop": "through the hoop"
        case "rattled_in": "rattled in"
        case "off_target": "off target"
        case "rim_out": "in and out"
        case "rim_bounce": "off the rim"
        case "fell_past_rim": "fell past the rim"
        default: reason
        }
    }

    static func name(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "?"
        }
    }

    private func parityPanel(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.parityRunning {
                Button("Close") { model.parityLines = nil }.buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .padding(30)
    }
}

/// Detector boxes, the hoop the shot judge uses and the tracked ball, drawn over the preview; frame pixels scale
/// linearly onto the view.
struct DetectionOverlay: View {
    let detections: [Detection]
    let hoop: Box?
    let ball: BallObs?
    let frameSize: CGSize

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / frameSize.width, sy = size.height / frameSize.height
            func rect(_ b: Box) -> CGRect {
                CGRect(x: b.x1 * sx, y: b.y1 * sy, width: b.width * sx, height: b.height * sy)
            }
            if let hoop {
                ctx.stroke(Path(rect(hoop)), with: .color(.green), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            for d in detections {
                let r = rect(d.box), color = Self.color(d.label)
                ctx.stroke(Path(r), with: .color(color.opacity(0.8)), lineWidth: 1.5)
                let label = Text("\(d.label) \(d.conf, specifier: "%.2f")").font(.caption2.monospaced()).foregroundStyle(color)
                ctx.draw(label, at: CGPoint(x: r.minX, y: r.minY - 2), anchor: .bottomLeading)
            }
            if let ball {
                let d = max(ball.diameter, 12)
                let r = CGRect(x: (ball.x - d / 2) * sx, y: (ball.y - d / 2) * sy, width: d * sx, height: d * sy)
                ctx.stroke(Path(ellipseIn: r.insetBy(dx: -4, dy: -4)), with: .color(.white), lineWidth: 3)
            }
        }
        .allowsHitTesting(false)
    }

    static func color(_ label: String) -> Color {
        switch label {
        case "ball": .orange
        case "hoop": .green
        default: .cyan
        }
    }
}
