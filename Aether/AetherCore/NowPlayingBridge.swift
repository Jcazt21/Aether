import AetherCore
import AppKit
import CoreGraphics
import Foundation
import MediaPlayer

@MainActor
final class NowPlayingBridge {
    private unowned let player: PlayerModel

    init(player: PlayerModel) {
        self.player = player
        Self.registerCommands(for: self)
    }

    private enum Command: Sendable { case toggle, play, pause, next, previous, seek(Double) }

    /// MediaPlayer invokes these handlers on its own queue. They must be built in a nonisolated context
    /// (closures made inside a @MainActor method inherit main-actor isolation and trap when called off-main).
    private nonisolated static func registerCommands(for bridge: NowPlayingBridge) {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ make: @escaping @Sendable (MPRemoteCommandEvent) -> Command?) {
            command.addTarget { [weak bridge] event in
                guard let cmd = make(event) else { return .commandFailed }
                Task { @MainActor in bridge?.handle(cmd) }
                return .success
            }
        }
        add(center.togglePlayPauseCommand) { _ in .toggle }
        add(center.playCommand) { _ in .play }
        add(center.pauseCommand) { _ in .pause }
        add(center.nextTrackCommand) { _ in .next }
        add(center.previousTrackCommand) { _ in .previous }
        add(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
        }
    }

    private func handle(_ command: Command) {
        switch command {
        case .toggle: player.toggle()
        case .play: if player.state != .playing { player.toggle() }
        case .pause: if player.state == .playing { player.toggle() }
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let position): if player.duration > 0 { player.seek(toFraction: position / player.duration) }
        }
    }

    private nonisolated static func artwork(_ cg: CGImage) -> MPMediaItemArtwork {
        let size = NSSize(width: cg.width, height: cg.height)
        return MPMediaItemArtwork(boundsSize: size) { _ in NSImage(cgImage: cg, size: size) }
    }

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let now = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: now.title,
            MPMediaItemPropertyArtist: now.artist,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
        ]
        if let album = now.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let cg = now.artwork {
            info[MPMediaItemPropertyArtwork] = Self.artwork(cg)
        }
        center.nowPlayingInfo = info
        center.playbackState = player.state == .playing ? .playing : .paused
    }
}
