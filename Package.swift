// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnoopyTVScreenSaver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnoopyTVCore", targets: ["SnoopyTVCore"]),
        .library(name: "SnoopySceneKit", targets: ["SnoopySceneKit"]),
        .executable(name: "SnoopySequenceProxyBuilder", targets: ["SnoopySequenceProxyBuilder"]),
        .executable(name: "SnoopyWallpaper", targets: ["SnoopyWallpaper"])
    ],
    targets: [
        // Selection model, calendar/weather context, playback graph (no UI).
        .target(name: "SnoopyTVCore"),
        // The AppKit compositor (SnoopySceneView) and the weather settings panel,
        // shared by the .saver bundle (compiled in by the Xcode project) and the
        // desktop-wallpaper app.
        .target(name: "SnoopySceneKit", dependencies: ["SnoopyTVCore"]),
        .executableTarget(name: "SnoopySequenceProxyBuilder", dependencies: ["SnoopyTVCore"]),
        // Menu-bar app that hosts SnoopySceneView on every screen at desktop level.
        .executableTarget(name: "SnoopyWallpaper", dependencies: ["SnoopySceneKit", "SnoopyTVCore"]),
        .testTarget(name: "SnoopyTVCoreTests", dependencies: ["SnoopyTVCore"])
    ]
)
