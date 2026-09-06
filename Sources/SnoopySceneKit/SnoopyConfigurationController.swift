import AppKit
#if canImport(SnoopyTVCore)
import SnoopyTVCore // Swift package build; the Xcode target compiles the core sources directly
#endif

private final class SnoopyConfigurationBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The Options sheet of the screen saver, also opened from the Snoopy Wallpaper
/// menu: weather linking (city, Open-Meteo) and the screen saver's playback
/// speed. Everything is stored in the shared `SnoopyPreferences` suite.
@MainActor
public final class SnoopyConfigurationController: NSObject {
    private let panel: NSPanel
    private let enabledButton = NSButton(checkboxWithTitle: "Match scenes and animations to the local weather", target: nil, action: nil)
    private let cityField = NSTextField(string: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save & Update Weather", target: nil, action: nil)
    private let speedPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    public override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 390),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        super.init()
        buildInterface()
    }

    public var window: NSWindow {
        reload()
        return panel
    }

    private func buildInterface() {
        panel.title = "Snoopy Settings"
        // Let the host supply Aqua or Dark Aqua to the complete view tree.
        // A drawn semantic background stays in sync with the controls even in
        // legacy screen-saver hosts that override a sheet's appearance after
        // it has been created; a cached CGColor would not update here.
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = SnoopyConfigurationBackgroundView(frame: panel.contentView?.bounds ?? .zero)
        enabledButton.target = self
        enabledButton.action = #selector(toggleWeather(_:))
        cityField.placeholderString = "e.g. London, New York, Tokyo"

        let title = NSTextField(labelWithString: "Weather")
        title.font = .boldSystemFont(ofSize: 18)
        title.textColor = .labelColor
        let locationLabel = NSTextField(labelWithString: "Location")
        locationLabel.font = .systemFont(ofSize: 13, weight: .medium)
        locationLabel.textColor = .labelColor
        let explanation = NSTextField(wrappingLabelWithString:
            "Type a city; no location permission is requested. Weather is cached for about an hour and only weights which scenes are chosen. Playback never waits for it."
        )
        explanation.textColor = .secondaryLabelColor
        let source = NSTextField(wrappingLabelWithString:
            "Free, key-less data source: Open-Meteo (WeatherKit is not used). If weather is unavailable, playback falls back to the normal logic."
        )
        source.textColor = .tertiaryLabelColor
        source.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let playbackTitle = NSTextField(labelWithString: "Playback")
        playbackTitle.font = .boldSystemFont(ofSize: 18)
        playbackTitle.textColor = .labelColor
        let speedLabel = NSTextField(labelWithString: "Screen saver playback speed")
        speedLabel.font = .systemFont(ofSize: 13, weight: .medium)
        speedLabel.textColor = .labelColor
        speedPopUp.addItems(withTitles: SnoopyPreferences.playbackRateChoices.map(SnoopyPreferences.playbackRateTitle))
        let speedRow = NSStackView(views: [speedLabel, speedPopUp])
        speedRow.orientation = .horizontal
        speedRow.spacing = 12
        let speedNote = NSTextField(wrappingLabelWithString:
            "The desktop wallpaper has its own speed in the Snoopy Wallpaper menu."
        )
        speedNote.textColor = .tertiaryLabelColor
        speedNote.font = .systemFont(ofSize: 11)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        saveButton.target = self
        saveButton.action = #selector(saveAndRefresh(_:))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [
            title, enabledButton, locationLabel, cityField, explanation, statusLabel, source,
            playbackTitle, speedRow, speedNote, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: source)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cityField.translatesAutoresizingMaskIntoConstraints = false
        explanation.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        source.translatesAutoresizingMaskIntoConstraints = false
        speedNote.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        guard let content = panel.contentView else { return }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            cityField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            source.widthAnchor.constraint(equalTo: stack.widthAnchor),
            speedNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func reload() {
        enabledButton.state = SnoopyPreferences.weatherEnabled ? .on : .off
        cityField.stringValue = SnoopyPreferences.defaults.string(forKey: SnoopyPreferences.cityNameKey) ?? ""
        if let snapshot = SnoopyPreferences.weatherSnapshot(), snapshot.isUsable {
            let time = DateFormatter.localizedString(from: snapshot.observedAt, dateStyle: .none, timeStyle: .short)
            statusLabel.stringValue = "Last updated: \(snapshot.locationName ?? cityField.stringValue) · \(snapshot.conditions.joined(separator: ", ")) · \(time)"
        } else {
            statusLabel.stringValue = "No weather cached yet. It updates as soon as you save."
        }
        let current = SnoopyPreferences.playbackRate(for: .screenSaver)
        let index = SnoopyPreferences.playbackRateChoices.firstIndex { abs($0 - current) < 0.001 }
            ?? SnoopyPreferences.playbackRateChoices.firstIndex(of: 1.0) ?? 0
        speedPopUp.selectItem(at: index)
        updateEnabledState()
    }

    @objc private func toggleWeather(_ sender: Any?) {
        updateEnabledState()
    }

    private func updateEnabledState() {
        cityField.isEnabled = enabledButton.state == .on
        saveButton.title = enabledButton.state == .on ? "Save & Update Weather" : "Save"
    }

    private func savePlaybackSpeed() {
        let index = speedPopUp.indexOfSelectedItem
        guard SnoopyPreferences.playbackRateChoices.indices.contains(index) else { return }
        SnoopyPreferences.setPlaybackRate(SnoopyPreferences.playbackRateChoices[index], for: .screenSaver)
    }

    @objc private func cancel(_ sender: Any?) {
        finish(returnCode: .cancel)
    }

    @objc private func saveAndRefresh(_ sender: Any?) {
        savePlaybackSpeed()
        let enabled = enabledButton.state == .on
        if !enabled {
            SnoopyPreferences.weatherEnabled = false
            finish(returnCode: .OK)
            return
        }
        let city = cityField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard city.count >= 2 else {
            statusLabel.stringValue = SnoopyWeatherError.invalidCity.localizedDescription
            NSSound.beep()
            return
        }
        setBusy(true, status: "Resolving the location and updating the weather…")
        Task {
            do {
                let client = SnoopyWeatherClient()
                let location = try await client.resolve(city: city)
                let snapshot = try await client.fetch(location: location)
                SnoopyPreferences.save(weatherLocation: location)
                SnoopyPreferences.save(weatherSnapshot: snapshot)
                SnoopyPreferences.weatherEnabled = true
                statusLabel.stringValue = "Updated: \(location.name) · \(snapshot.conditions.joined(separator: ", "))"
                setBusy(false)
                finish(returnCode: .OK)
            } catch {
                setBusy(false, status: error.localizedDescription)
                NSSound.beep()
            }
        }
    }

    private func setBusy(_ busy: Bool, status: String? = nil) {
        enabledButton.isEnabled = !busy
        cityField.isEnabled = !busy && enabledButton.state == .on
        saveButton.isEnabled = !busy
        speedPopUp.isEnabled = !busy
        if let status { statusLabel.stringValue = status }
    }

    private func finish(returnCode: NSApplication.ModalResponse) {
        if let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: returnCode)
        } else {
            panel.orderOut(nil)
        }
    }
}
