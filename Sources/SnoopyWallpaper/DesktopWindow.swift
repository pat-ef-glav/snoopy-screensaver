import AppKit
import SnoopySceneKit
import SnoopyTVCore

/// A borderless, click-through window at desktop level that fills one screen
/// and hosts a `SnoopySceneView`. Same recipe as Aerial's desktop mode: it
/// joins every Space, never becomes key, ignores the mouse, and sits below the
/// desktop icons.
final class DesktopWindow: NSWindow {
    enum PlaybackState { case stopped, playing, paused }

    let scene: SnoopySceneView
    let displayID: CGDirectDisplayID
    private(set) var state: PlaybackState = .stopped

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

    /// Show the window and play: continue a paused session, or start a new one.
    func play() {
        switch state {
        case .playing:
            return
        case .paused:
            state = .playing
            applyPlaybackRate()
            scene.resume()
            scene.startClock()
        case .stopped:
            state = .playing
            applyPlaybackRate()
            scene.start()
            scene.startClock()
            orderFrontRegardless()
        }
    }

    /// Freeze on the current frame. The window stays where it is, so the
    /// desktop keeps showing Snoopy instead of the system wallpaper.
    func pause() {
        guard state == .playing else { return }
        state = .paused
        scene.stopClock()
        scene.pause()
    }

    /// Stop playback and hide the window so the system wallpaper shows through.
    func hide() {
        guard state != .stopped else { return }
        state = .stopped
        scene.stopClock()
        scene.stop()
        orderOut(nil)
    }

    func applyPlaybackRate() {
        scene.playbackRate = SnoopyPreferences.playbackRate(for: .wallpaper)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
