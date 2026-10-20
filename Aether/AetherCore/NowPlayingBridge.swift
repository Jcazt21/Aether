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
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.player.toggle(); return .success }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.player.state != .playing else { return .success }
            self.player.toggle()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.player.state == .playing else { return .success }
            self.player.toggle()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.player.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.player.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent, self.player.duration > 0 else { return .commandFailed }
            self.player.seek(toFraction: e.positionTime / self.player.duration)
            return .success
        }
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
            let size = NSSize(width: cg.width, height: cg.height)
            // Capture the Sendable CGImage, build the NSImage inside the (Sendable) request handler.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in NSImage(cgImage: cg, size: size) }
        }
        center.nowPlayingInfo = info
        center.playbackState = player.state == .playing ? .playing : .paused
    }
}
