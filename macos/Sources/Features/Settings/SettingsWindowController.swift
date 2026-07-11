import Cocoa
import SwiftUI

/// Hosts the Settings window. Single instance — repeated calls to `show` just bring the
/// same window (and whatever live settings state it already has) back to the front
/// instead of recreating it.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private static let defaultSize = NSSize(width: 720, height: 520)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wisp Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        windowFrameAutosaveName = "WispSettingsWindow"
    }

    required init?(coder: NSCoder) { nil }

    /// Shows the Settings window, creating its content the first time this is called.
    /// Subsequent calls just bring the existing window (and its live state) to the front.
    func show(ghostty: Ghostty.App) {
        if window?.contentViewController == nil {
            window?.contentViewController = NSHostingController(rootView: SettingsView(ghostty: ghostty))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// This is called when "escape" is pressed while the window is key.
    @objc func cancel(_ sender: Any?) {
        window?.performClose(sender)
    }
}
