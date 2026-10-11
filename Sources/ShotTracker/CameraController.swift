import AVFoundation

/// The last landscape rotation angle seen (0 or 180 degrees); portrait angles keep it.
private final class LandscapeAngle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CGFloat?

    func pick(_ angle: CGFloat) -> CGFloat {
        lock.withLock {
            if angle == 0 || angle == 180 { last = angle }
            return last ?? 0
        }
    }
}

/// Back camera at 1080p / 60 fps (the research footage settings), delivering upright BGRA frames on its own queue,
/// with Camera-app style zoom: 0.5x = the ultra-wide lens, 1x = the wide lens, more = digital zoom (max 5x).
/// Prefers the dual-wide virtual camera, which switches between the two lenses by itself as the zoom changes.
/// Session state is touched only on `sessionQueue`, rotation and preview state only on the main thread.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct ZoomRange: Equatable {
        var min: Double
        var max: Double
    }

    enum CameraError: LocalizedError {
        case noCamera(Double)
        case cannotAdd

        var errorDescription: String? {
            switch self {
            case .noCamera(let fps): "This phone has no back camera with 1920×1080 at \(Int(fps)) fps."
            case .cannotAdd: "Could not connect the camera to the capture session."
            }
        }
    }

    /// Digital zoom beyond this looks too soft to be useful (the Camera app on an iPhone 11 also stops at 5x).
    static let maxDisplayZoom = 5.0

    let session = AVCaptureSession()
    /// Called on the video queue for each frame it keeps up with (the sample: pixels + presentation time);
    /// late frames are dropped (`onDrop`).
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onDrop: (() -> Void)?
    /// Which camera is in use ("dual wide", "ultra wide" or "wide"), for the readout.
    private(set) var cameraName = ""

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?  // session queue
    private var device: AVCaptureDevice?
    private var displayPerFactor = 1.0  // shown zoom = videoZoomFactor * displayPerFactor
    private var range = ZoomRange(min: 1, max: 1)
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    @MainActor func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        if let device { followRotation(of: device) }
    }

    /// Configures the camera the first time, then (re)starts it. Returns the zoom range, as the Camera app shows it.
    @MainActor func start(fps: Double = 60) async throws -> ZoomRange {
        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(AVCaptureDevice, ZoomRange), Error>) in
            sessionQueue.async {
                do {
                    if let device = self.device, self.input != nil {
                        cont.resume(returning: (device, self.range))
                    } else {
                        cont.resume(returning: try self.configure(fps: fps))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        followRotation(of: result.0)
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
        return result.1
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
    }

    /// Zoom as the Camera app shows it (0.5 = ultra-wide), clamped to the range `start` returned.
    func setZoom(_ display: Double) {
        sessionQueue.async {
            guard let device = self.device else { return }
            let shown = min(max(display, self.range.min), self.range.max)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = CGFloat(shown / self.displayPerFactor)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private func format(of device: AVCaptureDevice, fps: Double) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
        return formats.first(where: { !$0.isVideoBinned }) ?? formats.first
    }

    private func configure(fps: Double) throws -> (AVCaptureDevice, ZoomRange) {
        let choices: [(AVCaptureDevice.DeviceType, String)] = [
            (.builtInDualWideCamera, "dual wide"), (.builtInUltraWideCamera, "ultra wide"), (.builtInWideAngleCamera, "wide"),
        ]
        guard let (device, name, format) = choices.lazy.compactMap({ type, name -> (AVCaptureDevice, String, AVCaptureDevice.Format)? in
            guard let d = AVCaptureDevice.default(type, for: .video, position: .back), let f = self.format(of: d, fps: fps) else { return nil }
            return (d, name, f)
        }).first else {
            throw CameraError.noCamera(fps)
        }

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        if let input { session.removeInput(input) }
        let newInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(newInput) else {
            session.commitConfiguration()
            throw CameraError.cannotAdd
        }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()

        // Format and frame rate after the commit, so the session does not reset them.
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        switch device.deviceType {
        case .builtInDualWideCamera:  // zoom factor 1 = ultra-wide; the switch to the wide lens is "1x"
            displayPerFactor = 1 / (device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2)
        case .builtInUltraWideCamera: displayPerFactor = 0.5
        default: displayPerFactor = 1
        }
        let maxFactor = min(Double(device.maxAvailableVideoZoomFactor), Double(format.videoMaxZoomFactor))
        range = ZoomRange(min: Double(device.minAvailableVideoZoomFactor) * displayPerFactor,
                          max: min(maxFactor * displayPerFactor, Self.maxDisplayZoom))
        device.videoZoomFactor = CGFloat(range.min / displayPerFactor)  // start at the widest: 0.5x where there is one
        device.unlockForConfiguration()
        self.device = device
        cameraName = name
        return (device, range)
    }

    /// Keeps frames and preview level with the horizon whichever way the phone sits in landscape. The app is
    /// landscape only, so only landscape angles (0 / 180 degrees) are used: held upright, the phone keeps the last
    /// landscape angle instead of turning the frames portrait (which showed them small and sideways, and fed the
    /// detector sideways frames). Until a landscape angle has been seen, 0 (the sensor's own landscape) is used.
    @MainActor private func followRotation(of device: AVCaptureDevice) {
        observations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        let capture = LandscapeAngle(), preview = LandscapeAngle()
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] c, _ in
            let angle = capture.pick(c.videoRotationAngleForHorizonLevelCapture)
            self?.sessionQueue.async {
                guard let conn = self?.output.connection(with: .video), conn.isVideoRotationAngleSupported(angle) else { return }
                conn.videoRotationAngle = angle
            }
        })
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] c, _ in
            let angle = preview.pick(c.videoRotationAngleForHorizonLevelPreview)
            DispatchQueue.main.async {
                guard let conn = self?.previewLayer?.connection, conn.isVideoRotationAngleSupported(angle) else { return }
                conn.videoRotationAngle = angle
            }
        })
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onDrop?()
    }
}
