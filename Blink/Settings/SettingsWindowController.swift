import AppKit
import SwiftUI

/// Hosts the SwiftUI settings form in a standard titled window. This is the
/// only window in the app that is allowed to take focus.
@MainActor
final class SettingsWindowController: NSWindowController {
    private var hasCentered = false

    init(settings: AppSettings) {
        let host = NSHostingController(rootView: SettingsView(settings: settings))
        let window = NSWindow(contentViewController: host)
        window.title = "Blink Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        if !hasCentered {
            window?.center()
            hasCentered = true
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
