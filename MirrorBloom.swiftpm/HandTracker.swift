import Vision
import CoreVideo
import QuartzCore
import Foundation

/// One filtered reading of the player's hand, in *view* coordinates.
/// Everything downstream (gestures, world, drawing) uses this and never touches Vision.
struct HandSnapshot {
    var palm: CGPoint            // stable center of the hand
    var pinchPoint: CGPoint      // midpoint of thumb tip and index tip
    var fingertips: [CGPoint]    // thumb, index, middle, ring, little (view space)
    var extended: [Bool]         // same order — is each finger stretched out?
    var handScale: CGFloat       // wrist→middle-knuckle distance; normalizes all ratios
    var pinchRatio: CGFloat      // thumb-index distance ÷ handScale (distance-invariant)
    var opennessRatio: CGFloat   // mean fingertip distance from palm ÷ handScale
    var velocity: CGVector       // palm velocity, points/second
    var time: TimeInterval
}

/// Runs Vision hand detection on camera frames (throttled), converts the joints
/// into view space and smooths them. Emits a snapshot — or nil when no hand is seen.
final class HandTracker {
    /// Called on the camera queue after each processed frame (nil = no confident hand).
    var onSnapshot: ((HandSnapshot?) -> Void)?

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1   // one caster; the most confident hand wins
        return request
    }()

    private var lastRun: TimeInterval = 0
    private let minInterval: TimeInterval = 1.0 / 20.0   // 20 Hz; One-Euro fills the gaps

    private let viewSizeLock = NSLock()
    private var _viewSize: CGSize = .zero
    func setViewSize(_ size: CGSize) {
        viewSizeLock.lock(); _viewSize = size; viewSizeLock.unlock()
    }
    private var viewSize: CGSize {
        viewSizeLock.lock(); defer { viewSizeLock.unlock() }; return _viewSize
    }

    // One-Euro filters keep still hands rock-steady and fast hands low-latency.
    private var palmFilter = OneEuroPoint()
    private var pinchFilter = OneEuroPoint()
    private var tipFilters = (0..<5).map { _ in OneEuroPoint() }
    private var previousPalm: (point: CGPoint, time: TimeInterval)?

    private let joints: [[VNHumanHandPoseObservation.JointName]] = [
        [.thumbTip, .thumbMP],
        [.indexTip, .indexMCP],
        [.middleTip, .middleMCP],
        [.ringTip, .ringMCP],
        [.littleTip, .littleMCP]
    ]

    /// Camera-queue entry point.
    func process(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastRun >= minInterval else { return }
        lastRun = now

        let size = viewSize
        guard size.width > 1, size.height > 1 else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
        else { reportLoss(); return }

        guard let points = try? observation.recognizedPoints(.all),
              let wrist = points[.wrist], wrist.confidence > 0.3,
              let middleMCP = points[.middleMCP], middleMCP.confidence > 0.3
        else { reportLoss(); return }

        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer))
        let map = { (p: VNRecognizedPoint) -> CGPoint in
            Self.viewPoint(normalized: p.location, buffer: bufferSize, view: size)
        }

        let wristP = map(wrist)
        let knuckleP = map(middleMCP)
        let handScale = max(hypot(knuckleP.x - wristP.x, knuckleP.y - wristP.y), 1)

        // Fingertips + per-finger "stretched out" flags (tip much farther from the
        // wrist than its base joint). Low-confidence joints count as not extended.
        var tips: [CGPoint] = []
        var extended: [Bool] = []
        for (i, pair) in joints.enumerated() {
            guard let tip = points[pair[0]], tip.confidence > 0.3,
                  let base = points[pair[1]], base.confidence > 0.3 else {
                tips.append(knuckleP); extended.append(false); continue
            }
            let tipP = tipFilters[i].filter(map(tip), at: now)
            let baseP = map(base)
            let tipDist = hypot(tipP.x - wristP.x, tipP.y - wristP.y)
            let baseDist = max(hypot(baseP.x - wristP.x, baseP.y - wristP.y), 1)
            tips.append(tipP)
            // The thumb's base sits close to the wrist, so it needs a laxer ratio.
            extended.append(tipDist / baseDist > (i == 0 ? 1.25 : 1.45))
        }

        let rawPalm = CGPoint(x: (wristP.x + knuckleP.x) / 2, y: (wristP.y + knuckleP.y) / 2)
        let palm = palmFilter.filter(rawPalm, at: now)
        let pinchMid = CGPoint(x: (tips[0].x + tips[1].x) / 2, y: (tips[0].y + tips[1].y) / 2)
        let pinch = pinchFilter.filter(pinchMid, at: now)

        var velocity = CGVector.zero
        if let prev = previousPalm, now > prev.time {
            let dt = now - prev.time
            velocity = CGVector(dx: (palm.x - prev.point.x) / dt, dy: (palm.y - prev.point.y) / dt)
        }
        previousPalm = (palm, now)

        let pinchRatio = hypot(tips[0].x - tips[1].x, tips[0].y - tips[1].y) / handScale
        let openness = tips.dropFirst().map { hypot($0.x - palm.x, $0.y - palm.y) }
            .reduce(0, +) / 4 / handScale

        onSnapshot?(HandSnapshot(
            palm: palm, pinchPoint: pinch, fingertips: tips, extended: extended,
            handScale: handScale, pinchRatio: pinchRatio, opennessRatio: openness,
            velocity: velocity, time: now
        ))
    }

    private func reportLoss() {
        previousPalm = nil
        palmFilter.reset(); pinchFilter.reset()
        for i in tipFilters.indices { tipFilters[i].reset() }
        onSnapshot?(nil)
    }

    /// Vision gives normalized points with the origin at the *bottom left* of the
    /// (already rotated + mirrored) buffer. Flip y, then aspect-fill into the view.
    static func viewPoint(normalized: CGPoint, buffer: CGSize, view: CGSize) -> CGPoint {
        let p = CGPoint(x: normalized.x, y: 1 - normalized.y)
        let scale = max(view.width / buffer.width, view.height / buffer.height)
        let scaled = CGSize(width: buffer.width * scale, height: buffer.height * scale)
        let offset = CGPoint(x: (view.width - scaled.width) / 2,
                             y: (view.height - scaled.height) / 2)
        return CGPoint(x: offset.x + p.x * scaled.width,
                       y: offset.y + p.y * scaled.height)
    }
}

/// The One-Euro filter (Casiez et al.): an adaptive low-pass filter whose cutoff
/// rises with speed — still points stop jittering, fast moves stay responsive.
struct OneEuroPoint {
    var minCutoff: Double = 1.2   // Hz — lower = smoother when still
    var beta: Double = 0.015      // how quickly cutoff opens up with speed
    var dCutoff: Double = 1.0

    private var x = OneEuroAxis()
    private var y = OneEuroAxis()

    mutating func filter(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        CGPoint(x: x.filter(point.x, at: time, minCutoff: minCutoff, beta: beta, dCutoff: dCutoff),
                y: y.filter(point.y, at: time, minCutoff: minCutoff, beta: beta, dCutoff: dCutoff))
    }

    mutating func reset() { x = OneEuroAxis(); y = OneEuroAxis() }
}

private struct OneEuroAxis {
    private var previous: (value: Double, derivative: Double, time: TimeInterval)?

    mutating func filter(_ value: Double, at time: TimeInterval,
                         minCutoff: Double, beta: Double, dCutoff: Double) -> Double {
        guard let prev = previous, time > prev.time else {
            previous = (value, 0, time)
            return value
        }
        let dt = time - prev.time
        let rawDerivative = (value - prev.value) / dt
        let derivative = smooth(rawDerivative, previous: prev.derivative, cutoff: dCutoff, dt: dt)
        let cutoff = minCutoff + beta * abs(derivative)
        let filtered = smooth(value, previous: prev.value, cutoff: cutoff, dt: dt)
        previous = (filtered, derivative, time)
        return filtered
    }

    private func smooth(_ value: Double, previous: Double, cutoff: Double, dt: Double) -> Double {
        let r = 2 * Double.pi * cutoff * dt
        let alpha = r / (r + 1)
        return alpha * value + (1 - alpha) * previous
    }
}
