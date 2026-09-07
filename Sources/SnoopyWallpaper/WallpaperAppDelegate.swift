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
            // The first live frame of a 4K video can take a few seconds to
            // decode; wait for it (bounded) so the render is not a placeholder.
            for _ in 0..<16 where model.previewImage == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
                model.refresh()
            }
            // The first frame can predate the character's preroll; let the
            // panel's own 2 s clock fetch a settled one.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            model.refresh()
            // An AppKit hosting view in an offscreen window draws the real
            // controls (SwiftUI's ImageRenderer draws switches as placeholders).
            let hosting = NSHostingView(
                rootView: StatusPanelView(model: model).background(Color(nsColor: .windowBackgroundColor))
            )
            hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 10)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            // Controls only take their bound state once the window server has
            // displayed them, so the window is put on screen, practically
            // invisible, for the render.
            window.alphaValue = 0.01
            window.level = .floating
            window.ignoresMouseEvents = true
            if let screen = NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY))
            }
            window.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let image = NSImage(size: hosting.bounds.size)
                image.addRepresentation(rep)
                Self.writePNG(image, to: directory.appendingPathComponent("panel.png"))
            }
            window.orderOut(nil)
            window.close()
            model.setPanelVisible(wasVisible)
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

    private static func renderLayerTree(of view: NSView, scale: CGFloat) -> NSImage? {
        view.wantsLayer = true
        guard let layer = view.layer else { return nil }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cgContext = context.cgContext
        cgContext.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            cgContext.translateBy(x: 0, y: size.height)
            cgContext.scaleBy(x: 1, y: -1)
        }
        layer.render(in: cgContext)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
