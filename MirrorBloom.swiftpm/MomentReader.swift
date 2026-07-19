import Vision
import CoreVideo
import QuartzCore
import Foundation

/// What the mirror knows about *this moment* — read only when a flower blooms.
/// Every value is computed on-device and immediately forgotten.
struct MomentSnapshot {
    var smile: Double            // 0 neutral … 1 big smile
    var mouthOpen: Double        // 0 closed … 1 wide open (surprise!)
    var faceSeen: Bool
    var roomHue: Double          // dominant hue of the room, 0…1
    var roomBrightness: Double   // 0 dark … 1 bright
    var roomSaturation: Double   // 0 grey … 1 colorful

    /// Without a camera the *clock* becomes the world: dawn, day, dusk and night
    /// each lend the garden their own light. Reality still decides the flower.
    static func clockFallback(date: Date = Date()) -> MomentSnapshot {
        let hour = Calendar.current.component(.hour, from: date)
        let (hue, brightness, saturation): (Double, Double, Double)
        switch hour {
        case 5..<9:   (hue, brightness, saturation) = (0.93, 0.55, 0.50)  // dawn pink
        case 9..<16:  (hue, brightness, saturation) = (0.13, 0.85, 0.55)  // golden day
        case 16..<20: (hue, brightness, saturation) = (0.05, 0.45, 0.65)  // ember dusk
        default:      (hue, brightness, saturation) = (0.70, 0.18, 0.45)  // indigo night
        }
        return MomentSnapshot(smile: 0.5, mouthOpen: 0, faceSeen: false,
                              roomHue: hue, roomBrightness: brightness, roomSaturation: saturation)
    }
}

/// Reads the player's expression (Vision face landmarks, ~3 Hz) and the room's
/// ambient color (sparse pixel sampling, ~2 Hz) from the camera stream.
final class MomentReader {
    private let lock = NSLock()
    private var latest = MomentSnapshot.clockFallback()
    private var faceEverSeen = false

    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var lastFaceRun: TimeInterval = 0
    private var lastSceneRun: TimeInterval = 0

    /// Main-actor read used by the world at bloom time.
    func currentSnapshot(mode: MirrorMode) -> MomentSnapshot {
        if mode != .live { return .clockFallback() }
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Camera-queue entry point. Cheap: each sub-reading runs on its own slow clock.
    func process(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        if now - lastSceneRun >= 1.0 {
            lastSceneRun = now
            readRoom(pixelBuffer)
        }
        if now - lastFaceRun >= 0.5 {
            lastFaceRun = now
            readFace(pixelBuffer)
        }
    }

    // MARK: - Expression

    private func readFace(_ pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([faceRequest])) != nil,
              let face = faceRequest.results?.first,
              let lips = face.landmarks?.outerLips
        else {
            update { $0.faceSeen = false }   // keep last smile: expressions fade, not snap
            return
        }

        // Landmark points are normalized to the face's own bounding box, which makes
        // the ratios below distance-invariant for free.
        let pts = lips.normalizedPoints
        guard pts.count >= 6 else { return }
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)

        // Corners of the mouth vs. its center line: raised corners = smile.
        guard let leftX = xs.min(), let rightX = xs.max() else { return }
        let left = pts.min { abs($0.x - leftX) < abs($1.x - leftX) } ?? .zero
        let right = pts.min { abs($0.x - rightX) < abs($1.x - rightX) } ?? .zero
        let centerY = ys.reduce(0, +) / CGFloat(pts.count)
        let cornerLift = ((left.y + right.y) / 2 - centerY) / max(height, 0.001)

        // Wide mouth + lifted corners → smile. Ranges tuned live in M5.
        let smileRaw = Double((width - 0.55) / 0.25) * 0.6 + Double(cornerLift) * 1.2 + 0.15
        let openRaw = Double((height / max(width, 0.001) - 0.30) / 0.45)

        update {
            $0.faceSeen = true
            // Ease toward the new reading so one noisy frame can't flip the mood.
            $0.smile = $0.smile * 0.6 + min(max(smileRaw, 0), 1) * 0.4
            $0.mouthOpen = $0.mouthOpen * 0.6 + min(max(openRaw, 0), 1) * 0.4
        }
    }

    // MARK: - Room ambience

    /// Averages a sparse grid of the frame (luma + chroma planes) and converts the
    /// mean color to HSB. ~1,300 samples at 2 Hz — effectively free.
    private func readRoom(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        var ySum = 0.0, cbSum = 0.0, crSum = 0.0, count = 0.0
        let step = 32
        var row = 0
        while row < height {
            var col = 0
            while col < width {
                ySum += Double(luma[row * lumaStride + col])
                let cIndex = (row / 2) * chromaStride + (col / 2) * 2
                cbSum += Double(chroma[cIndex])
                crSum += Double(chroma[cIndex + 1])
                count += 1
                col += step
            }
            row += step
        }
        guard count > 0 else { return }

        // BT.601 full-range YCbCr → RGB, then RGB → HSB.
        let y = ySum / count, cb = cbSum / count - 128, cr = crSum / count - 128
        let r = min(max((y + 1.402 * cr) / 255, 0), 1)
        let g = min(max((y - 0.344 * cb - 0.714 * cr) / 255, 0), 1)
        let b = min(max((y + 1.772 * cb) / 255, 0), 1)
        let (hue, saturation, brightness) = Self.hsb(r: r, g: g, b: b)

        update {
            $0.roomHue = hue
            $0.roomBrightness = brightness
            $0.roomSaturation = saturation
        }
    }

    private static func hsb(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0.0001 {
            if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxC > 0.0001 ? delta / maxC : 0
        return (hue, saturation, maxC)
    }

    private func update(_ mutate: (inout MomentSnapshot) -> Void) {
        lock.lock(); mutate(&latest); lock.unlock()
    }
}
