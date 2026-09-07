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
    private var screenshotRequestSource: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        model.refresh()
        installScreenshotHook()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenshotRequestSource?.cancel()
        controller.shutdown()
    }

    // MARK: - Screenshots (remote checks)

    /// `~/Library/Application Support/Snoopy Wallpaper/Screenshots`. Creating
    /// a file named `request` in it makes the app write its own panel
    /// (`panel.png`) and a frame of every playing wallpaper
    /// (`wallpaper-<displayID>.png`) there, then remove the request. It exists
    /// because the desktop cannot be captured from a session without Screen
    /// Recording permission (for example when the Mac is used remotely); a
    /// file works from any context, unlike a distributed notification.
    static var screenshotsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snoopy Wallpaper/Screenshots", isDirectory: true)
    }

    private func installScreenshotHook() {
        let directory = Self.screenshotsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.handleScreenshotRequestIfPresent() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        screenshotRequestSource = source
        handleScreenshotRequestIfPresent()
    }

    private func handleScreenshotRequestIfPresent() {
        let request = Self.screenshotsDirectory.appendingPathComponent("request")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        try? FileManager.default.removeItem(at: request)
        writeScreenshots()
    }

    private func writeScreenshots() {
        Task { @MainActor in
            let directory = Self.screenshotsDirectory
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
