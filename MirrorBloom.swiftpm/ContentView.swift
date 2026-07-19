import SwiftUI

/// The whole app on one screen: the mirror at the back, the magical garden on top,
/// and a single gentle hint for anyone who hesitates. Everything else is wordless.
struct ContentView: View {
    @State private var world = WorldModel()
    @State private var conductor = SpellConductor()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                MirrorBackdropView(mode: conductor.mode, session: conductor.camera.session)
                GardenCanvasView(world: world)
                HintView(world: world, mode: conductor.mode)
            }
            .contentShape(Rectangle())
            .touchSpell(world: world)
            .onAppear {
                conductor.viewSize = size
                conductor.start(world: world)
            }
            .onChange(of: size) { _, newSize in
                conductor.viewSize = newSize
            }
        }
        .background(.black)
        .ignoresSafeArea()
    }
}

/// One line of guidance, shown only if the player has done nothing for 20 seconds,
/// and only while the mirror is still asleep. It fades away for good the moment the
/// first hand (or touch) arrives.
struct HintView: View {
    let world: WorldModel
    let mode: MirrorMode
    @State private var appeared = Date()

    var body: some View {
        // Re-check the 20-second timer once a second; observation hides it instantly
        // once `journey` leaves `.dormant`.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let waitedLongEnough = Date().timeIntervalSince(appeared) > 20
            let show = world.journey == .dormant && waitedLongEnough

            VStack {
                Spacer()
                Text(mode == .live ? "Raise your hand" : "Touch and hold")
                    .font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 80)
                    .opacity(show ? 1 : 0)
                    .animation(.easeInOut(duration: 1.5), value: show)
            }
        }
        .allowsHitTesting(false)
    }
}
