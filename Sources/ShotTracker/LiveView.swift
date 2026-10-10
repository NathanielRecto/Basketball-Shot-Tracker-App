import QuartzCore
import ShotCore
import SwiftUI

/// Frame counts from the video queue, read once a second on the main thread.
private final class FrameCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, drops = 0, detected = 0

    func frame() { lock.withLock { frames += 1 } }
    func drop() { lock.withLock { drops += 1 } }
    func detect() { lock.withLock { detected += 1 } }

    func take() -> (frames: Int, drops: Int, detected: Int) {
        lock.withLock {
            defer { frames = 0; drops = 0; detected = 0 }
            return (frames, drops, detected)
        }
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
    @Published var predictMs = 0.0
    @Published var totalMs = 0.0

    let camera = CameraController()
    private var detector: Detector?
    private let counts = FrameCounts()
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

        let det = detector, counts = counts
        camera.onDrop = { counts.drop() }
        camera.onFrame = { [weak self] frame in
            counts.frame()
            guard let det else { return }
            do {
                let found = try det.detect(frame)
                counts.detect()
                let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
                let predict = det.lastPredictMs, total = det.lastTotalMs
                DispatchQueue.main.async { self?.show(found, size: size, predictMs: predict, totalMs: total) }
            } catch {
                DispatchQueue.main.async { self?.status = "Detect: \(error.localizedDescription)" }
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

    private func show(_ found: [Detection], size: CGSize, predictMs: Double, totalMs: Double) {
        detections = found
        frameSize = size
        self.predictMs = predictMs
        self.totalMs = totalMs
    }

    private func tick() {
        let now = CACurrentMediaTime(), dt = max(now - lastTick, 1e-3)
        lastTick = now
        let c = counts.take()
        cameraFPS = Double(c.frames + c.drops) / dt
        detectorFPS = Double(c.detected) / dt
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
                    lensButtons
                }
            }
            .padding()

            if !model.status.isEmpty {
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
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(model.lens.rawValue) · \(Int(model.frameSize.width))×\(Int(model.frameSize.height)) · camera \(model.cameraFPS, specifier: "%.0f") fps")
            Text("detector \(model.detectorFPS, specifier: "%.1f") fps · model \(model.predictMs, specifier: "%.0f") ms · frame \(model.totalMs, specifier: "%.0f") ms")
            Text("ball \(byLabel["ball"] ?? 0) · hoop \(byLabel["hoop"] ?? 0) · rim \(byLabel["rim_only"] ?? 0)")
            if !model.modelName.isEmpty { Text(model.modelName).foregroundStyle(.white.opacity(0.6)) }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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
