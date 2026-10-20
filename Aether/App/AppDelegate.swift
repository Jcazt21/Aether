import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Dark-only product: menus, alerts and panels follow the window appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    /// Downloads keep running with the window closed; the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
