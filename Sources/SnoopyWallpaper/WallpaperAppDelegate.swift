import AppKit
import SnoopySceneKit
import SnoopyTVCore

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}
