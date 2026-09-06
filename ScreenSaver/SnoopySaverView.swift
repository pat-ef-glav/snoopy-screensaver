import Cocoa
import ScreenSaver

// The compositor (`SnoopySceneView`) and the weather settings panel live in
// Sources/SnoopySceneKit. The Xcode project compiles them into this bundle;
// the Swift package exposes them to other hosts (Sources/SnoopyWallpaper).

/// Thin `.saver` host: forwards the ScreenSaver lifecycle to a `SnoopySceneView`.
/// The principal class name (Info.plist `NSPrincipalClass`) is unchanged.
@objc(DingDangSnoopySaverView)
final class SnoopySaverView: ScreenSaverView {
    private let scene: SnoopySceneView
    private lazy var configurationController = SnoopyConfigurationController()

    @objc(initWithFrame:isPreview:)
    override init?(frame: NSRect, isPreview: Bool) {
        scene = SnoopySceneView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame, isPreview: isPreview)
        embedScene()
    }

    required init?(coder: NSCoder) {
        scene = SnoopySceneView(frame: .zero)
        super.init(coder: coder)
        embedScene()
    }

    private func embedScene() {
        animationTimeInterval = 1.0 / 30.0
        scene.frame = bounds
        scene.autoresizingMask = [.width, .height]
        addSubview(scene)
    }

    override func startAnimation() {
        // Set in the Options sheet or the Snoopy Wallpaper menu; 1 = authored speed.
        scene.playbackRate = SnoopyPreferences.playbackRate(for: .screenSaver)
        super.startAnimation()
        scene.start()
    }

    override func stopAnimation() {
        scene.stop()
        super.stopAnimation()
    }

    override func animateOneFrame() {
        scene.tick()
    }

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? { configurationController.window }
}
