import SwiftUI
import QuartzCore
import Observation

/// The four stages of the experience. Time only moves forward.
enum JourneyPhase: Equatable {
    case dormant                     // waiting for a hand
    case awakening                   // a hand has appeared; light answers it
    case blooming                    // flowers are appearing, 1…4
    case finale(start: TimeInterval) // the fifth flower — light fills the mirror
    case afterglow                   // a calm, bright world to keep playing in
}

/// A flower that has bloomed. It stays where it was released, gently bobbing, and its
/// head is drawn from an image that is baked a few frames after it opens.
struct BloomedFlower: Identifiable {
    let id = UUID()
    var flower: Flower
    var birthTime: TimeInterval
    var anchor: CGPoint        // where it was set free; it lives here in your world
    var bakedRadius: CGFloat   // the radius its image was baked at
    var headImage: Image?      // nil for the first few frames, then a ready-made sprite
}

/// The single source of truth for the experience.
///
/// Only `journey` and `mirrorMode` are observed, because they change rarely and should
/// refresh the UI. Everything the draw loop touches every frame is `@ObservationIgnored`
/// so SwiftUI is never invalidated 60 times a second. All access is on the main thread.
@Observable
final class WorldModel {

    // MARK: - Observed (low-frequency) state

    var journey: JourneyPhase = .dormant
    var mirrorMode: MirrorMode = .undecided

    // MARK: - Per-frame state (never observed)

    /// Asks the mirror "what is this moment?" — supplied by SpellConductor.
    @ObservationIgnored var momentProvider: () -> MomentSnapshot = { .clockFallback() }

    @ObservationIgnored let particles = ParticleSystem()
    @ObservationIgnored private(set) var flowers: [BloomedFlower] = []
    @ObservationIgnored private(set) var cachedMoment = MomentSnapshot.clockFallback()

    /// The dark wash over the camera. It eases toward a target set by the room's
    /// brightness, so a bright room shows through and a dark room stays moody.
    @ObservationIgnored private(set) var veilOpacity: Double = 0.35

    /// A smoothed frame rate, shown only in debug builds.
    @ObservationIgnored private(set) var fps: Double = 60

    // Hand and bud
    @ObservationIgnored private(set) var handPoint: CGPoint?
    @ObservationIgnored private(set) var handPose: HandPose = .unknown
    @ObservationIgnored private(set) var budGrowth: Double = 0
    @ObservationIgnored private(set) var handPresent = false
    @ObservationIgnored private var lastHandPoint: CGPoint?
    @ObservationIgnored private var lostSince: TimeInterval?
    @ObservationIgnored private var fullyGrownSince: TimeInterval?

    // Timing
    @ObservationIgnored private var lastUpdate: TimeInterval = 0
    @ObservationIgnored private var lastMomentCache: TimeInterval = 0
    @ObservationIgnored private var lastPetalRain: TimeInterval = 0
    @ObservationIgnored private var lastSize: CGSize = .zero

    /// How many flowers open before the finale.
    let bloomTarget = 5

    /// How long a bud takes to grow to full in a held hand.
    private let growSeconds: Double = 3.5

    // MARK: - Derived

    /// 0…1: how full your world is. Drives ambient richness.
    var gardenEnergy: Double { min(Double(flowers.count) / Double(bloomTarget), 1) }

    // MARK: - Input (gesture events)

    /// The one entry point for both real hands and touch. Runs on the main actor,
    /// outside the draw loop, so it may change observed state directly.
    func apply(_ event: GestureEvent) {
        switch event {
        case .handAppeared:
            handPresent = true
            lostSince = nil
            wake()

        case let .handMoved(point, pose, _, _):
            handPresent = true
            lostSince = nil
            handPoint = point
            lastHandPoint = point
            handPose = pose
            wake()

        case let .bloomTriggered(point, time):
            // A flick blooms right away, but nudge the bud up so it never looks bare.
            budGrowth = max(budGrowth, 0.25)
            performBloom(at: point, pose: handPose, now: time)

        case .handLost:
            handPresent = false
            lostSince = CACurrentMediaTime()
        }
    }

    private func wake() {
        if journey == .dormant { journey = .awakening }
    }

    // MARK: - Per-frame update (called from the Canvas draw closure)

    func update(now: TimeInterval, size: CGSize) {
        lastSize = size
        let rawDelta = now - lastUpdate
        let dt = min(rawDelta, 0.05)
        lastUpdate = now
        guard dt > 0 else { return }
        if rawDelta > 0 { fps = fps * 0.9 + (1.0 / rawDelta) * 0.1 }

        refreshMomentCache(now: now)
        updateVeil(dt: dt)
        updateBud(dt: dt, now: now)
        updateFinale(now: now, size: size)

        let dustTarget = 24 + Int(gardenEnergy * 30)
        particles.maintainDust(in: size, targetCount: dustTarget)
        particles.update(dt: dt, attractor: handPresent ? handPoint : nil)
    }

    /// Eases the veil toward its brightness-driven target so lighting changes are smooth.
    private func updateVeil(dt: Double) {
        veilOpacity += (veilTarget() - veilOpacity) * min(dt * 2, 1)
    }

    private func veilTarget() -> Double {
        // During and after the finale, light wins: the veil nearly vanishes.
        switch journey {
        case .finale, .afterglow: return 0.05
        default: break
        }
        guard mirrorMode == .live else { return 0.3 }   // the enchanted mirror stays dim
        // A bright room (0.7+) barely dims; a dark room (0.15) dims to 0.35.
        return remap(cachedMoment.roomBrightness, 0.15, 0.7, 0.35, 0.05)
    }

    /// Grows the bud while a hand is held, and decides what happens when it leaves —
    /// always ending in a flower or a gentle dissolve, never a dead bud.
    private func updateBud(dt: Double, now: TimeInterval) {
        if handPresent, let point = handPoint {
            budGrowth = min(budGrowth + dt / growSeconds, 1.0)
            particles.spawnGather(around: point, count: 2, hue: cachedMoment.roomHue)

            // Once full, hold a beat and bloom on its own — so a player who never
            // discovers the flick still always gets a flower.
            if budGrowth >= 1.0 {
                if fullyGrownSince == nil { fullyGrownSince = now }
                if now - (fullyGrownSince ?? now) > 0.5 {
                    performBloom(at: point, pose: handPose, now: now)
                }
            } else {
                fullyGrownSince = nil
            }
            return
        }

        // Hand is gone. Wait out a short grace period in case it flickers back.
        if let lost = lostSince, now - lost > 0.35 {
            if budGrowth > 0.4, let point = lastHandPoint {
                performBloom(at: point, pose: handPose, now: now)
            } else {
                dissolveBud()
            }
            lostSince = nil
            handPoint = nil
        }
    }

    private func dissolveBud() {
        if budGrowth > 0.05, let point = lastHandPoint {
            particles.burstBloom(at: point, hue: cachedMoment.roomHue, count: 10)
        }
        budGrowth = 0
        fullyGrownSince = nil
    }

    /// During the finale, rain petals from the top and, after a while, settle into afterglow.
    private func updateFinale(now: TimeInterval, size: CGSize) {
        guard case let .finale(start) = journey else { return }
        if now - lastPetalRain > 0.2 {
            lastPetalRain = now
            particles.spawnPetalRain(in: size, hue: cachedMoment.roomHue, count: 3)
        }
        if now - start > 8 {
            scheduleJourney(.afterglow)
        }
    }

    // MARK: - Blooming

    private func performBloom(at point: CGPoint, pose: HandPose, now: TimeInterval) {
        // Read this exact moment and grow a flower deterministically from it.
        let moment = momentProvider()
        let castX = lastSize.width > 0 ? point.x / lastSize.width : 0.5
        let seed = FlowerSeed(moment: moment, pose: pose, growth: budGrowth, castXUnit: castX)
        let flower = FlowerGrower.grow(from: seed)

        let radius = displayRadius(for: flower)
        let bloomed = BloomedFlower(flower: flower, birthTime: now, anchor: point,
                                    bakedRadius: radius, headImage: nil)
        flowers.append(bloomed)
        particles.burstBloom(at: point, hue: flower.tipHue, count: 55)
        bakeHead(for: bloomed.id, flower: flower, radius: radius)

        budGrowth = 0
        fullyGrownSince = nil

        // Advance the journey. `== bloomTarget` fires the finale exactly once.
        if flowers.count == bloomTarget {
            scheduleJourney(.finale(start: now))
        } else if flowers.count < bloomTarget {
            scheduleJourney(.blooming)
        }
    }

    /// The on-screen radius of a flower head, from the canvas size and the flower's size.
    func displayRadius(for flower: Flower) -> CGFloat {
        min(lastSize.width, lastSize.height) * 0.065 * flower.sizeScale
    }

    /// Bakes the head image off the draw loop and slots it into the flower when ready.
    /// Until then the canvas falls back to drawing the head as vectors.
    private func bakeHead(for id: UUID, flower: Flower, radius: CGFloat) {
        Task { @MainActor in
            guard let image = flower.rasterizedHead(radius: radius) else { return }
            if let index = flowers.firstIndex(where: { $0.id == id }) {
                flowers[index].headImage = image
            }
        }
    }

    /// Changing observed state from inside the draw loop would upset SwiftUI, so we hop
    /// to the next main-actor turn to do it safely.
    private func scheduleJourney(_ phase: JourneyPhase) {
        Task { @MainActor in
            if self.journey != phase { self.journey = phase }
        }
    }

    // MARK: - Flower motion

    /// A flower bobs gently around its anchor, so your world feels alive without drifting.
    func position(of flower: BloomedFlower, now: TimeInterval) -> CGPoint {
        let age = now - flower.birthTime
        let bob = CGFloat(sin(age * 0.9 + flower.flower.swayPhase)) * (flower.bakedRadius * 0.05)
        return CGPoint(x: flower.anchor.x, y: flower.anchor.y + bob)
    }

    /// Pops the flower open from small to full over ~0.8 seconds.
    func popScale(of flower: BloomedFlower, now: TimeInterval) -> CGFloat {
        let t = min((now - flower.birthTime) / 0.8, 1)
        return CGFloat(0.3 + 0.7 * easeOut(t))
    }

    // MARK: - Moment cache

    private func refreshMomentCache(now: TimeInterval) {
        if now - lastMomentCache > 0.5 {
            cachedMoment = momentProvider()
            lastMomentCache = now
        }
    }
}

// MARK: - Small math helpers

/// Ease-out: fast start, gentle finish.
private func easeOut(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return 1 - (1 - x) * (1 - x)
}

/// Maps `v` from one range to another, clamped to the output range.
private func remap(_ v: Double, _ inLow: Double, _ inHigh: Double,
                   _ outLow: Double, _ outHigh: Double) -> Double {
    let t = min(max((v - inLow) / (inHigh - inLow), 0), 1)
    return outLow + t * (outHigh - outLow)
}
