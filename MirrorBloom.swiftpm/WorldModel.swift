import SwiftUI
import QuartzCore
import Observation

/// The five stages of the three-minute journey. Time only moves forward.
enum JourneyPhase: Equatable {
    case dormant                     // dark mirror, waiting for a hand
    case awakening                   // a hand has appeared; light answers it
    case blooming                    // flowers are being grown, 1…4
    case finale(start: TimeInterval) // the fifth flower — the garden fills with light
    case afterglow                   // a calm sky to keep playing under
}

/// A flower that has bloomed and is (or has finished) drifting to its garden spot.
struct BloomedFlower: Identifiable {
    let id = UUID()
    var flower: Flower
    var birthTime: TimeInterval
    var from: CGPoint    // where the caster's bud opened
    var to: CGPoint      // the resting spot it drifts toward
}

/// The single source of truth for the experience.
///
/// Only `journey` and `mirrorMode` are observed, because they change rarely and
/// should refresh the UI. Everything the draw loop touches every frame is marked
/// `@ObservationIgnored` so SwiftUI is never invalidated 60 times a second.
///
/// All access happens on the main thread: gesture events arrive on the main actor,
/// and `update(now:size:)` is called from the Canvas draw closure (also main).
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

    /// The moment, sampled twice a second, so the growing bud can preview its color.
    @ObservationIgnored private(set) var cachedMoment = MomentSnapshot.clockFallback()

    // Hand and bud
    @ObservationIgnored private(set) var handPoint: CGPoint?     // nil when no bud is held
    @ObservationIgnored private(set) var handPose: HandPose = .unknown
    @ObservationIgnored private(set) var budGrowth: Double = 0   // 0…1
    @ObservationIgnored private var handPresent = false
    @ObservationIgnored private var lastHandPoint: CGPoint?
    @ObservationIgnored private var lostSince: TimeInterval?
    @ObservationIgnored private var fullyGrownSince: TimeInterval?

    // Timing / bookkeeping
    @ObservationIgnored private var lastUpdate: TimeInterval = 0
    @ObservationIgnored private var lastMomentCache: TimeInterval = 0
    @ObservationIgnored private var lastSize: CGSize = .zero

    /// How many flowers fill the garden before the finale.
    let bloomTarget = 5

    /// How long a flower takes to drift from the hand to its garden spot.
    private let driftDuration: TimeInterval = 2.5

    /// How long a bud takes to grow to full, held in an open hand.
    private let growSeconds: Double = 3.5

    // MARK: - Derived values

    /// 0…1: how full the garden is. Drives ambient richness and vines.
    var gardenEnergy: Double { min(Double(flowers.count) / Double(bloomTarget), 1) }

    /// How dark the mirror's veil is right now. It lifts during the finale so the
    /// caster finally sees themselves clearly, framed by their flowers.
    func backdropDim(now: TimeInterval) -> Double {
        switch journey {
        case .finale(let start):
            let t = easeInOut(min((now - start) / 4, 1))
            return 0.55 - t * (0.55 - 0.12)
        case .afterglow:
            return 0.12
        default:
            return 0.55
        }
    }

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
        let dt = min(now - lastUpdate, 0.05)
        lastUpdate = now
        guard dt > 0 else { return }

        refreshMomentCache(now: now)
        updateBud(dt: dt, now: now)
        updateDriftingFlowers(now: now)
        advanceToAfterglow(now: now)

        let dustTarget = 30 + Int(gardenEnergy * 40)
        particles.maintainDust(in: size, targetCount: dustTarget)
        particles.update(dt: dt, attractor: handPresent ? handPoint : nil)
    }

    /// Grows the bud while a hand is held, and decides what happens when the hand
    /// leaves — always ending in a flower or a gentle dissolve, never a dead bud.
    private func updateBud(dt: Double, now: TimeInterval) {
        if handPresent, let point = handPoint {
            budGrowth = min(budGrowth + dt / growSeconds, 1.0)
            particles.spawnGather(around: point, count: 2, hue: cachedMoment.roomHue)

            // Once full, hold a beat and then bloom on its own — so a player who
            // never discovers the flick still always gets a flower.
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

    /// Leaves a faint wake behind each flower still drifting to its spot.
    private func updateDriftingFlowers(now: TimeInterval) {
        for flower in flowers where settleFraction(of: flower, now: now) < 1 {
            if Int.random(in: 0..<2) == 0 {
                particles.trail(at: position(of: flower, now: now), hue: flower.flower.tipHue)
            }
        }
    }

    // MARK: - Blooming

    private func performBloom(at point: CGPoint, pose: HandPose, now: TimeInterval) {
        // Read this exact moment and grow a flower deterministically from it.
        let moment = momentProvider()
        let castX = lastSize.width > 0 ? point.x / lastSize.width : 0.5
        let seed = FlowerSeed(moment: moment, pose: pose, growth: budGrowth, castXUnit: castX)
        let flower = FlowerGrower.grow(from: seed)

        let slot = gardenSlot(index: flowers.count, size: lastSize)
        flowers.append(BloomedFlower(flower: flower, birthTime: now, from: point, to: slot))
        particles.burstBloom(at: point, hue: flower.tipHue, count: 60)

        budGrowth = 0
        fullyGrownSince = nil

        // Advance the journey. `== bloomTarget` fires the finale exactly once.
        if flowers.count == bloomTarget {
            scheduleJourney(.finale(start: now))
        } else if flowers.count < bloomTarget {
            scheduleJourney(.blooming)
        }
    }

    private func advanceToAfterglow(now: TimeInterval) {
        if case let .finale(start) = journey, now - start > 8 {
            scheduleJourney(.afterglow)
        }
    }

    /// Changing observed state from inside the draw loop would upset SwiftUI, so we
    /// hop to the next main-actor turn to do it safely.
    private func scheduleJourney(_ phase: JourneyPhase) {
        Task { @MainActor in
            if self.journey != phase { self.journey = phase }
        }
    }

    // MARK: - Garden layout & flower motion

    /// A stable resting spot for the n-th flower. The first `bloomTarget` line the
    /// lower meadow; any extras (during afterglow) settle a little higher up.
    func gardenSlot(index: Int, size: CGSize) -> CGPoint {
        let golden = 0.61803398875
        let spread = (0.15 + Double(index) * golden).truncatingRemainder(dividingBy: 1)
        let x = (0.10 + spread * 0.80) * size.width
        let y: CGFloat
        if index < bloomTarget {
            let row = Double(index % 3) / 2   // gentle up-and-down along the meadow
            y = (0.80 + row * 0.08) * size.height
        } else {
            y = (0.60 + spread * 0.15) * size.height
        }
        return CGPoint(x: x, y: y)
    }

    /// Where a flower is right now: easing from `from` to `to` over the drift, then resting.
    func position(of flower: BloomedFlower, now: TimeInterval) -> CGPoint {
        let f = settleFraction(of: flower, now: now)
        guard f < 1 else { return flower.to }
        return lerp(flower.from, flower.to, easeInOut(f))
    }

    /// 0 at bloom, 1 once the flower has fully settled into the garden.
    func settleFraction(of flower: BloomedFlower, now: TimeInterval) -> Double {
        min((now - flower.birthTime) / driftDuration, 1)
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

/// Smoothstep easing: slow in, slow out.
private func easeInOut(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}

private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}
