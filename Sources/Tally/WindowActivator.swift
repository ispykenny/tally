import AppKit
import SwiftUI

/// MenuBarExtra panels in an accessory (LSUIElement) app don't reliably
/// become the key window, so text fields silently ignore typing and paste.
/// This grabs key status for the hosting window whenever it becomes visible.
struct WindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> ActivatorView { ActivatorView() }
    func updateNSView(_ nsView: ActivatorView, context: Context) {}

    final class ActivatorView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            Self.makeKey(window)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window, window.isVisible else { return }
                Self.makeKey(window)
            }
        }

        private static func makeKey(_ window: NSWindow) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
