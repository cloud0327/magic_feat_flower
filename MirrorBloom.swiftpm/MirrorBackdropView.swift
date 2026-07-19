import SwiftUI
import AVFoundation

/// The bottom layer of the mirror. With a live camera it shows the (soon-to-be-dimmed)
/// reflection of the player; without one it shows a procedural "black mirror" so the
/// experience is identical whether or not a camera is available.
///
/// This view draws no veil or vignette — those belong to `GardenCanvasView` on top.
struct MirrorBackdropView: View {
    let mode: MirrorMode
    let session: AVCaptureSession

    var body: some View {
        switch mode {
        case .live:
            CameraPreviewView(session: session)
                .ignoresSafeArea()
        case .undecided, .enchanted:
            EnchantedMirrorView()
                .ignoresSafeArea()
        }
    }
}

/// Hosts an `AVCaptureVideoPreviewLayer` that fills the screen. The rotation matches
/// the capture output so the preview and Vision's coordinates agree.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    /// A UIView whose backing layer is the preview layer, so it resizes automatically.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// A dark, living mirror for when there is no camera: a deep indigo-to-black base
/// with two slow drifting glows, like candlelight somewhere behind the glass.
struct EnchantedMirrorView: View {
    var body: some View {
        // The dark mirror drifts slowly, so 20 fps is plenty and saves the GPU.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                // Base gradient: near-black at the edges, faint indigo in the middle.
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .linearGradient(
                                Gradient(colors: [Color(hue: 0.68, saturation: 0.6, brightness: 0.10),
                                                  .black]),
                                startPoint: .zero,
                                endPoint: CGPoint(x: 0, y: size.height)))

                drawDriftingGlow(in: &context, size: size, now: now, seed: 0,
                                 hue: 0.72, speed: 0.05)
                drawDriftingGlow(in: &context, size: size, now: now, seed: 1.7,
                                 hue: 0.9, speed: 0.037)
            }
        }
    }

    /// One soft glow that wanders in a slow Lissajous path behind the glass.
    private func drawDriftingGlow(in context: inout GraphicsContext, size: CGSize,
                                  now: TimeInterval, seed: Double, hue: Double, speed: Double) {
        let center = CGPoint(
            x: size.width * (0.5 + 0.30 * sin(now * speed * 2 * .pi + seed)),
            y: size.height * (0.5 + 0.22 * cos(now * speed * 2 * .pi * 0.8 + seed)))
        let radius = min(size.width, size.height) * 0.45
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.35).opacity(0.5), .clear]),
            center: center, startRadius: 0, endRadius: radius))
    }
}
