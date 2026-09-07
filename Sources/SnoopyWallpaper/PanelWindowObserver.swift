import AppKit
import SwiftUI

/// Tells the panel's model whether the panel's window is on screen. A
/// `MenuBarExtra` in its window style keeps the panel's view hierarchy alive
/// between openings — SwiftUI's `onAppear` / `onDisappear` fire once — so
/// visibility is read from the AppKit window that hosts the panel: it is on
/// screen while it is ordered in. The window's ordering (occlusion state),
/// key status and closing notifications re-read it. Zero-size; place it in
/// the panel's background.
struct PanelWindowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView(frame: .zero)
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private weak var observedWindow: NSWindow?
        private var reported: Bool?

        deinit { NotificationCenter.default.removeObserver(self) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window !== observedWindow {
                let center = NotificationCenter.default
                center.removeObserver(self)
                observedWindow = window
                if let window {
                    for name in [NSWindow.didChangeOcclusionStateNotification,
                                 NSWindow.didBecomeKeyNotification,
                                 NSWindow.didResignKeyNotification] {
                        center.addObserver(self, selector: #selector(windowDidChange(_:)), name: name, object: window)
                    }
                    center.addObserver(self, selector: #selector(windowWillClose(_:)),
                                       name: NSWindow.willCloseNotification, object: window)
                }
            }
            report(window?.isVisible ?? false)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        @objc private func windowDidChange(_ note: Notification) {
            report(window?.isVisible ?? false)
        }

        @objc private func windowWillClose(_ note: Notification) {
            report(false)
        }

        private func report(_ visible: Bool) {
            guard visible != reported else { return }
            reported = visible
            onChange?(visible)
        }
    }
}
