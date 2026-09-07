import AppKit
import SnoopySceneKit
import SnoopyTVCore
import SwiftUI

/// AppKit side of the app: starts the desktop windows and owns the model the
/// status panel observes.
@MainActor
final class WallpaperAppDelegate: NSObject, NSApplicationDelegate {
    let controller = WallpaperController()
    private(set) lazy var model = WallpaperModel(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        model.refresh()
        installScreenshotHook()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    // MARK: - Screenshots (remote checks)

    /// Posting this local distributed notification makes the app write its
    /// own panel and a frame of every playing wallpaper to PNG files:
    ///
    ///     ~/Library/Application Support/Snoopy Wallpaper/Screenshots/panel.png
    ///     …/wallpaper-<displayID>.png
    ///
    /// The destination is fixed; nothing is read from the notification. It
    /// exists because the desktop cannot be captured from a session without
    /// Screen Recording permission (for example when the Mac is used remotely).
    static let screenshotNotification = Notification.Name("com.dingdangnao.snoopy.wallpaper.screenshot")

    private func installScreenshotHook() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(writeScreenshots(_:)),
            name: Self.screenshotNotification, object: nil
        )
    }

    @objc private func writeScreenshots(_ note: Notification) {
        Task { @MainActor in
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = support.appendingPathComponent("Snoopy Wallpaper/Screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The panel only fetches live frames while it is visible; pretend
            // it is for the render so the preview is a real frame.
            let wasVisible = model.panelVisible
            model.setPanelVisible(true)
            model.refresh()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            model.refresh()
            let renderer = ImageRenderer(
                content: StatusPanelView(model: model).background(Color(nsColor: .windowBackgroundColor))
            )
            renderer.scale = 2
            if let image = renderer.nsImage {
                Self.writePNG(image, to: directory.appendingPathComponent("panel.png"))
            }
            if !wasVisible { model.setPanelVisible(false) }
            for (displayID, scene) in controller.playingScenes {
                scene.makePreviewImage(maxPixelSize: 1920) { cgImage in
                    guard let cgImage else { return }
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    Self.writePNG(image, to: directory.appendingPathComponent("wallpaper-\(displayID).png"))
                }
            }
            NSLog("SnoopyWallpaper: screenshots written to %@", directory.path)
        }
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
