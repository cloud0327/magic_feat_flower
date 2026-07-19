import SwiftUI

/// Five families of flowers — one for each shape a hand can make.
enum FlowerFamily {
    case sunbloom    // open palm: broad, generous petals
    case bellspire   // pointing finger: a tall, downward-chiming bell
    case twinbloom   // peace sign: two heads on one stem
    case burststar   // fist that opens: a spiky chrysanthemum burst
    case budCluster  // pinch: a constellation of tiny florets

    static func from(pose: HandPose) -> FlowerFamily {
        switch pose {
        case .openPalm, .unknown: return .sunbloom
        case .point: return .bellspire
        case .peace: return .twinbloom
        case .fist: return .burststar
        case .pinchPose: return .budCluster
        }
    }
}

/// The quantized "moment" a flower is grown from. Same moment → same seed → same
/// flower, deterministically. But no moment ever comes twice.
struct FlowerSeed {
    var pose: HandPose
    var smileBucket: Int        // 0…2
    var mouthOpenBucket: Int    // 0…1
    var hueBucket: Int          // 0…11 — the room's color wheel, coarsely
    var brightnessBucket: Int   // 0 dark room … 2 bright room
    var saturationBucket: Int   // 0…2
    var growthBucket: Int       // 0…3 — how long the bud was nursed
    var positionBucket: Int     // 0…3 — where on the mirror it was cast

    init(moment: MomentSnapshot, pose: HandPose, growth: Double, castXUnit: Double) {
        self.pose = pose
        smileBucket = min(Int(moment.smile * 3), 2)
        mouthOpenBucket = moment.mouthOpen > 0.5 ? 1 : 0
        hueBucket = min(Int(moment.roomHue * 12), 11)
        brightnessBucket = min(Int(moment.roomBrightness * 3), 2)
        saturationBucket = min(Int(moment.roomSaturation * 3), 2)
        growthBucket = min(Int(growth * 4), 3)
        positionBucket = min(max(Int(castXUnit * 4), 0), 3)
    }

    /// FNV-1a over the buckets: a stable, order-sensitive 64-bit fingerprint.
    var fingerprint: UInt64 {
        let parts = [pose.rawValue.hashValueStable, UInt64(smileBucket), UInt64(mouthOpenBucket),
                     UInt64(hueBucket), UInt64(brightnessBucket), UInt64(saturationBucket),
                     UInt64(growthBucket), UInt64(positionBucket)]
        var hash: UInt64 = 0xcbf29ce484222325
        for part in parts {
            for byte in 0..<8 {
                hash ^= (part >> (byte * 8)) & 0xff
                hash = hash &* 0x100000001b3
            }
        }
        return hash
    }
}

private extension String {
    /// String.hashValue changes between runs; FNV-1a over UTF-8 does not.
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return hash
    }
}

/// SplitMix64: a tiny, high-quality deterministic random stream from one seed.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }
    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}

/// A fully grown flower: pure parameters, ready to be drawn anywhere.
struct Flower {
    var family: FlowerFamily
    var petalCount: Int
    var layers: Int
    var petalAspect: CGFloat    // petal width ÷ length
    var curl: CGFloat           // 0 round tip … 1 pointed tip
    var openness: Double        // from the smile: 0.45 shy bud … 1 full bloom
    var baseHue: Double
    var tipHue: Double
    var saturation: Double
    var brightness: Double
    var luminous: Bool          // grown in a dark room: it makes its own light
    var centerRadius: CGFloat   // relative to head radius
    var centerHue: Double
    var stemLean: CGFloat       // -0.25…0.25, as a fraction of stem height
    var sizeScale: CGFloat      // from how long the bud was nursed
    var swayPhase: Double
}

enum FlowerGrower {
    /// Hues the garden is allowed to wear — every room color snaps to the nearest,
    /// so any two flowers always sit well together (color can never fail).
    static let palette: [Double] = [0.99, 0.05, 0.09, 0.13, 0.16, 0.55, 0.62, 0.68, 0.75, 0.82, 0.88, 0.94]

    static func grow(from seed: FlowerSeed) -> Flower {
        var rng = SeededRandom(seed: seed.fingerprint)
        let family = FlowerFamily.from(pose: seed.pose)

        // The room paints the petals; the smile warms and opens them.
        let roomHue = (Double(seed.hueBucket) + 0.5) / 12
        let baseHue = nearest(in: palette, to: roomHue)
        let smile = Double(seed.smileBucket) / 2
        let tipHue = wrap(baseHue + rng.double(in: -0.04...0.04) + smile * 0.04)
        let luminous = seed.brightnessBucket == 0
        let saturation = 0.45 + Double(seed.saturationBucket) * 0.15 + smile * 0.08
        let brightness = luminous ? 1.0 : 0.82 + Double(seed.brightnessBucket) * 0.08

        let petalCount: Int
        let aspect: Double
        let curl: Double
        switch family {
        case .sunbloom:   petalCount = rng.int(in: 8...13);  aspect = rng.double(in: 0.40...0.55); curl = rng.double(in: 0.15...0.45)
        case .bellspire:  petalCount = rng.int(in: 5...7);   aspect = rng.double(in: 0.30...0.40); curl = rng.double(in: 0.55...0.85)
        case .twinbloom:  petalCount = rng.int(in: 6...9);   aspect = rng.double(in: 0.38...0.50); curl = rng.double(in: 0.25...0.55)
        case .burststar:  petalCount = rng.int(in: 16...22); aspect = rng.double(in: 0.10...0.18); curl = rng.double(in: 0.70...0.95)
        case .budCluster: petalCount = rng.int(in: 5...6);   aspect = rng.double(in: 0.45...0.60); curl = rng.double(in: 0.10...0.30)
        }

        let growth = Double(seed.growthBucket) / 3
        var layers = 1 + (seed.growthBucket >= 2 ? 1 : 0) + (seed.growthBucket >= 3 ? 1 : 0)
        if family == .burststar { layers = max(layers, 2) }
        if seed.mouthOpenBucket == 1 { layers = min(layers + 1, 3) }   // surprise adds a flourish

        return Flower(
            family: family,
            petalCount: petalCount,
            layers: layers,
            petalAspect: aspect,
            curl: curl,
            openness: 0.45 + smile * 0.55,
            baseHue: baseHue,
            tipHue: tipHue,
            saturation: saturation,
            brightness: brightness,
            luminous: luminous,
            centerRadius: rng.double(in: 0.14...0.24),
            centerHue: wrap(0.12 + rng.double(in: -0.03...0.03)),   // a golden heart
            stemLean: rng.double(in: -0.22...0.22),
            sizeScale: 0.85 + growth * 0.45,
            swayPhase: rng.double(in: 0...(2 * .pi))
        )
    }

    private static func nearest(in palette: [Double], to hue: Double) -> Double {
        palette.min { hueDistance($0, hue) < hueDistance($1, hue) } ?? hue
    }
    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b); return min(d, 1 - d)
    }
    private static func wrap(_ hue: Double) -> Double {
        var h = hue.truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }; return h
    }
}

// MARK: - Drawing

extension Flower {
    var baseColor: Color { Color(hue: baseHue, saturation: saturation, brightness: brightness * 0.85) }
    var tipColor: Color { Color(hue: tipHue, saturation: saturation * 0.8, brightness: brightness) }
    var glowColor: Color { Color(hue: tipHue, saturation: saturation * 0.6, brightness: 1) }

    /// Draws just the head (petals + heart) centered at the origin of `context`'s
    /// current transform. Caller positions, scales and sways via the transform.
    func drawHead(in context: inout GraphicsContext, radius: CGFloat, time: TimeInterval) {
        switch family {
        case .twinbloom:
            for side: CGFloat in [-1, 1] {
                var twin = context
                twin.translateBy(x: side * radius * 0.62, y: -radius * 0.1 * side)
                twin.rotate(by: .radians(Double(side) * 0.18))
                drawSingleHead(in: &twin, radius: radius * 0.66, time: time)
            }
        case .budCluster:
            var rng = SeededRandom(seed: UInt64(bitPattern: Int64(swayPhase * 1e6)))
            for _ in 0..<5 {
                var floret = context
                let angle = rng.double(in: 0...(2 * .pi))
                let dist = rng.double(in: 0.25...0.75) * radius
                floret.translateBy(x: cos(angle) * dist, y: sin(angle) * dist * 0.8)
                drawSingleHead(in: &floret, radius: radius * rng.double(in: 0.28...0.42), time: time)
            }
        default:
            drawSingleHead(in: &context, radius: radius, time: time)
        }
    }

    private func drawSingleHead(in context: inout GraphicsContext, radius: CGFloat, time: TimeInterval) {
        if luminous {
            // A moon flower carries its own halo, breathing slowly.
            let pulse = 0.75 + 0.25 * sin(time * 1.4 + swayPhase)
            let halo = Path(ellipseIn: CGRect(x: -radius * 1.5, y: -radius * 1.5,
                                              width: radius * 3, height: radius * 3))
            context.fill(halo, with: .radialGradient(
                Gradient(colors: [glowColor.opacity(0.35 * pulse), .clear]),
                center: .zero, startRadius: 0, endRadius: radius * 1.5))
        }

        let open = 0.55 + 0.45 * openness
        for layer in 0..<layers {
            let layerScale = 1 - CGFloat(layer) * 0.26
            let length = radius * layerScale * open
            let width = length * petalAspect
            for i in 0..<petalCount {
                var petal = context
                let angleStep = spreadAngle / Double(petalCount)
                let angle = spreadStart + angleStep * (Double(i) + 0.5 + Double(layer) * 0.5)
                petal.rotate(by: .radians(angle))
                let path = Self.petalPath(length: length, width: width, curl: curl)
                petal.fill(path, with: .linearGradient(
                    Gradient(colors: [baseColor, layer == 0 ? tipColor : glowColor]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: -length)))
            }
        }

        let heartR = radius * centerRadius
        let heart = Path(ellipseIn: CGRect(x: -heartR, y: -heartR, width: heartR * 2, height: heartR * 2))
        context.fill(heart, with: .radialGradient(
            Gradient(colors: [Color(hue: centerHue, saturation: 0.55, brightness: 1),
                              Color(hue: centerHue, saturation: 0.85, brightness: 0.75)]),
            center: .zero, startRadius: 0, endRadius: heartR))
    }

    /// Bell flowers fan their petals downward; every other family opens all around.
    private var spreadAngle: Double { family == .bellspire ? 1.9 : 2 * .pi }
    private var spreadStart: Double { family == .bellspire ? .pi - 0.95 : 0 }

    /// One petal pointing "up" (-y) from the origin: two mirrored cubic curves.
    /// `curl` pinches the tip from round (0) to pointed (1).
    static func petalPath(length: CGFloat, width: CGFloat, curl: CGFloat) -> Path {
        var path = Path()
        let tipWidth = width * (1 - curl * 0.75)
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: 0, y: -length),
                      control1: CGPoint(x: -width, y: -length * 0.35),
                      control2: CGPoint(x: -tipWidth, y: -length * 0.8))
        path.addCurve(to: .zero,
                      control1: CGPoint(x: tipWidth, y: -length * 0.8),
                      control2: CGPoint(x: width, y: -length * 0.35))
        path.closeSubpath()
        return path
    }
}
