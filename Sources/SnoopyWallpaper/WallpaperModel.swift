import AppKit
import Combine
import ImageIO
import SnoopySceneKit
import SnoopyTVCore

/// Observable state behind the status panel. Reads `SnoopyPreferences` and the
/// controller, applies changes through the controller, and keeps the scene
/// preview (a live frame of the main display, or the room's first background
/// frame until one has been rendered) and the "Now / Then" lines current.
/// It refreshes every 2 s, but only while the panel's window is on screen
/// (`setPanelVisible`); a closed panel costs nothing.
@MainActor
final class WallpaperModel: ObservableObject {
    private typealias PlaybackStatus = SnoopySceneView.PlaybackStatus

    @Published private(set) var status = "Starting…"
    @Published private(set) var isEnabled = SnoopyPreferences.wallpaperEnabled
    @Published private(set) var wallpaperRate = SnoopyPreferences.playbackRate(for: .wallpaper)
    @Published private(set) var saverRate = SnoopyPreferences.playbackRate(for: .screenSaver)
    @Published private(set) var onBatteryMode = SnoopyPreferences.onBatteryMode
    @Published private(set) var pauseWhenHidden = SnoopyPreferences.pauseWhenHidden
    @Published private(set) var launchAtLogin = false
    @Published private(set) var weatherText = ""
    @Published private(set) var weatherEnabled = SnoopyPreferences.weatherEnabled
    /// A live frame of the main display's wallpaper, or the current room's
    /// first background frame until the first live frame has arrived.
    @Published private(set) var previewImage: NSImage?
    /// The room on screen ("Scene 33 · bundle 104") or the id of the
    /// full-screen video; nil when nothing is known.
    @Published private(set) var sceneCaption: String?
    /// What plays now ("Pose AP007 · 12 s left") and what follows inside the
    /// current composite ("Bridge BP001→BP002"); "—" when unknown.
    @Published private(set) var nowLabel = "—"
    @Published private(set) var thenLabel = "—"
    @Published private(set) var canGoBack = false

    let hasBattery = PowerMonitor.hasBattery
    let launchAtLoginAvailable = LaunchAtLogin.isAvailable

    private let controller: WallpaperController
    private lazy var weatherController = SnoopyConfigurationController()
    private var currentSceneID: String?
    private var thumbnails: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var liveFrame: NSImage?
    private var previewRequestInFlight = false
    private(set) var panelVisible = false
    private var panelClock: Timer?

    init(controller: WallpaperController) {
        self.controller = controller
    }

    // MARK: - Panel visibility

    /// The panel reports whether its window is on screen. The 2 s refresh
    /// clock — and with it the live-frame rendering, the only costly part of
    /// a refresh — runs only while it is. `MenuBarExtra` in its window style
    /// keeps the panel's views alive between openings, so a timer owned by
    /// the SwiftUI view would keep decoding frames after the panel closed.
    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        panelClock?.invalidate()
        panelClock = nil
        guard visible else {
            // The next opening starts from the room thumbnail until a fresh
            // frame arrives rather than from a picture that may be hours old.
            liveFrame = nil
            applyPreview()
            return
        }
        refresh()
        let clock = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Common modes, so the clock keeps ticking while a pop-up menu tracks.
        RunLoop.main.add(clock, forMode: .common)
        panelClock = clock
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
        weatherEnabled = SnoopyPreferences.weatherEnabled
        weatherText = Self.describeWeather()
        refreshScene()
    }

    private func refreshScene() {
        guard let scene = controller.primaryScene else {
            currentSceneID = nil
            liveFrame = nil
            canGoBack = false
            sceneCaption = nil
            nowLabel = "—"
            thenLabel = "—"
            applyPreview()
            return
        }
        canGoBack = scene.canSkipToPreviousScene
        currentSceneID = scene.currentIdleSceneID
        if let id = currentSceneID, let url = scene.thumbnailURL(forIdleScene: id) {
            loadThumbnail(id: id, url: url)
        }
        let playback = scene.playbackStatus
        sceneCaption = Self.caption(for: playback, roomID: currentSceneID)
        let labels = Self.labels(for: playback, playbackRate: scene.playbackRate)
        nowLabel = labels.now
        thenLabel = labels.then
        applyPreview()
        requestLiveFrame(from: scene)
    }

    /// Ask the scene for a picture of what is on screen — only while the
    /// panel can show it. One request at a time; the engine renders off the
    /// main thread and never touches playback. A nil result (nothing sensible
    /// on screen) falls back to the room thumbnail.
    private func requestLiveFrame(from scene: SnoopySceneView) {
        guard panelVisible, !previewRequestInFlight else { return }
        previewRequestInFlight = true
        scene.makePreviewImage(maxPixelSize: 640) { [weak self] cgImage in
            guard let self else { return }
            self.previewRequestInFlight = false
            guard self.panelVisible else { return }
            self.liveFrame = cgImage.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            self.applyPreview()
        }
    }

    private func applyPreview() {
        previewImage = liveFrame ?? currentSceneID.flatMap { thumbnails[$0] }
    }

    private func loadThumbnail(id: String, url: URL) {
        guard thumbnails[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        Task.detached(priority: .utility) { [weak self] in
            let image: NSImage? = {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(id)
                if let image { self.thumbnails[id] = image }
                self.applyPreview()
            }
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

    // MARK: - Playback labels

    /// What the preview shows: the room, or the full-screen video named the
    /// way the Now line names it ("Video AS014").
    private static func caption(for playback: PlaybackStatus, roomID: String?) -> String? {
        switch playback.mode {
        case .idle(let sceneID): return sceneTitle(sceneID)
        case .activeScene(let id): return label(kind: "activeScene", id: id)
        case .transition, .none: return roomID.map(sceneTitle)
        }
    }

    /// The "Now" and "Then" lines. In a room the current segment of the
    /// seamless character item and the one after it; a full-screen video or a
    /// hide/reveal transition has no known successor. The time left is wall
    /// time (media seconds divided by the playback rate) until the Now item
    /// ends, shown when the engine knows the duration.
    private static func labels(for playback: PlaybackStatus, playbackRate: Double) -> (now: String, then: String) {
        var now: String
        var then = "—"
        var remaining: TimeInterval?
        switch playback.mode {
        case .idle:
            guard !playback.segments.isEmpty else { return ("—", "—") }
            let index = min(max(playback.currentSegmentIndex ?? 0, 0), playback.segments.count - 1)
            let segment = playback.segments[index]
            now = label(kind: segment.kind, id: segment.assetID)
            if index + 1 < playback.segments.count {
                let next = playback.segments[index + 1]
                then = label(kind: next.kind, id: next.assetID)
            }
            if playback.duration > 0 { remaining = segment.end - playback.elapsed }
        case .activeScene(let id):
            now = label(kind: "activeScene", id: id)
            if playback.duration > 0 { remaining = playback.duration - playback.elapsed }
        case .transition(let pairID, let stage):
            now = "Transition \(transitionName(pairID)) \(stage)"
            if playback.duration > 0 { remaining = playback.duration - playback.elapsed }
        case .none:
            return ("—", "—")
        }
        if let remaining, remaining > 0 {
            let rate = playbackRate > 0 ? playbackRate : 1
            now += " · \(Int((remaining / rate).rounded(.up))) s left"
        }
        return (now, then)
    }

    /// A short name for one asset of the composite, from its kind and id:
    /// "Resting BP002", "Pose AP007", "Moment CM001", "Bridge BP001→BP002",
    /// "Enter RPH" / "Exit RPH", "Reaction RPD001", "Hold RPH", "Video AS002".
    static func label(kind: String, id: String) -> String {
        let code = assetCode(id)
        switch kind {
        case "characterBasePose": return "Resting \(code)"
        case "characterAdditionalPose": return "Pose \(code)"
        case "characterMoment": return "Moment \(momentCode(code))"
        case "characterPoseTransition", "characterReactionTransitionPose": return transitionLabel(code) ?? code
        case "characterReactionPose": return reactionLabel(code)
        case "hold": return reactionLabel(strippingRepeatSuffix(code))
        case "activeScene": return "Video \(code)"
        default: return inferredLabel(code)
        }
    }

    /// "104_IS033" → "Scene 33 · bundle 104"; other ids stay as they are.
    static func sceneTitle(_ id: String) -> String {
        let parts = id.split(separator: "_")
        if parts.count == 2, parts[1].hasPrefix("IS"), let number = Int(parts[1].dropFirst(2)) {
            return "Scene \(number) · bundle \(parts[0])"
        }
        return id
    }

    /// "SceneTransitionPair_ClockWipeExcludeLateNight" → "ClockWipe".
    static func transitionName(_ pairID: String) -> String {
        var name = pairID
        if let range = name.range(of: "SceneTransitionPair_"), range.lowerBound == name.startIndex {
            name.removeSubrange(range)
        }
        if let range = name.range(of: "Exclude"), range.lowerBound > name.startIndex {
            name = String(name[..<range.lowerBound])
        }
        return name
    }

    /// "101_AP007" → "AP007": the bundle prefix is dropped.
    private static func assetCode(_ id: String) -> String {
        let digits = id.prefix { $0.isNumber }
        guard !digits.isEmpty, id.dropFirst(digits.count).hasPrefix("_") else { return id }
        return String(id.dropFirst(digits.count + 1))
    }

    /// "CM001_From_BP001_To_BP003" → "CM001".
    private static func momentCode(_ code: String) -> String {
        String(code.prefix { $0 != "_" })
    }

    /// "RPH_Loopx6" → "RPH_Loop" (a repeated hold tail is "<holdID>x<repeats>").
    private static func strippingRepeatSuffix(_ code: String) -> String {
        guard let marker = code.lastIndex(of: "x") else { return code }
        let repeats = code[code.index(after: marker)...]
        guard !repeats.isEmpty, repeats.allSatisfy(\.isNumber) else { return code }
        return String(code[..<marker])
    }

    private static func isReactionCode(_ code: String) -> Bool {
        code.hasPrefix("RP") || code.hasPrefix("RW")
    }

    /// "RPD001" → "Reaction RPD001"; "RPH_Loop" → "Hold RPH".
    private static func reactionLabel(_ code: String) -> String {
        code.hasSuffix("_Loop") ? "Hold \(code.dropLast("_Loop".count))" : "Reaction \(code)"
    }

    /// "BP001_To_BP002" → "Bridge BP001→BP002"; "AP021_To_RWH" → "Enter RWH";
    /// "RPH_To_BP001" → "Exit RPH"; nil when the code is not a transition.
    private static func transitionLabel(_ code: String) -> String? {
        let parts = code.components(separatedBy: "_To_")
        guard parts.count == 2 else { return nil }
        if isReactionCode(parts[1]) { return "Enter \(parts[1])" }
        if isReactionCode(parts[0]) { return "Exit \(parts[0])" }
        return "Bridge \(parts[0])→\(parts[1])"
    }

    /// For an asset the graph does not know: the same names, by id shape. A
    /// moment id ("CM001_From_BP001_To_BP003") contains "_To_" as well, so it
    /// is recognised before the transition shape.
    private static func inferredLabel(_ code: String) -> String {
        if code.hasPrefix("CM") { return "Moment \(momentCode(code))" }
        if let transition = transitionLabel(code) { return transition }
        if code.hasPrefix("BP") { return "Resting \(code)" }
        if code.hasPrefix("AP") { return "Pose \(code)" }
        if code.hasPrefix("AS") { return "Video \(code)" }
        if isReactionCode(code) { return reactionLabel(strippingRepeatSuffix(code)) }
        return code
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

    func restart() {
        controller.restart()
        refresh()
    }

    func refreshWeather() {
        controller.refreshWeather()
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
