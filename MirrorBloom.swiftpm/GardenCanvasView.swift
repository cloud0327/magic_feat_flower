import SwiftUI
import QuartzCore

/// Draws the entire magical layer over the mirror: the darkening veil, the garden,
/// the growing bud, and every mote of light. One `Canvas`, redrawn every frame by
/// `TimelineView(.animation)`.
///
/// The whole app shares one clock — `CACurrentMediaTime()` — so times stamped on
/// gesture events line up exactly with the times used here for animation.
struct GardenCanvasView: View {
    let world: WorldModel

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                let now = CACurrentMediaTime()
                world.update(now: now, size: size)

                var ctx = context
                drawVeil(in: &ctx, size: size, now: now)
                drawVignette(in: &ctx, size: size)
                drawGround(in: &ctx, size: size, now: now, energy: world.gardenEnergy)
                drawFlowers(in: &ctx, size: size, now: now)
                drawBud(in: &ctx, now: now)
                drawHandHalo(in: &ctx)
                drawFinale(in: &ctx, now: now)
                drawParticles(in: &ctx)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)   // touches belong to the TouchSpell layer, not the canvas
    }

    // MARK: - The mirror's veil

    /// A dark wash over the camera that lifts during the finale.
    private func drawVeil(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(.black.opacity(world.backdropDim(now: now))))
    }

    /// Darkened edges to draw the eye toward the center.
    private func drawVignette(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [.clear, .black.opacity(0.55)]),
            center: center,
            startRadius: min(size.width, size.height) * 0.3,
            endRadius: max(size.width, size.height) * 0.7))
    }

    // MARK: - The garden floor

    /// A soft band of light along the bottom, plus glowing vines that grow brighter
    /// as the garden fills.
    private func drawGround(in context: inout GraphicsContext, size: CGSize,
                            now: TimeInterval, energy: Double) {
        let bandHeight = size.height * 0.28
        let rect = CGRect(x: 0, y: size.height - bandHeight, width: size.width, height: bandHeight)
        let glow = Color(hue: 0.6, saturation: 0.5, brightness: 0.5).opacity(0.10 + energy * 0.20)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [.clear, glow]),
            startPoint: CGPoint(x: 0, y: rect.minY),
            endPoint: CGPoint(x: 0, y: rect.maxY)))

        guard energy > 0 else { return }
        for i in 0..<2 {
            var path = Path()
            let baseY = size.height * (0.86 + Double(i) * 0.05)
            let amplitude = size.height * 0.02
            path.move(to: CGPoint(x: 0, y: baseY))
            var x: CGFloat = 0
            while x <= size.width {
                let y = baseY + sin(x / 60 + Double(i) * 1.5 + now * 0.3) * amplitude
                path.addLine(to: CGPoint(x: x, y: y))
                x += 8
            }
            let vine = Color(hue: 0.4, saturation: 0.5, brightness: 0.8).opacity(0.12 + energy * 0.25)
            context.stroke(path, with: .color(vine), lineWidth: 1.5)
        }
    }

    // MARK: - Flowers

    /// Draws every bloomed flower — stem and leaves once settled, always a swaying head.
    private func drawFlowers(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        let headRadius = min(size.width, size.height) * 0.055
        for bloomed in world.flowers {
            let flower = bloomed.flower
            let position = world.position(of: bloomed, now: now)
            let settle = world.settleFraction(of: bloomed, now: now)
            let radius = headRadius * flower.sizeScale * (0.5 + 0.5 * settle)   // swells as it lands

            if settle >= 1 {
                drawStem(in: &context, head: position, size: size, flower: flower, radius: radius)
            }

            var head = context
            head.translateBy(x: position.x, y: position.y)
            head.rotate(by: .radians(sin(now * 0.5 + flower.swayPhase) * 0.03))
            flower.drawHead(in: &head, radius: radius, time: now)
        }
    }

    /// A stem rising from the meadow floor to the flower's head, with a pair of leaves.
    private func drawStem(in context: inout GraphicsContext, head: CGPoint, size: CGSize,
                          flower: Flower, radius: CGFloat) {
        let groundY = size.height * 0.95
        guard groundY > head.y else { return }

        let lean = flower.stemLean * (groundY - head.y)
        let base = CGPoint(x: head.x + lean, y: groundY)
        let control = CGPoint(x: head.x + lean * 0.3, y: (head.y + groundY) / 2)

        var stem = Path()
        stem.move(to: base)
        stem.addQuadCurve(to: head, control: control)
        let stemColor = Color(hue: 0.38, saturation: 0.45, brightness: 0.55).opacity(0.7)
        context.stroke(stem, with: .color(stemColor), lineWidth: max(2, radius * 0.10))

        let leafPoint = pointOnQuad(base: base, control: control, tip: head, t: 0.55)
        for side: CGFloat in [-1, 1] {
            var leaf = context
            leaf.translateBy(x: leafPoint.x, y: leafPoint.y)
            leaf.rotate(by: .radians(side * 1.1 + flower.swayPhase))
            let path = Flower.petalPath(length: radius * 0.9, width: radius * 0.4, curl: 0.5)
            leaf.fill(path, with: .color(Color(hue: 0.36, saturation: 0.5, brightness: 0.5).opacity(0.6)))
        }
    }

    // MARK: - The bud and the hand

    /// The growing light-ball on the caster's hand, wrapped in slowly turning arcs.
    private func drawBud(in context: inout GraphicsContext, now: TimeInterval) {
        guard world.budGrowth > 0.01, let point = world.handPoint else { return }
        let growth = world.budGrowth
        let radius = 8 + growth * 26
        let hue = world.cachedMoment.roomHue

        let ball = ellipse(at: point, radius: radius)
        context.fill(ball, with: .radialGradient(
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

    /// A faint halo confirming the mirror sees the hand.
    private func drawHandHalo(in context: inout GraphicsContext) {
        guard world.handPresent, let point = world.handPoint else { return }
        let radius: CGFloat = 60
        context.fill(ellipse(at: point, radius: radius), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.12), .clear]),
            center: point, startRadius: 0, endRadius: radius))
    }

    // MARK: - Finale

    /// A line of light threads between the flowers, and their heads pulse together.
    private func drawFinale(in context: inout GraphicsContext, now: TimeInterval) {
        guard case let .finale(start) = world.journey else { return }
        let heads = world.flowers
            .map { world.position(of: $0, now: now) }
            .sorted { $0.x < $1.x }
        guard heads.count >= 2 else { return }

        var context = context
        context.blendMode = .plusLighter

        var path = Path()
        path.move(to: heads[0])
        for point in heads.dropFirst() { path.addLine(to: point) }
        let progress = min((now - start) / 3, 1)   // the thread draws itself over 3s
        context.stroke(path.trimmedPath(from: 0, to: progress),
                       with: .color(Color(hue: 0.13, saturation: 0.3, brightness: 1).opacity(0.6)),
                       lineWidth: 2)

        let pulse = 0.5 + 0.5 * sin(now * 3)
        for point in heads {
            context.fill(ellipse(at: point, radius: 40),
                         with: .color(.white.opacity(0.10 * pulse)))
        }
    }

    // MARK: - Particles

    /// Every mote of light, drawn additively so overlaps glow. A bright core inside a
    /// soft halo — cheap, and it reads as light without any image assets.
    private func drawParticles(in context: inout GraphicsContext) {
        var context = context
        context.blendMode = .plusLighter
        for mote in world.particles.particles {
            let alpha = mote.aliveFraction
            let r = mote.size
            let halo = Color(hue: mote.hue, saturation: 0.7, brightness: 1).opacity(alpha * 0.25)
            let core = Color(hue: mote.hue, saturation: 0.5, brightness: 1).opacity(alpha)
            context.fill(ellipse(at: mote.position, radius: r * 2), with: .color(halo))
            context.fill(ellipse(at: mote.position, radius: r), with: .color(core))
        }
    }

    // MARK: - Small geometry helpers

    private func ellipse(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2))
    }

    /// A point on a quadratic Bézier curve at parameter `t` (0…1).
    private func pointOnQuad(base: CGPoint, control: CGPoint, tip: CGPoint, t: CGFloat) -> CGPoint {
        let m = 1 - t
        return CGPoint(x: m * m * base.x + 2 * m * t * control.x + t * t * tip.x,
                       y: m * m * base.y + 2 * m * t * control.y + t * t * tip.y)
    }
}
