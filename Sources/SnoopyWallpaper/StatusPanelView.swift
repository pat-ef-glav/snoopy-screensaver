import SnoopyTVCore
import SwiftUI

/// The status-item panel: a frosted card in the style of Klack / Little
/// Snitch. Buttons and menu rows highlight under the pointer; the preview is
/// a live frame of the wallpaper at the display's own aspect ratio. The model
/// refreshes on its own clock while the panel's window is on screen
/// (`PanelWindowObserver`), so nothing is rendered for a closed panel.
struct StatusPanelView: View {
    @ObservedObject var model: WallpaperModel

    private let cardWidth: CGFloat = 364
    private let cardPadding: CGFloat = 16
    private var contentWidth: CGFloat { cardWidth - 2 * cardPadding }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        }
    }

    /// The live preview with the room (or video) caption, what Snoopy is
    /// doing now and next, and the scene buttons.
    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .overlay(alignment: .bottomLeading) {
                    if let caption = model.sceneCaption {
                        Text(caption)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                playbackLine("Now", model.nowLabel)
                playbackLine("Then", model.thenLabel)
            }
            HStack(spacing: 8) {
                Button { model.previousScene() } label: { Label("Previous", systemImage: "backward.end.fill") }
                    .disabled(!model.canGoBack || !model.isEnabled)
                Button { model.nextScene() } label: { Label("Next Scene", systemImage: "forward.end.fill") }
                    .disabled(!model.isEnabled)
                Spacer()
                Button { model.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(PanelButtonStyle(compact: true))
                    .help("Restart Snoopy")
                    .disabled(!model.isEnabled)
            }
            .buttonStyle(PanelButtonStyle())
        }
    }

    /// Speed (the two pop-ups beside the title when they fit on one line,
    /// under it otherwise), On Battery (laptops only) and Pause When Covered
    /// by Windows.
    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    rowTitle("Speed")
                    Spacer(minLength: 0)
                    speedPickers
                }
                VStack(alignment: .leading, spacing: 6) {
                    rowTitle("Speed")
                    HStack(spacing: 12) { speedPickers }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                rowTitle("Weather")
                Text(model.weatherText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button { model.refreshWeather() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(PanelButtonStyle(compact: true))
                    .help("Fetch the weather now")
                    .disabled(!model.weatherEnabled)
            }
            Button("Weather & Screen Saver Settings…") { model.showWeatherSettings() }
                .buttonStyle(MenuRowButtonStyle())
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Text("Launch at Login").font(.body).fixedSize()
            }
            .toggleStyle(.switch)
            .disabled(!model.launchAtLoginAvailable)
            Spacer()
            Button("Quit Snoopy Wallpaper") { model.quit() }
                .buttonStyle(MenuRowButtonStyle(fullWidth: false))
        }
    }

    // MARK: - Pieces

    private func rowTitle(_ title: String) -> some View {
        Text(title).font(.body.weight(.medium))
    }

    /// "Now: Pose AP007 · 12 s left" — the title in secondary, one line.
    private func playbackLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(title):").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(value).monospacedDigit()
        }
        .font(.body)
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

    /// The whole frame at the display's aspect ratio, in a frame of fixed
    /// size: a flexible image collapses when the panel's window keeps an
    /// earlier size, so the height is decided here from the image itself
    /// (16:10 for the placeholder), within sane bounds.
    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let height = previewHeight(for: model.previewImage)
        return Group {
            if let image = model.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    shape.fill(.quaternary)
                    Image(systemName: "photo").font(.title3).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: contentWidth, height: height)
        .clipShape(shape)
    }

    private func previewHeight(for image: NSImage?) -> CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return (contentWidth * 10 / 16).rounded() }
        let natural = contentWidth * image.size.height / image.size.width
        return min(max(natural, 140), 230).rounded()
    }
}

/// A rounded button that brightens under the pointer and darkens while
/// pressed, like the buttons in Klack's panel. `compact` is the icon-only
/// variant (the weather refresh).
struct PanelButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, compact: compact)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body)
                .padding(.horizontal, compact ? 6 : 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.22 : hovered ? 0.15 : 0.08))
                )
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovered = $0 && isEnabled }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

/// A menu-item-like text row: full width, the accent colour behind it while
/// the pointer is over it, as in a MenuBarExtra menu.
struct MenuRowButtonStyle: ButtonStyle {
    /// Stretch across the card (a menu row) or hug the title (a trailing
    /// action beside another control).
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, fullWidth: fullWidth)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(hovered ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1) : Color.clear)
                )
                .padding(.horizontal, -8)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}
