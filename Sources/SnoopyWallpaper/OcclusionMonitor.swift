import AppKit

/// Polls the window list once a second and reports when regular application
/// windows cover most of a display — the signal for "pause when hidden". This
/// is a port of Aerial's `DesktopOcclusionMonitor`: it grids the display into
/// 50×50 cells, marks every cell touched by an on-screen window at a normal
/// level (0 ≤ level < Dock) owned by another process, and compares the covered
/// fraction against a threshold (Aerial's default 0.6).
final class OcclusionMonitor {
    static let didChangeNotification = Notification.Name("SnoopyWallpaper.occlusionDidChange")
    static let threshold = 0.6

    let displayID: CGDirectDisplayID
    private(set) var isOccluded = false
    private var timer: DispatchSourceTimer?
    private var isCoolingDown = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    deinit { stop() }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + 1.0, repeating: 1.0)
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isCoolingDown = false
    }

    /// Ignore polls for a while after a playback change so start/stop churn
    /// cannot oscillate with window animations.
    func cooldown(seconds: TimeInterval) {
        isCoolingDown = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.isCoolingDown = false
        }
    }

    private func poll() {
        guard !isCoolingDown else { return }
        // Resolve the display's bounds on every poll so display rearrangement
        // and resolution changes heal on the next tick.
        let coverage = Self.coverage(for: CGDisplayBounds(displayID))
        let nowOccluded = coverage >= Self.threshold
        guard nowOccluded != isOccluded else { return }
        isOccluded = nowOccluded
        let monitor = self
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: OcclusionMonitor.didChangeNotification, object: monitor)
        }
    }

    /// Fraction of `screenFrame` (CG global coordinates, top-left origin)
    /// covered by other processes' normal-level windows.
    static func coverage(for screenFrame: CGRect) -> Double {
        guard !screenFrame.isNull, screenFrame.width > 0, screenFrame.height > 0 else { return 0 }
        let gridCols = 50, gridRows = 50
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else { return 0 }

        var grid = [Bool](repeating: false, count: gridCols * gridRows)
        let cellWidth = screenFrame.width / CGFloat(gridCols)
        let cellHeight = screenFrame.height / CGFloat(gridRows)
        for entry in windowList {
            if let pid = entry[kCGWindowOwnerPID] as? Int32, pid == ownPID { continue }
            guard let layer = entry[kCGWindowLayer] as? Int, layer >= 0, layer < dockLevel else { continue }
            guard let boundsRaw = entry[kCGWindowBounds] else { continue }
            var windowRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsRaw as! CFDictionary, &windowRect) else { continue }
            let clipped = windowRect.intersection(screenFrame)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            let minCol = max(0, Int((clipped.minX - screenFrame.minX) / cellWidth))
            let maxCol = min(gridCols - 1, Int((clipped.maxX - screenFrame.minX) / cellWidth))
            let minRow = max(0, Int((clipped.minY - screenFrame.minY) / cellHeight))
            let maxRow = min(gridRows - 1, Int((clipped.maxY - screenFrame.minY) / cellHeight))
            guard minCol <= maxCol, minRow <= maxRow else { continue }
            for row in minRow...maxRow {
                for col in minCol...maxCol {
                    grid[row * gridCols + col] = true
                }
            }
        }
        return Double(grid.filter { $0 }.count) / Double(gridCols * gridRows)
    }
}
