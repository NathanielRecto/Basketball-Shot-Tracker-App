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

/// A Bool shared with the camera queue.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
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
    @Published var parityLines: [String]?
    @Published var parityRunning = false
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var pipelined = true {
        didSet { pipelineFlag.isOn = pipelined }
    }

    let camera = CameraController()
    let hasParityFrames = ParityCheck.directory != nil
    private var detector: Detector?
    private let counts = FrameCounts()
    private let inFlight = InFlight(limit: 2)
    private let pipelineFlag = Flag(true)
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

        let det = detector, counts = counts, inFlight = inFlight, inferenceQueue = inferenceQueue, pipeline = pipelineFlag
        camera.onDrop = { counts.drop() }
        camera.onFrame = { [weak self] frame in  // camera queue: stage 1
            counts.frame()
            guard let det else { return }
            if !pipeline.isOn {  // both stages on the camera queue, one frame at a time (for comparison)
                guard inFlight.tryTake() else {
                    counts.skip()
                    return
                }
                defer { inFlight.release() }
                do {
                    let out = try det.detect(frame)
                    counts.detect()
                    DispatchQueue.main.async { self?.show(out) }
                } catch {
                    DispatchQueue.main.async { self?.status = "Detect: \(error.localizedDescription)" }
                }
                return
            }
            guard inFlight.tryTake() else {
                counts.skip()
                return
            }
            do {
                let prepared = try det.prepare(frame)
                inferenceQueue.async {  // stage 2
                    defer { inFlight.release() }
                    do {
                        let out = try det.infer(prepared)
                        counts.detect()
                        DispatchQueue.main.async { self?.show(out) }
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
        self.lens = lens
        do {
            try await camera.start(lens: lens)
            if detector != nil { status = "" }
        } catch {
            status = "Camera: \(error.localizedDescription)"
        }
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

    private func show(_ out: Detector.Output) {
        detections = out.detections
        frameSize = out.frameSize
        timings = out
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                CameraPreview(camera: model.camera)
                DetectionOverlay(detections: model.detections, frameSize: model.frameSize)
            }
            .aspectRatio(model.frameSize.width / model.frameSize.height, contentMode: .fit)

            VStack {
                HStack(alignment: .top) {
                    hud
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Button(model.pipelined ? "Pipe on" : "Pipe off") { model.pipelined.toggle() }
                        .buttonStyle(.borderedProminent)
                        .tint(model.pipelined ? .teal : .gray.opacity(0.6))
                    if model.hasParityFrames {
                        Button("Check") { model.runParity() }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)
                            .disabled(model.parityRunning)
                    }
                    lensButtons
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

    private var hud: some View {
        let byLabel = Dictionary(grouping: model.detections, by: \.label).mapValues(\.count)
        let t = model.timings
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(model.lens.rawValue) · \(Int(model.frameSize.width))×\(Int(model.frameSize.height)) · camera \(model.cameraFPS, specifier: "%.0f") fps · detector \(model.detectorFPS, specifier: "%.1f") fps")
            if let t {
                Text("prep \(t.prepareMs, specifier: "%.1f") · model \(t.predictMs, specifier: "%.1f") · decode \(t.decodeMs, specifier: "%.1f") · latency \(t.latencyMs, specifier: "%.0f") ms")
            }
            Text("ball \(byLabel["ball"] ?? 0) · hoop \(byLabel["hoop"] ?? 0) · rim \(byLabel["rim_only"] ?? 0) · thermal \(Self.name(model.thermal)) · pipeline \(model.pipelined ? "on" : "off")")
            if !model.modelName.isEmpty { Text(model.modelName).foregroundStyle(.white.opacity(0.6)) }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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

    private var lensButtons: some View {
        HStack(spacing: 8) {
            ForEach(CameraController.Lens.allCases) { lens in
                Button(lens.rawValue) { Task { await model.switchLens(to: lens) } }
                    .buttonStyle(.borderedProminent)
                    .tint(lens == model.lens ? .orange : .gray.opacity(0.6))
            }
        }
    }
}

/// Detector boxes drawn over the preview; frame pixels scale linearly onto the view.
struct DetectionOverlay: View {
    let detections: [Detection]
    let frameSize: CGSize

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / frameSize.width, sy = size.height / frameSize.height
            for d in detections {
                let rect = CGRect(x: d.box.x1 * sx, y: d.box.y1 * sy, width: d.box.width * sx, height: d.box.height * sy)
                let color = Self.color(d.label)
                ctx.stroke(Path(rect), with: .color(color), lineWidth: 2)
                let label = Text("\(d.label) \(d.conf, specifier: "%.2f")").font(.caption2.monospaced()).foregroundStyle(color)
                ctx.draw(label, at: CGPoint(x: rect.minX, y: rect.minY - 2), anchor: .bottomLeading)
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
