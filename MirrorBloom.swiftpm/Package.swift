// swift-tools-version: 5.9

// MirrorBloom (working title) — a magic mirror where your real hand grows a flower
// shaped by this very moment: your hand pose, your smile, and the light of your room.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "MirrorBloom",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "MirrorBloom",
            targets: ["AppModule"],
            bundleIdentifier: "com.sena327.MirrorBloom",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .flower),
            accentColor: .presetColor(.pink),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeLeft,
                .landscapeRight
            ],
            capabilities: [
                .camera(purposeString: "The mirror looks at your hands, your smile, and the light of your room to shape each flower. Everything stays on your device; nothing is recorded or saved.")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
