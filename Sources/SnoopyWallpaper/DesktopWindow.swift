import AppKit
import SnoopySceneKit
import SnoopyTVCore

/// A borderless, click-through window at desktop level that fills one screen
/// and hosts a `SnoopySceneView`. Same recipe as Aerial's desktop mode: it
/// joins every Space, never becomes key, ignores the mouse, and sits below the
/// desktop icons.
final class DesktopWindow: NSWindow {
    let scene: SnoopySceneView
    let displayID: CGDirectDisplayID
    private(set) var isPlaying = false

    /// Offset from `CGWindowLevelForKey(.desktopWindow)`. 0 places the window at
    /// desktop level, above the system wallpaper and below the desktop icons
    /// (the icons live 20 levels up). Overridable for experiments with
    /// `defaults write com.dingdangnao.snoopy.shared SnoopyWallpaperLevelOffset -int N`.
    static var levelOffset: Int {
        let defaults = SnoopyPreferences.defaults
        return defaults.object(forKey: "SnoopyWallpaperLevelOffset") == nil
            ? 0 : defaults.integer(forKey: "SnoopyWallpaperLevelOffset")
    }

    init(screen: NSScreen) {
        scene = SnoopySceneView(frame: NSRect(origin: .zero, size: screen.frame.size))
        displayID = screen.displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + Self.levelOffset)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = false
        canHide = false
        isOpaque = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        backgroundColor = .black

        // Suppress implicit Core Animation actions on the wallpaper layer so a
        // re-order (e.g. after the screensaver dismisses) never fades or slides.
        scene.wantsLayer = true
        let nullAction = NSNull()
        scene.layer?.actions = [
            "contents": nullAction, "opacity": nullAction, "position": nullAction,
            "bounds": nullAction, "transform": nullAction, "hidden": nullAction,
            "onOrderIn": nullAction, "onOrderOut": nullAction, "sublayers": nullAction,
        ]
        contentView = scene
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Start (or restart) playback and show the window.
    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        scene.playbackRate = SnoopyPreferences.playbackRate
        scene.start()
        scene.startClock()
        orderFrontRegardless()
    }

    /// Stop playback and hide the window so the system wallpaper shows through.
    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        scene.stopClock()
        scene.stop()
        orderOut(nil)
    }

    func applyPlaybackRate() {
        scene.playbackRate = SnoopyPreferences.playbackRate
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
