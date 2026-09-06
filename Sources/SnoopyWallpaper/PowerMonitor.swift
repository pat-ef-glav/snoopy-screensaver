import Foundation
import IOKit.ps

/// Battery state from IOKit power sources (the same calls Aerial's
/// `Battery` helper uses), plus change notifications on the main run loop.
final class PowerMonitor {
    static let didChangeNotification = Notification.Name("SnoopyWallpaper.powerDidChange")

    private var source: CFRunLoopSource?

    /// Whether this Mac has a battery at all (desktops report no sources).
    static var hasBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources: NSArray = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() else {
            return false
        }
        return sources.count > 0
    }

    /// True while running on battery power (no unlimited power source).
    static var isOnBattery: Bool {
        IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited
    }

    /// Current charge percentage of the first battery, if any.
    static var batteryPercent: Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources: NSArray = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() else {
            return nil
        }
        for source in sources {
            guard let info: NSDictionary = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?
                    .takeUnretainedValue(),
                  let capacity = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return Int(Double(capacity) / Double(maximum) * 100)
        }
        return nil
    }

    /// Low battery as Aerial defines it: below 20 % (0 = unknown, not low).
    static var isLowBattery: Bool {
        guard let percent = batteryPercent, percent > 0 else { return false }
        return percent < 20
    }

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            NotificationCenter.default.post(name: PowerMonitor.didChangeNotification, object: monitor)
        }, context)?.takeRetainedValue() else {
            NSLog("SnoopyWallpaper: IOPSNotificationCreateRunLoopSource failed; battery changes will not be tracked")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = nil
    }

    deinit { stop() }
}
