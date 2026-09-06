import Combine
import SnoopyTVCore
import SwiftUI

/// The status-item panel: a frosted card in the style of Klack / Little Snitch.
struct StatusPanelView: View {
    @ObservedObject var model: WallpaperModel
    private let clock = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let cardWidth: CGFloat = 340
    private var contentWidth: CGFloat { cardWidth - 32 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            sceneSection
            Divider()
            speedSection
            Divider()
            powerSection
            Divider()
            weatherSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: cardWidth)
        .background(.ultraThickMaterial)
        .onAppear { model.refresh() }
        .onReceive(clock) { _ in model.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Snoopy").font(.title2.weight(.semibold))
                Text(model.status).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Scene")
            thumbnail(model.currentThumbnail, width: contentWidth, height: contentWidth * 9 / 16)
                .overlay(alignment: .bottomLeading) {
                    if let id = model.currentSceneID {
                        Text(Self.sceneTitle(id))
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            HStack(spacing: 8) {
                Button { model.previousScene() } label: { Label("Previous", systemImage: "backward.end.fill") }
                    .disabled(!model.canGoBack || !model.isEnabled)
                Button { model.nextScene() } label: { Label("Next Scene", systemImage: "forward.end.fill") }
                    .disabled(!model.isEnabled)
                Spacer()
                Button { model.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Restart Snoopy")
                    .disabled(!model.isEnabled)
            }
            .buttonStyle(.bordered)
            if !model.upcoming.isEmpty {
                Text("Up next, by chance").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(model.upcoming) { choice in
                        VStack(spacing: 4) {
                            thumbnail(choice.thumbnail, width: (contentWidth - 16) / 3, height: (contentWidth - 16) / 3 * 9 / 16)
                            Text("\(Int((choice.chance * 100).rounded())) %")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            speedRow("Wallpaper Speed", value: model.wallpaperRate) { model.setWallpaperRate($0) }
            speedRow("Screen Saver Speed", value: model.saverRate) { model.setSaverRate($0) }
        }
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.hasBattery {
                sectionTitle("On Battery")
                ForEach(SnoopyOnBatteryMode.allCases, id: \.self) { mode in
                    Button { model.setOnBatteryMode(mode) } label: {
                        HStack {
                            Text(mode.title).font(.body)
                            Spacer()
                            if model.onBatteryMode == mode {
                                Image(systemName: "checkmark").font(.body.weight(.semibold))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle(isOn: Binding(get: { model.pauseWhenHidden }, set: { model.setPauseWhenHidden($0) })) {
                Text("Pause When Covered by Windows").font(.body)
            }
            .toggleStyle(.switch)
        }
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Weather")
            Text(model.weatherText).font(.callout).foregroundStyle(.secondary)
            Button("Weather & Screen Saver Settings…") { model.showWeatherSettings() }
                .buttonStyle(.plain)
                .font(.body)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Text("Launch at Login").font(.body)
            }
            .toggleStyle(.switch)
            .disabled(!model.launchAtLoginAvailable)
            Text("Version \(model.version)").font(.callout).foregroundStyle(.tertiary)
            Button("Quit Snoopy Wallpaper") { model.quit() }
                .buttonStyle(.plain)
                .font(.body)
        }
    }

    // MARK: - Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.secondary)
    }

    private func speedRow(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionTitle(title)
                Spacer()
                Text(SnoopyPreferences.playbackRateTitle(value)).font(.body).monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: { set($0) }), in: 0.5...2, step: 0.25)
        }
    }

    @ViewBuilder
    private func thumbnail(_ image: NSImage?, width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let image {
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
        .frame(width: width, height: height)
        .clipShape(shape)
    }

    /// "104_IS033" → "Scene 33 · bundle 104"; other ids stay as they are.
    private static func sceneTitle(_ id: String) -> String {
        let parts = id.split(separator: "_")
        if parts.count == 2, parts[1].hasPrefix("IS"), let number = Int(parts[1].dropFirst(2)) {
            return "Scene \(number) · bundle \(parts[0])"
        }
        return id
    }
}
