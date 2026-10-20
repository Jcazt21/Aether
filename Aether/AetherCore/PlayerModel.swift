import AetherCore
import AppKit
import CoreGraphics
import Cosmos
import Foundation
import HiFiClient
import Observation
import TagKit

struct NowPlaying: Equatable {
    let url: URL
    let title: String
    let artist: String
    let album: String?
    let formatLabel: String
    let artwork: CGImage?
    static func == (a: NowPlaying, b: NowPlaying) -> Bool { a.url == b.url && a.title == b.title && a.artist == b.artist }
}

struct SignalPath: Equatable {
    let sourceRate: Double
    let bitDepth: Int?
    let deviceRate: Double
    let deviceName: String
    let isBitPerfect: Bool

    private static func khz(_ rate: Double) -> String {
        let k = rate / 1000
        return k.rounded() == k ? String(Int(k)) : String(format: "%.1f", k)
    }

    var summary: String {
        let source = bitDepth.map { "\($0)/\(Self.khz(sourceRate))" } ?? "\(Self.khz(sourceRate)) kHz"
        return "\(source) → \(deviceName) · \(Self.khz(deviceRate)) kHz · \(isBitPerfect ? "BIT-PERFECT" : "REMUESTREADO")"
    }
}

struct PlayQueue: Equatable {
    var urls: [URL] = []
    var index = 0
    var current: URL? { urls.indices.contains(index) ? urls[index] : nil }
    mutating func next() -> URL? { guard index + 1 < urls.count else { return nil }; index += 1; return current }
    mutating func previous() -> URL? { guard index > 0 else { return nil }; index -= 1; return current }
}

@MainActor
@Observable
final class PlayerModel {
    private(set) var current: NowPlaying?
    private(set) var state: PlaybackEngine.State = .idle
    private(set) var waveform: [Float] = []
    private(set) var signal: SignalPath?
    private(set) var queue = PlayQueue()
    var meteringVisible = false { didSet { engine.setMetering(meteringVisible) } }
    private(set) var previewingTrackID: Int?
    private(set) var isPreparingPreview = false
    @ObservationIgnored private let previewCache = PreviewCache()

    @ObservationIgnored let engine = PlaybackEngine()
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var waveformCache: [String: [Float]] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    // @Observable does not support `lazy`: assigned once at the end of init.
    @ObservationIgnored private(set) var nowPlaying: NowPlayingBridge!

    init(preferences: Preferences) {
        self.preferences = preferences
        engine.onStateChange = { [weak self] in self?.syncState() }
        engine.onFinish = { [weak self] in self?.next() }
        nowPlaying = NowPlayingBridge(player: self)
    }

    var duration: Double { engine.track?.duration ?? 0 }
    /// Read only from TimelineView bodies (no observation, no timers).
    var currentTime: Double { engine.currentTime }

    func play(urls: [URL], startAt index: Int) {
        queue = PlayQueue(urls: urls, index: index)
        load(queue.current, autoplay: true)
    }

    func preview(_ track: TidalTrack, client: HiFiClient) {
        if previewingTrackID == track.id, current != nil { toggle(); return }
        previewingTrackID = track.id
        isPreparingPreview = true
        Task {
            defer { isPreparingPreview = false }
            let session = URLSession(configuration: .ephemeral)
            do {
                let info = try await client.playbackInfo(trackID: track.id, quality: .lossless)
                let manifest = try info.dashManifest()
                let (initData, _) = try await session.data(from: manifest.initializationURL)
                _ = try await engine.loadStream(manifest: manifest, initSegment: [UInt8](initData), bitDepth: info.bitDepth) { url in
                    [UInt8](try await session.data(from: url).0)
                }
                current = NowPlaying(url: manifest.initializationURL, title: track.displayTitle, artist: track.allArtistNames,
                                     album: track.album?.title, formatLabel: "TIDAL · \(info.bitDepth ?? 16)/44.1 · STREAM", artwork: nil)
                waveform = []
            } catch {
                guard let url = try? await previewCache.file(for: track, client: client), previewingTrackID == track.id else { return }
                play(urls: [url], startAt: 0)
            }
        }
    }

    func toggle() {
        if current == nil, let url = queue.current { load(url, autoplay: true); return }
        try? engine.toggle()
    }

    func next() {
        if let url = queue.next() { load(url, autoplay: true) } else { engine.stop() }
    }

    func previous() {
        if currentTime > 3 { engine.seek(to: 0); return }
        if let url = queue.previous() { load(url, autoplay: true) }
    }

    func seek(toFraction fraction: Double) {
        engine.seek(to: min(max(fraction, 0), 1) * duration)
        nowPlaying.update()
    }

    func skip(by seconds: Double) {
        engine.seek(to: min(max(currentTime + seconds, 0), duration))
        nowPlaying.update()
    }

    func shutdown() {
        engine.stop()
        engine.restoreDeviceRate()
    }

    private func load(_ url: URL?, autoplay: Bool) {
        guard let url else { return }
        loadTask?.cancel()
        engine.bitPerfect = preferences.bitPerfect
        let probe = try? AudioProbe.probe(url)
        do {
            _ = try engine.load(url, bitDepth: probe?.bitDepth)
            if autoplay { try engine.play() }
        } catch {
            current = nil
            return
        }
        refreshSignal()
        let key = "\(url.path)|\(probe?.duration ?? 0)"
        waveform = waveformCache[key] ?? []
        loadTask = Task {
            async let tags = Task.detached(priority: .userInitiated) { (try? TagIO.read(url)) ?? TrackTags() }.value
            async let peaks = Task.detached(priority: .utility) { try? WaveformAnalyzer.peaks(for: url, bins: 1200) }.value
            let t = await tags
            let art = await Task.detached(priority: .userInitiated) { t.artwork.flatMap { ArtworkProcessor.thumbnail($0.data, maxPixel: 128) } }.value
            guard !Task.isCancelled else { return }
            let stem = url.deletingPathExtension().lastPathComponent
            current = NowPlaying(url: url, title: t.title ?? stem, artist: t.artist ?? "", album: t.album,
                                 formatLabel: probe?.label ?? url.pathExtension.uppercased(), artwork: art)
            nowPlaying.update()
            if waveform.isEmpty, let p = await peaks, !Task.isCancelled {
                waveform = p
                waveformCache[key] = p
                if waveformCache.count > 32 { waveformCache.removeValue(forKey: waveformCache.keys.first!) }
            }
        }
    }

    private func syncState() {
        state = engine.state
        refreshSignal()
        nowPlaying.update()
    }

    private func refreshSignal() {
        guard let track = engine.track else { signal = nil; return }
        signal = SignalPath(sourceRate: track.sampleRate, bitDepth: track.bitDepth, deviceRate: engine.deviceSampleRate,
                            deviceName: engine.deviceName, isBitPerfect: engine.isBitPerfect)
    }
}
