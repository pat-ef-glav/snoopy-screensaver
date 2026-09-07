import SnoopyTVCore
import SwiftUI

/// The status-item panel: a compact frosted card in the style of Klack /
/// Little Snitch. Every control is small except the master switch. The
/// model refreshes on its own clock while the panel's window is on screen
/// (`PanelWindowObserver`), so nothing is rendered for a closed panel.
struct StatusPanelView: View {
    @ObservedObject var model: WallpaperModel

    private let cardWidth: CGFloat = 340
    private let cardPadding: CGFloat = 14
    private let previewHeight: CGFloat = 148
    private var contentWidth: CGFloat { cardWidth - 2 * cardPadding }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            sceneSection
            Divider()
            playbackSection
            Divider()
            weatherSection
            Divider()
            footer
        }
        .controlSize(.small)
        .padding(cardPadding)
        .frame(width: cardWidth)
        .background(.ultraThickMaterial)
        .background(PanelWindowObserver { model.setPanelVisible($0) }.frame(width: 0, height: 0))
        .onAppear { model.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Snoopy").font(.title2.weight(.semibold))
                Text(model.status).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.regular)
        }
    }

    /// The live preview with the room (or video) caption, what Snoopy is
    /// doing now and next, and the scene buttons.
    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
                .overlay(alignment: .bottomLeading) {
                    if let caption = model.sceneCaption {
                        Text(caption)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                playbackLine("Now", model.nowLabel)
                playbackLine("Then", model.thenLabel)
            }
            HStack(spacing: 8) {
                Button { model.previousScene() } label: { Label("Previous", systemImage: "backward.end.fill") }
                    .disabled(!model.canGoBack || !model.isEnabled)
                Button { model.nextScene() } label: { Label("Next Scene", systemImage: "forward.end.fill") }
                    .disabled(!model.isEnabled)
                Spacer()
                Button { model.restart() } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                    .help("Restart Snoopy")
                    .disabled(!model.isEnabled)
            }
            .buttonStyle(.bordered)
        }
    }

    /// Speed (the two pop-ups beside the title when they fit on one line,
    /// under it otherwise), On Battery (laptops only) and Pause When Covered
    /// by Windows.
    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    rowTitle("Speed")
                    Spacer(minLength: 0)
                    speedPickers
                }
                VStack(alignment: .leading, spacing: 4) {
                    rowTitle("Speed")
                    HStack(spacing: 10) { speedPickers }
                }
            }
            if model.hasBattery {
                HStack {
                    rowTitle("On Battery")
                    Spacer()
                    Picker("On Battery", selection: Binding(get: { model.onBatteryMode }, set: { model.setOnBatteryMode($0) })) {
                        ForEach(SnoopyOnBatteryMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            switchRow("Pause When Covered by Windows",
                      isOn: Binding(get: { model.pauseWhenHidden }, set: { model.setPauseWhenHidden($0) }))
        }
    }

    @ViewBuilder private var speedPickers: some View {
        ratePicker("Wallpaper", value: model.wallpaperRate) { model.setWallpaperRate($0) }
        ratePicker("Screen Saver", value: model.saverRate) { model.setSaverRate($0) }
    }

    /// "place · conditions · time": a long line loses the middle of the
    /// conditions, never the time, which is what tells whether it is fresh.
    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                rowTitle("Weather")
                Text(model.weatherText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button { model.refreshWeather() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Fetch the weather now")
                    .disabled(!model.weatherEnabled)
            }
            Button("Weather & Screen Saver Settings…") { model.showWeatherSettings() }
                .buttonStyle(.plain)
                .font(.body)
        }
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Text("Launch at Login").font(.body)
            }
            .toggleStyle(.switch)
            .disabled(!model.launchAtLoginAvailable)
            Spacer()
            Button("Quit Snoopy Wallpaper") { model.quit() }
                .buttonStyle(.plain)
                .font(.body)
        }
    }

    // MARK: - Pieces

    private func rowTitle(_ title: String) -> some View {
        Text(title).font(.body.weight(.medium))
    }

    /// "Now: Pose AP007 · 12 s left" — the title in secondary, one line.
    private func playbackLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(title):").foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.body)
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }

    /// A labelled pop-up over `SnoopyPreferences.playbackRateChoices`. A stored
    /// rate that is not one of them (a legacy value such as 1.75) is listed as
    /// an extra item, so the pop-up always names the speed that is playing.
    private func ratePicker(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        let choices = Self.rateChoices(including: value)
        return Picker(title, selection: Binding(get: { Self.rateSelection(for: value) }, set: set)) {
            ForEach(choices, id: \.self) { rate in
                Text(SnoopyPreferences.playbackRateTitle(rate)).tag(rate)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private static func rateSelection(for value: Double) -> Double {
        SnoopyPreferences.playbackRateChoices.first { abs($0 - value) < 0.001 } ?? value
    }

    private static func rateChoices(including value: Double) -> [Double] {
        let choices = SnoopyPreferences.playbackRateChoices
        guard !choices.contains(where: { abs($0 - value) < 0.001 }) else { return choices }
        return (choices + [value]).sorted()
    }

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // The whole frame, at the display's own aspect ratio: cropping to a
        // fixed height cut Snoopy off the top of tall rooms.
        return Group {
            if let image = model.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: contentWidth)
            } else {
                ZStack {
                    shape.fill(.quaternary)
                    Image(systemName: "photo").font(.title3).foregroundStyle(.tertiary)
                }
                .frame(width: contentWidth, height: previewHeight)
            }
        }
        .clipShape(shape)
    }
}
