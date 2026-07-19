import SwiftUI
import QuartzCore

/// Lets a finger (or a trackpad click on Mac) cast exactly like a real hand.
///
/// Touch and hand tracking both speak only in `GestureEvent`s, so the world can't
/// tell them apart — the fallback path is always as good as the main one, and it
/// doubles as the way to develop in the simulator, where there is no camera.
///
/// Touch and hold to grow a bud; lift to bloom the flower.
struct TouchSpellModifier: ViewModifier {
    let world: WorldModel

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let now = CACurrentMediaTime()
                    // Treat every touch as an open palm — the friendliest default pose.
                    world.apply(.handAppeared(time: now))
                    world.apply(.handMoved(to: value.location, pose: .openPalm,
                                           velocity: .zero, time: now))
                }
                .onEnded { value in
                    let now = CACurrentMediaTime()
                    world.apply(.bloomTriggered(at: value.location, time: now))
                    world.apply(.handLost(time: now))
                }
        )
    }
}

extension View {
    /// Attaches the touch-casting fallback to a view.
    func touchSpell(world: WorldModel) -> some View {
        modifier(TouchSpellModifier(world: world))
    }
}
