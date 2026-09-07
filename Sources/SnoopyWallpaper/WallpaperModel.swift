import AppKit
import Combine
import ImageIO
import SnoopySceneKit
import SnoopyTVCore

/// Observable state behind the status panel. Reads `SnoopyPreferences` and the
/// controller, applies changes through the controller, and loads scene
/// thumbnails off the main thread.
@MainActor
final class WallpaperModel: ObservableObject {
    struct SceneChoice: Identifiable {
        let id: String
        let chance: Double
        var thumbnail: NSImage?
    }

    @Published private(set) var status = "Starting…"
    @Published private(set) var isEnabled = SnoopyPreferences.wallpaperEnabled
    @Published private(set) var wallpaperRate = SnoopyPreferences.playbackRate(for: .wallpaper)
    @Published private(set) var saverRate = SnoopyPreferences.playbackRate(for: .screenSaver)
    @Published private(set) var onBatteryMode = SnoopyPreferences.onBatteryMode
    @Published private(set) var pauseWhenHidden = SnoopyPreferences.pauseWhenHidden
    @Published private(set) var launchAtLogin = false
    @Published private(set) var weatherText = ""
    @Published private(set) var currentSceneID: String?
    @Published private(set) var currentThumbnail: NSImage?
    @Published private(set) var upcoming: [SceneChoice] = []
    @Published private(set) var canGoBack = false
    /// The panel's reaction buttons, in `ReactionTrigger.all` order; empty
    /// when the loaded index has no reaction clips.
    @Published private(set) var reactionTriggers: [String] = []
    @Published private(set) var pendingReactionTrigger: String?

    let hasBattery = PowerMonitor.hasBattery
    let launchAtLoginAvailable = LaunchAtLogin.isAvailable
    let version: String = {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "dev"
    }()

    private let controller: WallpaperController
    private lazy var weatherController = SnoopyConfigurationController()
    private var thumbnails: [String: NSImage] = [:]
    private var loading: Set<String> = []

    init(controller: WallpaperController) {
        self.controller = controller
    }

    // MARK: - Reading state

    func refresh() {
        status = controller.statusDescription
        isEnabled = SnoopyPreferences.wallpaperEnabled
        wallpaperRate = SnoopyPreferences.playbackRate(for: .wallpaper)
        saverRate = SnoopyPreferences.playbackRate(for: .screenSaver)
        onBatteryMode = SnoopyPreferences.onBatteryMode
        pauseWhenHidden = SnoopyPreferences.pauseWhenHidden
        launchAtLogin = launchAtLoginAvailable && LaunchAtLogin.isEnabled
        weatherText = Self.describeWeather()
        reactionTriggers = Self.panelReactionTriggers(controller.availableReactionTriggers)
        pendingReactionTrigger = controller.pendingReactionTrigger
        refreshScenes()
    }

    /// The named triggers the index can answer, in `ReactionTrigger.all`
    /// order. `generic` is a fallback tag on the holds, not a trigger to fire,
    /// and a token the panel has no title for is left out.
    private static func panelReactionTriggers(_ available: [String]) -> [String] {
        let available = Set(available)
        return ReactionTrigger.all.filter { $0 != ReactionTrigger.generic && available.contains($0) }
    }

    private func refreshScenes() {
        guard let scene = controller.primaryScene else {
            currentSceneID = nil
            currentThumbnail = nil
            upcoming = []
            canGoBack = false
            return
        }
        canGoBack = scene.canSkipToPreviousScene
        currentSceneID = scene.currentIdleSceneID
        if let id = scene.currentIdleSceneID {
            if let url = scene.thumbnailURL(forIdleScene: id) { loadThumbnail(id: id, url: url) }
            currentThumbnail = thumbnails[id]
        } else {
            currentThumbnail = nil
        }
        let candidates = scene.upcomingSceneCandidates(limit: 3)
        for candidate in candidates {
            if let url = candidate.thumbnailURL { loadThumbnail(id: candidate.id, url: url) }
        }
        upcoming = candidates.map { SceneChoice(id: $0.id, chance: $0.chance, thumbnail: thumbnails[$0.id]) }
    }

    private func loadThumbnail(id: String, url: URL) {
        guard thumbnails[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        Task.detached(priority: .utility) { [weak self] in
            var image: NSImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 560,
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(id)
                if let image { self.thumbnails[id] = image }
                self.applyThumbnails()
            }
        }
    }

    private func applyThumbnails() {
        if let id = currentSceneID { currentThumbnail = thumbnails[id] }
        upcoming = upcoming.map { choice in
            var updated = choice
            updated.thumbnail = thumbnails[choice.id]
            return updated
        }
    }

    private static func describeWeather() -> String {
        guard SnoopyPreferences.weatherEnabled else { return "Weather linking is off" }
        guard let snapshot = SnoopyPreferences.weatherSnapshot(), snapshot.isUsable else {
            return "No weather cached yet"
        }
        let time = DateFormatter.localizedString(from: snapshot.observedAt, dateStyle: .none, timeStyle: .short)
        let place = snapshot.locationName
            ?? SnoopyPreferences.defaults.string(forKey: SnoopyPreferences.cityNameKey) ?? "Weather"
        return "\(place) · \(snapshot.conditions.joined(separator: ", ")) · \(time)"
    }

    // MARK: - Actions

    func setEnabled(_ enabled: Bool) {
        controller.setEnabled(enabled)
        refresh()
    }

    func setWallpaperRate(_ rate: Double) {
        controller.setPlaybackRate(rate, for: .wallpaper)
        wallpaperRate = SnoopyPreferences.playbackRate(for: .wallpaper)
    }

    func setSaverRate(_ rate: Double) {
        controller.setPlaybackRate(rate, for: .screenSaver)
        saverRate = SnoopyPreferences.playbackRate(for: .screenSaver)
    }

    func setOnBatteryMode(_ mode: SnoopyOnBatteryMode) {
        controller.setOnBatteryMode(mode)
        refresh()
    }

    func setPauseWhenHidden(_ pause: Bool) {
        controller.setPauseWhenHidden(pause)
        refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            NSAlert(error: error).runModal()
        }
        launchAtLogin = launchAtLoginAvailable && LaunchAtLogin.isEnabled
    }

    func nextScene() {
        controller.nextScene()
        refresh()
    }

    func previousScene() {
        controller.previousScene()
        refresh()
    }

    func react(_ trigger: String) {
        controller.react(trigger)
        refresh()
    }

    func restart() {
        controller.restart()
        refresh()
    }

    func showWeatherSettings() {
        let window = weatherController.window
        (window as? NSPanel)?.hidesOnDeactivate = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
