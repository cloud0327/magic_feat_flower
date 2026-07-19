import SwiftUI

/// The four roles a mote of light can play in the mirror.
enum ParticleKind {
    case dust        // ambient specks drifting in the dark mirror
    case gather      // sparks rushing inward to the caster's hand
    case bloomBurst  // light thrown outward when a flower opens
    case trail       // a soft wake left by a flower drifting to the garden
}

/// One mote of light. Plain data — the system below moves and ages it.
struct Particle {
    var position: CGPoint
    var velocity: CGVector
    var life: Double        // seconds of life remaining
    var maxLife: Double     // life it started with, so we can fade it out
    var size: CGFloat
    var hue: Double
    var kind: ParticleKind

    /// 1 when freshly born, 0 at death. Used for opacity.
    var aliveFraction: Double { max(0, life / maxLife) }
}

/// A fixed-capacity pool of light motes. It never grows past `capacity`, and it
/// removes dead motes by swapping the last one into the gap (no array shifting),
/// so it does no per-frame heap work.
final class ParticleSystem {
    private(set) var particles: [Particle] = []
    private let capacity = 512

    // MARK: - Per-frame update

    /// Ages every mote, moves it according to its kind, and drops the dead.
    /// `attractor` is the hand: only `gather` motes are pulled toward it.
    func update(dt: Double, attractor: CGPoint?) {
        var index = 0
        while index < particles.count {
            var mote = particles[index]

            mote.life -= dt
            if mote.life <= 0 {
                // Swap-remove: move the last mote here, shrink by one, revisit index.
                particles[index] = particles[particles.count - 1]
                particles.removeLast()
                continue
            }

            move(&mote, dt: dt, attractor: attractor)
            mote.position.x += mote.velocity.dx * dt
            mote.position.y += mote.velocity.dy * dt

            particles[index] = mote
            index += 1
        }
    }

    /// Applies the motion rule for one mote's kind.
    private func move(_ mote: inout Particle, dt: Double, attractor: CGPoint?) {
        switch mote.kind {
        case .dust:
            // A slow, gentle upward float, as if the air itself were rising.
            mote.velocity.dy += -2 * dt

        case .gather:
            // Accelerate toward the hand, with damping so motes curve in and settle
            // instead of orbiting forever. When close enough, they are "absorbed".
            if let target = attractor {
                let dx = target.x - mote.position.x
                let dy = target.y - mote.position.y
                let distance = max(hypot(dx, dy), 1)
                let pull = 900.0
                mote.velocity.dx += (dx / distance) * pull * dt
                mote.velocity.dy += (dy / distance) * pull * dt
                mote.velocity.dx *= 0.90
                mote.velocity.dy *= 0.90
                if distance < 12 { mote.life = min(mote.life, 0.08) }
            }

        case .bloomBurst:
            // Fly out, slow down, and drift down a touch so petals settle.
            mote.velocity.dx *= 0.94
            mote.velocity.dy *= 0.94
            mote.velocity.dy += 20 * dt

        case .trail:
            // Just slow to a stop where it was dropped.
            mote.velocity.dx *= 0.96
            mote.velocity.dy *= 0.96
        }
    }

    // MARK: - Spawning

    /// Keeps a soft population of ambient dust alive, topping up a few per call so
    /// it fills in gradually rather than popping into existence.
    func maintainDust(in size: CGSize, targetCount: Int) {
        let current = count(of: .dust)
        guard current < targetCount else { return }
        for _ in 0..<min(2, targetCount - current) {
            let life = Double.random(in: 4...9)
            add(Particle(
                position: CGPoint(x: .random(in: 0...size.width),
                                  y: .random(in: 0...size.height)),
                velocity: CGVector(dx: .random(in: -6...6), dy: .random(in: -10 ... -2)),
                life: life, maxLife: life,
                size: .random(in: 1...2.5),
                hue: .random(in: 0.5...0.75),
                kind: .dust))
        }
    }

    /// Sparks that appear in a ring around the hand and rush inward.
    func spawnGather(around point: CGPoint, count: Int, hue: Double) {
        for _ in 0..<count {
            let angle = Double.random(in: 0...(2 * .pi))
            let radius = Double.random(in: 60...160)
            let start = CGPoint(x: point.x + cos(angle) * radius,
                                y: point.y + sin(angle) * radius)
            let life = Double.random(in: 0.5...1.1)
            add(Particle(
                position: start,
                velocity: CGVector(dx: -cos(angle) * 40, dy: -sin(angle) * 40),
                life: life, maxLife: life,
                size: .random(in: 1.5...3),
                hue: hue, kind: .gather))
        }
    }

    /// A shower of light thrown outward when a flower blooms.
    func burstBloom(at point: CGPoint, hue: Double, count: Int) {
        for _ in 0..<count {
            let angle = Double.random(in: 0...(2 * .pi))
            let speed = Double.random(in: 60...260)
            let life = Double.random(in: 0.6...1.4)
            add(Particle(
                position: point,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                life: life, maxLife: life,
                size: .random(in: 2...4),
                hue: hue + .random(in: -0.05...0.05),
                kind: .bloomBurst))
        }
    }

    /// A single soft mote dropped behind a drifting flower.
    func trail(at point: CGPoint, hue: Double) {
        let life = Double.random(in: 0.5...1.0)
        add(Particle(
            position: point,
            velocity: CGVector(dx: .random(in: -12...12), dy: .random(in: -12...12)),
            life: life, maxLife: life,
            size: .random(in: 1.5...3),
            hue: hue, kind: .trail))
    }

    // MARK: - Helpers

    /// Adds a mote unless the pool is already full (in which case we simply skip it).
    private func add(_ mote: Particle) {
        guard particles.count < capacity else { return }
        particles.append(mote)
    }

    /// Counts motes of one kind. The pool is small (≤512), so a plain scan is fine.
    private func count(of kind: ParticleKind) -> Int {
        particles.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }
}
