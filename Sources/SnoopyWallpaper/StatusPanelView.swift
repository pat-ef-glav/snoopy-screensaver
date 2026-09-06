import Combine
import SnoopyTVCore
import SwiftUI

/// The status-item panel: a compact card in the style of Klack / Little Snitch.
struct StatusPanelView: View {
    @ObservedObject var model: WallpaperModel
    private let clock = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refresh() }
        .onReceive(clock) { _ in model.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Snoopy").font(.headline)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Scene")
            thumbnail(model.currentThumbnail, width: 292, height: 164)
                .overlay(alignment: .bottomLeading) {
                    if let id = model.currentSceneID {
                        Text(Self.sceneTitle(id))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                            .padding(6)
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
            .controlSize(.small)
            if !model.upcoming.isEmpty {
                Text("Up next, by chance").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(model.upcoming) { choice in
                        VStack(spacing: 3) {
                            thumbnail(choice.thumbnail, width: 92, height: 52)
                            Text("\(Int((choice.chance * 100).rounded())) %")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            speedRow("Wallpaper Speed", value: model.wallpaperRate) { model.setWallpaperRate($0) }
            speedRow("Screen Saver Speed", value: model.saverRate) { model.setSaverRate($0) }
        }
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.hasBattery {
                sectionTitle("On Battery")
                ForEach(SnoopyOnBatteryMode.allCases, id: \.self) { mode in
                    Button { model.setOnBatteryMode(mode) } label: {
                        HStack {
                            Text(mode.title)
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
            Toggle("Pause When Covered by Windows",
                   isOn: Binding(get: { model.pauseWhenHidden }, set: { model.setPauseWhenHidden($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Weather")
            Text(model.weatherText).font(.caption).foregroundStyle(.secondary)
            Button("Weather & Screen Saver Settings…") { model.showWeatherSettings() }
                .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at Login",
                   isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.launchAtLoginAvailable)
            Text("Version \(model.version)").font(.caption).foregroundStyle(.tertiary)
            Button("Quit Snoopy Wallpaper") { model.quit() }
                .buttonStyle(.plain)
        }
    }

    // MARK: - Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func speedRow(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                sectionTitle(title)
                Spacer()
                Text(SnoopyPreferences.playbackRateTitle(value)).font(.caption).monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: { set($0) }), in: 0.5...2, step: 0.25)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func thumbnail(_ image: NSImage?, width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    shape.fill(.quaternary)
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
    }

    /// "104_IS033" → "Scene 33 (bundle 104)"; palettes and ids stay readable.
    private static func sceneTitle(_ id: String) -> String {
        let parts = id.split(separator: "_")
        if parts.count == 2, parts[1].hasPrefix("IS"), let number = Int(parts[1].dropFirst(2)) {
            return "Scene \(number) · bundle \(parts[0])"
        }
        return id
    }
}
