import AVFoundation

/// Back camera at 1080p / 60 fps (the research footage settings), delivering upright BGRA frames on its own queue.
/// Session state is touched only on `sessionQueue`, rotation and preview state only on the main thread.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Lens: String, CaseIterable, Identifiable {
        case ultraWide = "0.5x"
        case wide = "1x"

        var id: String { rawValue }
        var deviceType: AVCaptureDevice.DeviceType {
            self == .ultraWide ? .builtInUltraWideCamera : .builtInWideAngleCamera
        }
    }

    enum CameraError: LocalizedError {
        case noCamera(Lens)
        case noFormat(Lens, Double)
        case cannotAdd

        var errorDescription: String? {
            switch self {
            case .noCamera(let lens): "This phone has no \(lens.rawValue) back camera."
            case .noFormat(let lens, let fps): "The \(lens.rawValue) camera has no 1920×1080 format at \(Int(fps)) fps."
            case .cannotAdd: "Could not connect the camera to the capture session."
            }
        }
    }

    let session = AVCaptureSession()
    /// Called on the video queue for each frame it keeps up with (pixels, presentation time in seconds);
    /// late frames are dropped (`onDrop`).
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    var onDrop: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?  // session queue
    private var device: AVCaptureDevice?  // main
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

    /// Switches to `lens` (configuring the session on its own queue) and starts it if needed.
    @MainActor func start(lens: Lens, fps: Double = 60) async throws {
        let device = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AVCaptureDevice, Error>) in
            sessionQueue.async {
                do { cont.resume(returning: try self.configure(lens: lens, fps: fps)) } catch { cont.resume(throwing: error) }
            }
        }
        self.device = device
        followRotation(of: device)
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
    }

    private func configure(lens: Lens, fps: Double) throws -> AVCaptureDevice {
        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            throw CameraError.noCamera(lens)
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
        let formats = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
        guard let format = formats.first(where: { !$0.isVideoBinned }) ?? formats.first else {
            throw CameraError.noFormat(lens, fps)
        }
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.unlockForConfiguration()
        return device
    }

    /// Keeps frames and preview level with the horizon whichever way the phone sits in landscape.
    @MainActor private func followRotation(of device: AVCaptureDevice) {
        observations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async {
                guard let conn = self?.output.connection(with: .video), conn.isVideoRotationAngleSupported(angle) else { return }
                conn.videoRotationAngle = angle
            }
        })
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let conn = self?.previewLayer?.connection, conn.isVideoRotationAngleSupported(angle) else { return }
                conn.videoRotationAngle = angle
            }
        })
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(frame, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onDrop?()
    }
}
