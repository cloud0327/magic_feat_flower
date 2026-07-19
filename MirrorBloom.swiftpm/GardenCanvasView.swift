import SwiftUI
import QuartzCore

/// Draws the magical layer over the real world: a light veil, the flowers you have set
/// free, the bud in your hand, and every mote of light. One `Canvas`, capped at 60 fps.
///
/// The whole app shares one clock — `CACurrentMediaTime()` — so times stamped on gesture
/// events line up exactly with the times used here for animation.
struct GardenCanvasView: View {
    let world: WorldModel

    var body: some View {
        // Cap at 60 fps: on a 120 Hz display the extra frames just burned the GPU.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            Canvas { context, size in
                let now = CACurrentMediaTime()
                world.update(now: now, size: size)

                var ctx = context
                drawVeil(in: &ctx, size: size)
                drawFlowers(in: &ctx, now: now)
                drawBud(in: &ctx, now: now)
                drawHandHalo(in: &ctx)
                drawFinale(in: &ctx, size: size, now: now)
                drawParticles(in: &ctx)
                #if DEBUG
                drawFPS(in: &ctx)
                #endif
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)   // touches belong to the TouchSpell layer, not the canvas
    }

    // MARK: - The mirror's veil

    /// A light wash over the camera. Its strength follows the room's brightness and
    /// lifts almost entirely during the finale (see `WorldModel.veilOpacity`).
    private func drawVeil(in context: inout GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.black.opacity(world.veilOpacity)))
    }

    // MARK: - Flowers

    /// Draws every bloomed flower at its anchor, popping open and gently swaying.
    /// Prefers the baked sprite; falls back to vectors for the first few frames.
    private func drawFlowers(in context: inout GraphicsContext, now: TimeInterval) {
        for bloomed in world.flowers {
            let center = world.position(of: bloomed, now: now)
            let pop = world.popScale(of: bloomed, now: now)
            let sway = sin(now * 0.5 + bloomed.flower.swayPhase) * 0.03

            var head = context
            head.translateBy(x: center.x, y: center.y)
            head.rotate(by: .radians(sway))

            if let image = bloomed.headImage {
                let side = bloomed.bakedRadius * 3 * pop
                head.draw(image, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
            } else {
                bloomed.flower.drawHead(in: &head, radius: bloomed.bakedRadius * pop, time: now)
            }
        }
    }

    // MARK: - The bud and the hand

    /// The growing light-ball in your hand, wrapped in slowly turning arcs.
    private func drawBud(in context: inout GraphicsContext, now: TimeInterval) {
        guard world.budGrowth > 0.01, let point = world.handPoint else { return }
        let growth = world.budGrowth
        let radius = 8 + growth * 26
        let hue = world.cachedMoment.roomHue

        context.fill(ellipse(at: point, radius: radius), with: .radialGradient(
            Gradient(colors: [Color(hue: hue, saturation: 0.4, brightness: 1).opacity(0.9),
                              Color(hue: hue, saturation: 0.7, brightness: 0.9).opacity(0)]),
            center: point, startRadius: 0, endRadius: radius))

        let arcCount = 2 + Int(growth * 2)
        for i in 0..<arcCount {
            var arc = Path()
            let phase = now * 1.2 + Double(i) * (2 * .pi / Double(arcCount))
            arc.addArc(center: point, radius: radius * 1.2,
                       startAngle: .radians(phase), endAngle: .radians(phase + 1.6),
                       clockwise: false)
            let color = Color(hue: hue, saturation: 0.5, brightness: 1).opacity(0.5 * growth)
            context.stroke(arc, with: .color(color), lineWidth: 2)
        }
    }

    /// A faint halo confirming the mirror sees your hand.
    private func drawHandHalo(in context: inout GraphicsContext) {
        guard world.handPresent, let point = world.handPoint else { return }
        let radius: CGFloat = 60
        context.fill(ellipse(at: point, radius: radius), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.12), .clear]),
            center: point, startRadius: 0, endRadius: radius))
    }

    // MARK: - Finale

    /// Light fills the mirror: a golden wash swells from the center, a thread links the
    /// flowers, and their heads pulse together.
    private func drawFinale(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        guard case let .finale(start) = world.journey else { return }
        let progress = min((now - start) / 3, 1)

        var context = context
        context.blendMode = .plusLighter

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [Color(hue: 0.13, saturation: 0.35, brightness: 1).opacity(0.22 * progress),
                              .clear]),
            center: center, startRadius: 0, endRadius: max(size.width, size.height) * 0.7))

        let heads = world.flowers
            .map { world.position(of: $0, now: now) }
            .sorted { $0.x < $1.x }
        guard heads.count >= 2 else { return }

        var path = Path()
        path.move(to: heads[0])
        for point in heads.dropFirst() { path.addLine(to: point) }
        context.stroke(path.trimmedPath(from: 0, to: progress),
                       with: .color(Color(hue: 0.13, saturation: 0.3, brightness: 1).opacity(0.6)),
                       lineWidth: 2)

        let pulse = 0.5 + 0.5 * sin(now * 3)
        for point in heads {
            context.fill(ellipse(at: point, radius: 44), with: .color(.white.opacity(0.10 * pulse)))
        }
    }

    // MARK: - Particles

    /// Two passes so light reads on any background: an additive halo for glow, then a
    /// solid core so each mote stays visible even against a bright wall.
    private func drawParticles(in context: inout GraphicsContext) {
        var glow = context
        glow.blendMode = .plusLighter
        for mote in world.particles.particles {
            let color = Color(hue: mote.hue, saturation: 0.7, brightness: 1)
                .opacity(mote.aliveFraction * 0.3)
            glow.fill(ellipse(at: mote.position, radius: mote.size * 2), with: .color(color))
        }
        for mote in world.particles.particles {
            let color = Color(hue: mote.hue, saturation: 0.8, brightness: 0.95)
                .opacity(mote.aliveFraction)
            context.fill(ellipse(at: mote.position, radius: mote.size), with: .color(color))
        }
    }

    // MARK: - Helpers

    private func ellipse(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2))
    }

    #if DEBUG
    /// A small frame-rate readout, so the real-device test can report a number.
    private func drawFPS(in context: inout GraphicsContext) {
        let text = Text(String(format: "%.0f fps", world.fps))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.green)
        context.draw(text, at: CGPoint(x: 44, y: 28), anchor: .center)
    }
    #endif
}
