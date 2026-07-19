import Foundation
import CoreGraphics
import QuartzCore

/// The shape the caster's hand is making. Each pose grows a different flower family.
enum HandPose: String, CaseIterable {
    case openPalm   // all fingers out            → wide sunbloom
    case point      // index only                 → tall bellspire
    case peace      // index + middle             → twin bloom
    case fist       // nothing extended           → bursting star
    case pinchPose  // thumb + index almost touch → cluster of tiny buds
    case unknown
}

/// The common currency of the whole app. Real hands (Vision) and touches
/// (fallback) both speak only in these events, so the two paths share one world.
enum GestureEvent {
    case handAppeared(time: TimeInterval)
    case handMoved(to: CGPoint, pose: HandPose, velocity: CGVector, time: TimeInterval)
    case bloomTriggered(at: CGPoint, time: TimeInterval)   // a flick — bloom *now*
    case handLost(time: TimeInterval)
}

/// Turns raw hand snapshots into debounced, hysteresis-guarded gesture events.
/// Pure logic — no Vision, no SwiftUI — so it is trivial to reason about and tune.
final class GestureEngine {
    /// Every tunable in one place, waiting for the real-device tuning pass (M7).
    enum Tunables {
        static let appearFrames = 3        // hand must persist ~0.1 s to appear…
        static let vanishFrames = 10       // …but ~0.33 s to vanish (asymmetric)
        static let poseFrames = 4          // a new pose must hold before it counts
        static let pinchOn: CGFloat = 0.35 // pinchRatio below this = pinching…
        static let pinchOff: CGFloat = 0.55// …and must rise past this to release
        static let flickSpeed: CGFloat = 900   // points/sec that reads as a throw
        static let flickCooldown: TimeInterval = 1.0
    }

    private var presentStreak = 0
    private var absentStreak = 0
    private var isPresent = false

    private var stablePose: HandPose = .unknown
    private var candidatePose: HandPose = .unknown
    private var candidateStreak = 0
    private var isPinched = false

    private var lastFlick: TimeInterval = 0

    /// Main-actor entry point: one snapshot (or nil) in, zero or more events out.
    func ingest(_ snapshot: HandSnapshot?) -> [GestureEvent] {
        let now = snapshot?.time ?? CACurrentMediaTime()
        var events: [GestureEvent] = []

        guard let snap = snapshot else {
            presentStreak = 0
            absentStreak += 1
            if isPresent && absentStreak >= Tunables.vanishFrames {
                isPresent = false
                stablePose = .unknown
                isPinched = false
                events.append(.handLost(time: now))
            }
            return events
        }

        absentStreak = 0
        presentStreak += 1
        if !isPresent {
            guard presentStreak >= Tunables.appearFrames else { return events }
            isPresent = true
            events.append(.handAppeared(time: now))
        }

        updatePose(with: snap)

        // A fast throw of the whole hand blooms the bud immediately.
        let speed = hypot(snap.velocity.dx, snap.velocity.dy)
        if speed > Tunables.flickSpeed, now - lastFlick > Tunables.flickCooldown {
            lastFlick = now
            events.append(.bloomTriggered(at: snap.palm, time: now))
        }

        events.append(.handMoved(to: snap.palm, pose: stablePose,
                                 velocity: snap.velocity, time: now))
        return events
    }

    /// Classifies the finger-extension pattern, with two guards against noise:
    /// pinch uses split on/off thresholds, and any new pose must persist a few frames.
    private func updatePose(with snap: HandSnapshot) {
        // Pinch hysteresis runs first — it overrides the finger pattern.
        if isPinched {
            if snap.pinchRatio > Tunables.pinchOff { isPinched = false }
        } else {
            if snap.pinchRatio < Tunables.pinchOn { isPinched = true }
        }

        let raw: HandPose
        let extendedCount = snap.extended.filter { $0 }.count
        if isPinched {
            raw = .pinchPose
        } else if extendedCount >= 4 {
            raw = .openPalm
        } else if snap.extended[1] && snap.extended[2] && !snap.extended[3] && !snap.extended[4] {
            raw = .peace
        } else if snap.extended[1] && !snap.extended[2] && !snap.extended[3] && !snap.extended[4] {
            raw = .point
        } else if extendedCount == 0 {
            raw = .fist
        } else {
            raw = stablePose == .unknown ? .openPalm : stablePose   // ambiguous: keep calm
        }

        if raw == stablePose {
            candidateStreak = 0
        } else if raw == candidatePose {
            candidateStreak += 1
            if candidateStreak >= Tunables.poseFrames {
                stablePose = raw
                candidateStreak = 0
            }
        } else {
            candidatePose = raw
            candidateStreak = 1
        }
    }
}
