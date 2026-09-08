import AppKit
import SwiftUI
#if canImport(SnoopyTVCore)
import SnoopyTVCore // Swift package build; the Xcode target compiles the core sources directly
#endif

public enum SnoopySettingsTab: String, CaseIterable, Identifiable, Sendable {
    case weather
    case playback
    case reactions

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: return "Weather"
        case .playback: return "Playback"
        case .reactions: return "Reactions"
        }
    }

    var symbol: String {
        switch self {
        case .weather: return "cloud.sun"
        case .playback: return "play.rectangle"
        case .reactions: return "bell"
        }
    }
}

/// One real-world source behind a reaction trigger, as shown in settings.
struct SnoopyReactionSourceInfo: Identifiable {
    let trigger: String
    let title: String
    let detail: String
    var id: String { trigger }

    static let all: [SnoopyReactionSourceInfo] = [
        .init(trigger: ReactionTrigger.music, title: "Music",
              detail: "When another app has been playing audio for a few seconds."),
        .init(trigger: ReactionTrigger.presence, title: "Presence",
              detail: "When you unlock the Mac or it wakes from sleep."),
        .init(trigger: ReactionTrigger.environment, title: "Environment",
              detail: "When the weather changes, including sunrise and sunset."),
        .init(trigger: ReactionTrigger.alarm, title: "Alarm",
              detail: "When a calendar event starts. Asks for calendar access."),
        .init(trigger: ReactionTrigger.doorbell, title: "Doorbell",
              detail: "When a download finishes. Asks for access to your Downloads folder."),
    ]
}

/// State behind the settings window. Every control writes to
/// `SnoopyPreferences` as it changes; the city is resolved and the weather
/// fetched on Update Now, on Return in the field, and on Done when the city
/// changed.
@MainActor
final class SnoopySettingsModel: ObservableObject {
    @Published var tab: SnoopySettingsTab = .weather
    @Published var weatherEnabled = SnoopyPreferences.weatherEnabled {
        didSet {
            guard !loading else { return }
            SnoopyPreferences.weatherEnabled = weatherEnabled
            refreshStatus()
        }
    }
    @Published var city = ""
    @Published var weatherStatus = ""
    @Published var weatherError: String?
    @Published var isUpdatingWeather = false
    @Published var wallpaperRate = SnoopyPreferences.playbackRate(for: .wallpaper) {
        didSet { if !loading { SnoopyPreferences.setPlaybackRate(wallpaperRate, for: .wallpaper) } }
    }
    @Published var saverRate = SnoopyPreferences.playbackRate(for: .screenSaver) {
        didSet { if !loading { SnoopyPreferences.setPlaybackRate(saverRate, for: .screenSaver) } }
    }
    @Published var onBatteryMode = SnoopyPreferences.onBatteryMode {
        didSet { if !loading { SnoopyPreferences.onBatteryMode = onBatteryMode } }
    }
    @Published var pauseWhenHidden = SnoopyPreferences.pauseWhenHidden {
        didSet { if !loading { SnoopyPreferences.pauseWhenHidden = pauseWhenHidden } }
    }
    @Published var pauseCoverage = SnoopyPreferences.pauseCoverageThreshold {
        didSet { if !loading { SnoopyPreferences.pauseCoverageThreshold = pauseCoverage } }
    }

    @Published var reactionSources: [String: Bool] = [:]

    var onDone: (() -> Void)?
    private var loading = false

    func reactionSourceBinding(_ trigger: String) -> Binding<Bool> {
        Binding(
            get: { self.reactionSources[trigger] ?? SnoopyPreferences.reactionSourceEnabled(trigger) },
            set: { enabled in
                self.reactionSources[trigger] = enabled
                SnoopyPreferences.setReactionSourceEnabled(enabled, for: trigger)
            }
        )
    }

    private var savedCity: String {
        SnoopyPreferences.defaults.string(forKey: SnoopyPreferences.cityNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var cityChanged: Bool {
        city.trimmingCharacters(in: .whitespacesAndNewlines) != savedCity
    }

    func reload() {
        loading = true
        defer { loading = false }
        weatherEnabled = SnoopyPreferences.weatherEnabled
        city = savedCity
        weatherError = nil
        wallpaperRate = SnoopyPreferences.playbackRate(for: .wallpaper)
        saverRate = SnoopyPreferences.playbackRate(for: .screenSaver)
        onBatteryMode = SnoopyPreferences.onBatteryMode
        pauseWhenHidden = SnoopyPreferences.pauseWhenHidden
        pauseCoverage = SnoopyPreferences.pauseCoverageThreshold
        reactionSources = Dictionary(uniqueKeysWithValues: SnoopyReactionSourceInfo.all.map {
            ($0.trigger, SnoopyPreferences.reactionSourceEnabled($0.trigger))
        })
        refreshStatus()
    }

    func refreshStatus() {
        if !weatherEnabled {
            weatherStatus = "Weather linking is off."
        } else if let snapshot = SnoopyPreferences.weatherSnapshot(), snapshot.isUsable {
            weatherStatus = snapshot.summary()
        } else {
            weatherStatus = "No weather yet."
        }
    }

    /// Resolve the city (when it changed or no location is saved) and fetch.
    @discardableResult
    func updateWeather() async -> Bool {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            weatherError = SnoopyWeatherError.invalidCity.localizedDescription
            return false
        }
        isUpdatingWeather = true
        weatherError = nil
        weatherStatus = "Updating…"
        defer { isUpdatingWeather = false }
        do {
            let client = SnoopyWeatherClient()
            let location: SnoopyWeatherLocation
            if !cityChanged, let saved = SnoopyPreferences.weatherLocation() {
                location = saved
            } else {
                location = try await client.resolve(city: trimmed)
                SnoopyPreferences.save(weatherLocation: location)
            }
            let snapshot = try await client.fetch(location: location)
            SnoopyPreferences.save(weatherSnapshot: snapshot)
            SnoopyPreferences.weatherEnabled = true
            city = savedCity
            refreshStatus()
            return true
        } catch {
            weatherError = error.localizedDescription
            refreshStatus()
            return false
        }
    }

    func done() {
        Task { @MainActor in
            if weatherEnabled, cityChanged {
                guard await updateWeather() else { return }
            }
            onDone?()
        }
    }
}

struct SnoopySettingsView: View {
    @ObservedObject var model: SnoopySettingsModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(SnoopySettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, 14)
            .padding(.horizontal, 60)
            Group {
                switch model.tab {
                case .weather: weatherForm
                case .playback: playbackForm
                case .reactions: reactionsForm
                }
            }
            .frame(height: 330)
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.done() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isUpdatingWeather)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var weatherForm: some View {
        Form {
            Section {
                Toggle("Match scenes and animations to the local weather", isOn: $model.weatherEnabled)
                TextField("City", text: $model.city, prompt: Text("London, New York, Tokyo…"))
                    .disabled(!model.weatherEnabled)
                    .onSubmit { Task { await model.updateWeather() } }
                LabeledContent("Status") {
                    HStack(spacing: 10) {
                        Text(model.weatherStatus)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                        if model.isUpdatingWeather {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Update Now") { Task { await model.updateWeather() } }
                                .disabled(!model.weatherEnabled)
                        }
                    }
                }
                if let error = model.weatherError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } footer: {
                Text("Type a city; no location permission is asked for. The weather comes from Open-Meteo (free, no key), is cached for about an hour and re-checked on its own, including after the network was down. It only weights which scenes are chosen; playback never waits for it.")
            }
        }
        .formStyle(.grouped)
    }

    private var playbackForm: some View {
        Form {
            Section("Speed") {
                ratePicker("Wallpaper", selection: $model.wallpaperRate)
                ratePicker("Screen saver", selection: $model.saverRate)
            }
            Section {
                Picker("On battery", selection: $model.onBatteryMode) {
                    ForEach(SnoopyOnBatteryMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Pause when covered by windows", isOn: $model.pauseWhenHidden)
                if model.pauseWhenHidden {
                    LabeledContent("Pause when covered by at least") {
                        HStack(spacing: 10) {
                            Slider(value: $model.pauseCoverage, in: 0.3...0.95, step: 0.05)
                                .frame(width: 160)
                            Text("\(Int((model.pauseCoverage * 100).rounded())) %")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Power")
            } footer: {
                Text("Coverage is measured once a second on a 50 × 50 grid of each display; only other apps' ordinary windows count. Paused, the wallpaper keeps its current frame on screen.")
            }
        }
        .formStyle(.grouped)
    }

    private var reactionsForm: some View {
        Form {
            Section {
                ForEach(SnoopyReactionSourceInfo.all) { source in
                    Toggle(isOn: model.reactionSourceBinding(source.trigger)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                            Text(source.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Snoopy reacts to")
            } footer: {
                Text("A reaction plays at Snoopy's next pause in a scene, within about a minute and a half of the event, and each kind at most once every three minutes. When Woodstock is with him, the two react together. These are the Apple TV reactions: a doorbell, an alarm, music, the environment and someone arriving.")
            }
        }
        .formStyle(.grouped)
    }

    private func ratePicker(_ title: String, selection: Binding<Double>) -> some View {
        let value = selection.wrappedValue
        var choices = SnoopyPreferences.playbackRateChoices
        if !choices.contains(where: { abs($0 - value) < 0.001 }) { choices = (choices + [value]).sorted() }
        return Picker(title, selection: selection) {
            ForEach(choices, id: \.self) { rate in
                Text(SnoopyPreferences.playbackRateTitle(rate)).tag(rate)
            }
        }
    }
}

/// The settings window: the screen saver's Options sheet, and the window the
/// Snoopy Wallpaper menu opens. Everything is stored in the shared
/// `SnoopyPreferences` suite as it changes.
@MainActor
public final class SnoopyConfigurationController: NSObject {
    private let panel: NSPanel
    private let model = SnoopySettingsModel()

    public override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        super.init()
        panel.title = "Snoopy Settings"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: SnoopySettingsView(model: model))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        model.onDone = { [weak self] in self?.finish() }
    }

    /// The window, with every control reloaded from the preferences.
    public var window: NSWindow {
        model.reload()
        return panel
    }

    /// Open the window on `tab` (the wallpaper app's entry point).
    public func show(tab: SnoopySettingsTab) {
        model.reload()
        model.tab = tab
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        if let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: .OK)
        } else {
            panel.orderOut(nil)
        }
    }
}
