import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AetherApp so termination can restore the DAC's original sample rate.
    var onTerminate: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Dark-only product: menus, alerts and panels follow the window appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    /// Downloads keep running with the window closed; the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
}
