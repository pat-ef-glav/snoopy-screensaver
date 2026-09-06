import AppKit
import SnoopySceneKit
import SnoopyTVCore

/// Menu-bar UI: a status item whose menu exposes the on/off toggle, playback
/// speed, on-battery behaviour, pause-when-covered, weather settings and
/// launch-at-login. All state lives in `SnoopyPreferences` (shared with the
/// screensaver) and is applied by `WallpaperController`.
@MainActor
final class WallpaperAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = WallpaperController()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private lazy var weatherController = SnoopyConfigurationController()

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "dog.fill", accessibilityDescription: "Snoopy Wallpaper")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Snoopy Wallpaper"
        }
        menu.delegate = self
        item.menu = menu
        statusItem = item
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let status = NSMenuItem(title: controller.statusDescription, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Show Snoopy on the Desktop", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = SnoopyPreferences.wallpaperEnabled ? .on : .off
        menu.addItem(toggle)

        let speed = NSMenuItem(title: "Playback Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for rate in Self.speeds {
            let item = NSMenuItem(title: Self.title(forRate: rate), action: #selector(selectSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rate
            item.state = abs(SnoopyPreferences.playbackRate - rate) < 0.001 ? .on : .off
            speedMenu.addItem(item)
        }
        speed.submenu = speedMenu
        menu.addItem(speed)

        let battery = NSMenuItem(title: "On Battery", action: nil, keyEquivalent: "")
        let batteryMenu = NSMenu()
        for mode in SnoopyOnBatteryMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectBatteryMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = SnoopyPreferences.onBatteryMode == mode ? .on : .off
            batteryMenu.addItem(item)
        }
        battery.submenu = batteryMenu
        battery.isEnabled = PowerMonitor.hasBattery
        menu.addItem(battery)

        let hidden = NSMenuItem(title: "Pause When Covered by Windows", action: #selector(togglePauseWhenHidden(_:)), keyEquivalent: "")
        hidden.target = self
        hidden.state = SnoopyPreferences.pauseWhenHidden ? .on : .off
        menu.addItem(hidden)
        menu.addItem(.separator())

        let weather = NSMenuItem(title: "Weather Settings…", action: #selector(showWeatherSettings(_:)), keyEquivalent: "")
        weather.target = self
        menu.addItem(weather)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.isEnabled = LaunchAtLogin.isAvailable
        login.state = LaunchAtLogin.isAvailable && LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Snoopy Wallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private static func title(forRate rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: Any?) {
        controller.setEnabled(!SnoopyPreferences.wallpaperEnabled)
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double else { return }
        controller.setPlaybackRate(rate)
    }

    @objc private func selectBatteryMode(_ sender: NSMenuItem) {
        guard let mode = SnoopyOnBatteryMode(rawValue: sender.tag) else { return }
        controller.setOnBatteryMode(mode)
    }

    @objc private func togglePauseWhenHidden(_ sender: Any?) {
        controller.setPauseWhenHidden(!SnoopyPreferences.pauseWhenHidden)
    }

    @objc private func showWeatherSettings(_ sender: Any?) {
        let window = weatherController.window
        (window as? NSPanel)?.hidesOnDeactivate = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
