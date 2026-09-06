import AppKit
import SnoopySceneKit
import SnoopyTVCore

/// Owns one `DesktopWindow` per screen and decides when each one plays. The
/// policy combines the user's on/off toggle with power state, window coverage,
/// display sleep and the system screensaver — the same inputs Aerial's desktop
/// mode reacts to. Everything runs on the main thread.
@MainActor
final class WallpaperController: NSObject {
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var occlusionMonitors: [CGDirectDisplayID: OcclusionMonitor] = [:]
    private let power = PowerMonitor()
    private var screensAsleep = false
    private var screensaverActive = false
    private var didStart = false

    /// One-line summary for the status menu.
    var statusDescription: String {
        guard SnoopyPreferences.wallpaperEnabled else { return "Off" }
        if let reason = globalPauseReason { return "Paused: \(reason)" }
        let playing = windows.values.filter { $0.state == .playing }.count
        let total = windows.count
        if total == 0 { return "No displays" }
        if playing == total { return total == 1 ? "Playing" : "Playing on \(total) displays" }
        if playing == 0 { return "Paused: covered by windows" }
        return "Playing on \(playing) of \(total) displays"
    }

    // MARK: - Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true
        power.start()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(powerDidChange(_:)),
                           name: PowerMonitor.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(occlusionDidChange(_:)),
                           name: OcclusionMonitor.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidChange(_:)),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep(_:)),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake(_:)),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)

        // The screensaver covers the desktop; playing underneath it is wasted work.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screensaverWillStart(_:)),
                                name: Notification.Name("com.apple.screensaver.willstart"), object: nil)
        distributed.addObserver(self, selector: #selector(screensaverDidStop(_:)),
                                name: Notification.Name("com.apple.screensaver.didstop"), object: nil)

        rebuildWindows()
    }

    func shutdown() {
        for window in windows.values { window.hide() }
        for monitor in occlusionMonitors.values { monitor.stop() }
        occlusionMonitors.removeAll()
        power.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Settings changes (called by the menu)

    /// The scene on the main display (previews and scene info come from it).
    var primaryScene: SnoopySceneView? {
        if let main = NSScreen.main, let window = windows[main.displayID] { return window.scene }
        return windows.values.first?.scene
    }

    func nextScene() {
        for window in windows.values where window.state != .stopped { window.scene.skipToNextScene() }
    }

    func previousScene() {
        for window in windows.values where window.state != .stopped { window.scene.skipToPreviousScene() }
    }

    /// Tear every session down and start fresh (menu action and recovery hatch).
    func restart() {
        for window in windows.values { window.hide() }
        applyPolicy()
    }

    func setEnabled(_ enabled: Bool) {
        SnoopyPreferences.wallpaperEnabled = enabled
        applyPolicy()
    }

    func setPlaybackRate(_ rate: Double, for host: SnoopyPlaybackHost) {
        SnoopyPreferences.setPlaybackRate(rate, for: host)
        if host == .wallpaper {
            for window in windows.values { window.applyPlaybackRate() }
        }
    }

    func setOnBatteryMode(_ mode: SnoopyOnBatteryMode) {
        SnoopyPreferences.onBatteryMode = mode
        applyPolicy()
    }

    func setPauseWhenHidden(_ pause: Bool) {
        SnoopyPreferences.pauseWhenHidden = pause
        applyPolicy()
    }

    // MARK: - Policy

    /// A reason that pauses every display, or nil.
    private var globalPauseReason: String? {
        if screensAsleep { return "displays asleep" }
        if screensaverActive { return "screensaver" }
        if PowerMonitor.hasBattery, PowerMonitor.isOnBattery {
            switch SnoopyPreferences.onBatteryMode {
            case .keepPlaying: break
            case .pause: return "on battery"
            case .pauseWhenLow: if PowerMonitor.isLowBattery { return "battery low" }
            }
        }
        return nil
    }

    private func shouldPlay(on displayID: CGDirectDisplayID) -> Bool {
        guard SnoopyPreferences.wallpaperEnabled, globalPauseReason == nil else { return false }
        if SnoopyPreferences.pauseWhenHidden, occlusionMonitors[displayID]?.isOccluded == true { return false }
        return true
    }

    private func applyPolicy() {
        let enabled = SnoopyPreferences.wallpaperEnabled
        for (displayID, window) in windows {
            let before = window.state
            if !enabled {
                window.hide()                       // off: the system wallpaper shows
            } else if shouldPlay(on: displayID) {
                window.play()                       // start, or continue a paused session
            } else if window.state == .playing {
                window.pause()                      // freeze on the current frame, stay visible
            }
            if window.state != before {
                // Let the window settle before trusting coverage again.
                occlusionMonitors[displayID]?.cooldown(seconds: 1.5)
            }
        }
        let wantOcclusionPolling = SnoopyPreferences.wallpaperEnabled && SnoopyPreferences.pauseWhenHidden
        for monitor in occlusionMonitors.values {
            if wantOcclusionPolling { monitor.start() } else { monitor.stop() }
        }
    }

    private func rebuildWindows() {
        let screens = NSScreen.screens
        let currentIDs = Set(screens.map(\.displayID))

        // Tear down windows whose display went away.
        for (displayID, window) in windows where !currentIDs.contains(displayID) {
            window.hide()
            window.close()
            windows[displayID] = nil
            occlusionMonitors[displayID]?.stop()
            occlusionMonitors[displayID] = nil
        }

        for screen in screens {
            let displayID = screen.displayID
            if let existing = windows[displayID] {
                // Same display, possibly a new geometry.
                if existing.frame != screen.frame {
                    existing.setFrame(screen.frame, display: true)
                    existing.scene.frame = NSRect(origin: .zero, size: screen.frame.size)
                }
                continue
            }
            windows[displayID] = DesktopWindow(screen: screen)
            occlusionMonitors[displayID] = OcclusionMonitor(displayID: displayID)
        }
        applyPolicy()
    }

    // MARK: - Notifications

    @objc private func powerDidChange(_ note: Notification) { applyPolicy() }
    @objc private func occlusionDidChange(_ note: Notification) { applyPolicy() }
    @objc private func screensDidChange(_ note: Notification) { rebuildWindows() }
    @objc private func screensDidSleep(_ note: Notification) { screensAsleep = true; applyPolicy() }
    @objc private func screensDidWake(_ note: Notification) { screensAsleep = false; applyPolicy() }
    @objc private func screensaverWillStart(_ note: Notification) { screensaverActive = true; applyPolicy() }
    @objc private func screensaverDidStop(_ note: Notification) { screensaverActive = false; applyPolicy() }
}
