import AppKit

/// Menu-bar-only app. `LSUIElement` in the bundle's Info.plist hides the Dock
/// icon; the activation policy is also set here so `swift run SnoopyWallpaper`
/// from a checkout behaves the same.
@main
@MainActor
enum SnoopyWallpaperApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = WallpaperAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
