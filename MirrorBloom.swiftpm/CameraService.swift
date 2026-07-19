import AVFoundation
import CoreVideo

/// Which mirror the player is looking into.
enum MirrorMode {
    case undecided   // still asking for permission — show the black mirror meanwhile
    case live        // front camera: the real you, dimmed into a dark mirror
    case enchanted   // no camera (denied / simulator): a procedural black mirror
}

/// Owns the AVCaptureSession for the front camera and hands every frame
/// to `onFrame` on a private serial queue. Nothing is recorded or stored.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    /// Called on the camera queue with every captured frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let queue = DispatchQueue(label: "mirrorbloom.camera")

    /// Asks for permission, builds the session and starts it.
    /// Any failure quietly falls back to the enchanted mirror — never a dead end.
    func configureAndStart() async -> MirrorMode {
        #if targetEnvironment(simulator)
        return .enchanted   // the simulator has no camera
        #else
        guard await AVCaptureDevice.requestAccess(for: .video) else { return .enchanted }
        return await withCheckedContinuation { continuation in
            queue.async {
                if self.configureSession() {
                    self.session.startRunning()
                    continuation.resume(returning: .live)
                } else {
                    continuation.resume(returning: .enchanted)
                }
            }
        }
        #endif
    }

    private func configureSession() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720   // enough for Vision, cheap to draw

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return false }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            // Portrait buffers, mirrored like the preview: Vision's coordinates then
            // match what the player sees, and all later math is just y-flip + aspect-fill.
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
