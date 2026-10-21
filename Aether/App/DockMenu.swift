import AetherCore
import AppKit

@MainActor
final class DockMenuBuilder {
    weak var player: PlayerModel?

    func menu() -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: player?.state == .playing ? "Pause" : "Play",
                                action: #selector(togglePlayback), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let next = NSMenuItem(title: "Next", action: #selector(nextTrack), keyEquivalent: "")
        next.target = self
        menu.addItem(next)
        return menu
    }

    @objc private func togglePlayback() { player?.toggle() }
    @objc private func nextTrack() { player?.next() }
}
