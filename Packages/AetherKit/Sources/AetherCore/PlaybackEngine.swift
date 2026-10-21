@preconcurrency import AVFAudio
import FlacKit
public import Foundation
public import HiFiClient
import OSLog
import Synchronization

public struct LoadedTrack: Equatable, Sendable {
    public let url: URL
    public let sampleRate: Double
    public let channels: Int
    public let bitDepth: Int?
    public let frames: Int64
    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
}

/// Local-file playback. Signal path: AVAudioFile → PlayerNode → MainMixer (gain 1.0) → device.
/// With `bitPerfect`, the device nominal rate is switched to the file's rate before starting, so the
/// mixer does no sample-rate conversion and 16/24-bit samples pass through Float32 unchanged.
@MainActor
public final class PlaybackEngine {
    public enum State: Equatable, Sendable { case idle, playing, paused }

    private static let log = Logger(subsystem: "com.jazar.Aether", category: "aethercore")

    public private(set) var state: State = .idle { didSet { if state != oldValue { onStateChange?() } } }
    public private(set) var track: LoadedTrack?
    public var bitPerfect = true
    public var onFinish: (() -> Void)?
    public var onStateChange: (() -> Void)?
    public let meter = MeterTap()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var isScheduled = false
    private var originalDeviceRate: Double?
    private var isMetering = false
    private var configObserver: (any NSObjectProtocol)?
    private var streamTask: Task<Void, Never>?
    private var streamSource: StreamSource?

    private struct StreamSource {
        let manifest: DashManifest
        let makeDecoder: @Sendable () throws -> FlacPacketDecoder
        let fetch: @Sendable (URL) async throws -> [UInt8]
    }

    public init() {
        engine.attach(player)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    public var deviceSampleRate: Double { OutputDevice.defaultOutput()?.nominalSampleRate ?? 0 }
    public var deviceName: String { OutputDevice.defaultOutput()?.name ?? "" }

    public var isBitPerfect: Bool {
        guard let track else { return false }
        return track.sampleRate == deviceSampleRate && engine.mainMixerNode.outputVolume == 1 && player.volume == 1
    }

    @discardableResult
    public func load(_ url: URL, bitDepth: Int?) throws -> LoadedTrack {
        stop()
        streamSource = nil
        let file = try AVAudioFile(forReading: url)
        self.file = file
        let format = file.processingFormat
        let loaded = LoadedTrack(url: url, sampleRate: format.sampleRate, channels: Int(format.channelCount),
                                 bitDepth: bitDepth, frames: file.length)
        track = loaded

        engine.stop()
        if bitPerfect, let device = OutputDevice.defaultOutput() {
            let target = device.bestRate(for: format.sampleRate)
            if device.nominalSampleRate != target {
                if originalDeviceRate == nil { originalDeviceRate = device.nominalSampleRate }
                do { try device.setNominalSampleRate(target) } catch { Self.log.error("rate switch failed: \(String(describing: error))") }
            }
        }
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1
        engine.disconnectNodeOutput(player)
        try engine.connectNode(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        startFrame = 0
        state = .paused
        return loaded
    }

    public func play() throws {
        guard file != nil, state != .playing else { return }
        if !engine.isRunning { try engine.start() }
        if !isScheduled { schedule(from: startFrame) }
        try player.playAudio()
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        player.pause()
        state = .paused
    }

    public func toggle() throws { state == .playing ? pause() : try play() }

    public func stop() {
        generation += 1
        streamTask?.cancel()
        // player.stop() blocks the caller until the audio thread acknowledges; skip it when nothing is queued or running.
        if isScheduled || state == .playing || streamSource != nil { player.stop() }
        isScheduled = false
        startFrame = 0
        if state != .idle { state = file == nil ? .idle : .paused }
    }

    /// Streams DASH: fetch → decode → schedule, keeping ≤ 3 segments queued in the player node.
    public func loadStream(manifest: DashManifest, initSegment: [UInt8], bitDepth: Int?,
                           fetch: @escaping @Sendable (URL) async throws -> [UInt8]) async throws -> LoadedTrack {
        stop()
        streamTask?.cancel()
        file = nil
        let config = try FMP4Flac.parseInit(initSegment)
        let cookie = try StreamCookie.make(from: initSegment)
        let makeDecoder: @Sendable () throws -> FlacPacketDecoder = {
            try FlacPacketDecoder(config: config, cookie: cookie, maxPacketSize: 1 << 20)
        }
        let format = try makeDecoder().outputFormat
        engine.stop()
        engine.disconnectNodeOutput(player)
        try engine.connectNode(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        let loaded = LoadedTrack(url: manifest.initializationURL, sampleRate: format.sampleRate,
                                 channels: Int(format.channelCount), bitDepth: bitDepth, frames: Int64(manifest.totalSamples))
        track = loaded
        streamSource = StreamSource(manifest: manifest, makeDecoder: makeDecoder, fetch: fetch)
        try startStreaming(atFrame: 0)
        try player.playAudio()
        state = .playing
        return loaded
    }

    /// (Re)starts the fetch → decode → schedule pipeline at `frame`, from the segment that contains it.
    /// The leading frames of that first segment are trimmed so the seek lands on the requested position.
    private func startStreaming(atFrame frame: Int64) throws {
        guard let source = streamSource, let track else { return }
        let manifest = source.manifest
        let decoder = try source.makeDecoder()
        let fetch = source.fetch
        let scale = manifest.timescale == manifest.sampleRate ? 1.0 : Double(manifest.sampleRate) / Double(manifest.timescale)
        var index = 0
        var segmentStart: Int64 = 0
        for duration in manifest.segmentDurations {
            let frames = Int64(Double(duration) * scale)
            if segmentStart + frames > frame { break }
            segmentStart += frames
            index += 1
        }
        index = min(index, max(manifest.segmentCount - 1, 0))
        let skip = AVAudioFrameCount(max(min(frame - segmentStart, track.frames), 0))
        startFrame = segmentStart + Int64(skip)
        generation += 1
        let token = generation
        let inFlight = InFlightCounter()
        let numbers = Array(manifest.segmentNumbers).dropFirst(index)
        streamTask = Task { [weak self] in
            var trim = skip
            for number in numbers {
                while inFlight.value >= 3 { try? await Task.sleep(for: .milliseconds(100)) }
                guard !Task.isCancelled, let bytes = try? await fetch(manifest.mediaURL(number: number)),
                      let decoded = try? decoder.decode(segment: bytes), let self, self.generation == token else { return }
                let pcm = trim > 0 ? Self.dropping(trim, from: decoded) : decoded
                trim = 0
                guard let pcm else { continue }
                inFlight.increment()
                self.player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { _ in inFlight.decrement() }
            }
        }
    }

    private static func dropping(_ frames: AVAudioFrameCount, from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard frames < buffer.frameLength,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - frames) else { return nil }
        out.frameLength = buffer.frameLength - frames
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (from, to) in zip(src, dst) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData + Int(frames) * bytesPerFrame, Int(out.frameLength) * bytesPerFrame)
        }
        return out
    }

    public func seek(to seconds: Double) {
        if file == nil, streamSource != nil, let track {
            let wasPlaying = state == .playing
            streamTask?.cancel()
            player.stop()
            let frame = Int64(min(max(seconds, 0), track.duration) * track.sampleRate)
            try? startStreaming(atFrame: min(frame, max(track.frames - 1, 0)))
            if wasPlaying { try? player.playAudio() }
            return
        }
        guard let file else { return }
        let rate = file.processingFormat.sampleRate
        let frame = min(max(AVAudioFramePosition(seconds * rate), 0), file.length)
        let wasPlaying = state == .playing
        schedule(from: frame)
        if wasPlaying { try? player.playAudio() }
    }

    public var currentTime: Double {
        guard let track, track.sampleRate > 0 else { return 0 }
        let rate = track.sampleRate
        guard state != .idle,
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return min(Double(startFrame) / rate, track.duration) }
        return min(Double(startFrame + max(playerTime.sampleTime, 0)) / rate, track.duration)
    }

    /// Built outside the actor: the tap runs on a realtime audio queue, and a closure created in a
    /// `@MainActor` method inherits that isolation and trips libdispatch's queue assertion.
    private nonisolated static func meterBlock(_ meter: MeterTap) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in meter.process(buffer) }
    }

    public func setMetering(_ on: Bool) {
        guard on != isMetering else { return }
        isMetering = on
        let mixer = engine.mainMixerNode
        if on {
            try? mixer.__installTap(onBus: 0, bufferSize: 2048, format: nil, error: (), block: Self.meterBlock(meter))
        } else {
            mixer.removeTap(onBus: 0)
            meter.reset()
        }
    }

    public func restoreDeviceRate() {
        guard let original = originalDeviceRate, let device = OutputDevice.defaultOutput() else { return }
        try? device.setNominalSampleRate(original)
        originalDeviceRate = nil
    }

    /// Every (re)schedule bumps `generation`; completions from older generations (seek/stop) are ignored.
    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        generation += 1
        let token = generation
        player.stop()
        startFrame = frame
        isScheduled = false
        let remaining = AVAudioFrameCount(max(file.length - frame, 0))
        guard remaining > 0 else { return }
        isScheduled = true
        player.scheduleSegment(file, startingFrame: frame, frameCount: remaining, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(token) }
        }
    }

    private func segmentFinished(_ token: Int) {
        guard token == generation, state == .playing else { return }
        // Nothing is left queued: `schedule(from:)` stops the node before the next play, so no blocking stop() here.
        isScheduled = false
        startFrame = 0
        state = .idle
        onFinish?()
    }

    /// Device rate or route changed: rebuild the graph and continue from where we were.
    private func handleConfigurationChange() {
        guard let file else { return }
        let resumeAt = currentTime
        let wasPlaying = state == .playing
        engine.disconnectNodeOutput(player)
        try? engine.connectNode(player, to: engine.mainMixerNode, format: file.processingFormat)
        engine.prepare()
        if wasPlaying {
            try? engine.start()
            seek(to: resumeAt)
            try? player.playAudio()
        } else {
            startFrame = AVAudioFramePosition(resumeAt * file.processingFormat.sampleRate)
        }
    }
}

private final class InFlightCounter: Sendable {
    private let value_ = Mutex(0)
    var value: Int { value_.withLock { $0 } }
    func increment() { value_.withLock { $0 += 1 } }
    func decrement() { value_.withLock { $0 -= 1 } }
}
