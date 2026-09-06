import AppKit
import SwiftUI

/// Menu-bar-only app. The status item opens a Klack-style panel
/// (`MenuBarExtra` in its window style) whose content is `StatusPanelView`;
/// the AppKit `WallpaperAppDelegate` owns the desktop windows and policy.
/// `LSUIElement` in the bundle's Info.plist hides the Dock icon; the delegate
/// also sets the accessory activation policy so `swift run` behaves the same.
@main
struct SnoopyWallpaperApp: App {
    @NSApplicationDelegateAdaptor(WallpaperAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusPanelView(model: appDelegate.model)
        } label: {
            Image(systemName: "dog.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
