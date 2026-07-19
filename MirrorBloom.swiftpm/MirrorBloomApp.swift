import SwiftUI
import Observation

@main
struct MirrorBloomApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// Wires the camera, the trackers and the world together.
/// Everything user-visible lives in WorldModel; this class only routes signals.
@Observable
final class SpellConductor {
    let camera = CameraService()
    let hands = HandTracker()
    let moment = MomentReader()
    @ObservationIgnored let gestures = GestureEngine()

    /// Which mirror the player got: the live camera, or the enchanted black mirror.
    private(set) var mode: MirrorMode = .undecided

    @ObservationIgnored private weak var world: WorldModel?

    /// The canvas size, needed to map Vision's normalized points into view space.
    var viewSize: CGSize = .zero {
        didSet { hands.setViewSize(viewSize) }
    }

    @MainActor
    func start(world: WorldModel) {
        guard self.world == nil else { return }   // idempotent — onAppear can fire twice
        self.world = world

        // The world asks "what is this moment?" only when a flower actually blooms.
        world.momentProvider = { [moment, weak self] in
            moment.currentSnapshot(mode: self?.mode ?? .enchanted)
        }

        // Camera frames fan out to both readers on the camera queue.
        camera.onFrame = { [hands, moment] pixelBuffer in
            hands.process(pixelBuffer)
            moment.process(pixelBuffer)
        }

        // Hand snapshots (or their absence) become gesture events on the main actor.
        hands.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                guard let self, let world = self.world else { return }
                for event in self.gestures.ingest(snapshot) {
                    world.apply(event)
                }
            }
        }

        Task { @MainActor in
            let mode = await camera.configureAndStart()
            self.mode = mode
            world.mirrorMode = mode
        }
    }
}
