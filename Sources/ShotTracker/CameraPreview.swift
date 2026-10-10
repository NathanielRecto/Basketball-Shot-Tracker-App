import AVFoundation
import SwiftUI

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// The live camera image. Sits in a container with the frame's aspect ratio, so frame pixels map linearly
/// onto it (see `DetectionOverlay`).
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        camera.attach(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}
