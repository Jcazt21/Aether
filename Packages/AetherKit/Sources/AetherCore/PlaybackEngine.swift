@preconcurrency import AVFAudio
public import Foundation
import OSLog

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
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        startFrame = 0
        state = .paused
        return loaded
    }

    public func play() throws {
        guard file != nil, state != .playing else { return }
        if !engine.isRunning { try engine.start() }
        if !isScheduled { schedule(from: startFrame) }
        player.play()
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
        player.stop()
        isScheduled = false
        startFrame = 0
        if state != .idle { state = file == nil ? .idle : .paused }
    }

    public func seek(to seconds: Double) {
        guard let file else { return }
        let rate = file.processingFormat.sampleRate
        let frame = min(max(AVAudioFramePosition(seconds * rate), 0), file.length)
        let wasPlaying = state == .playing
        schedule(from: frame)
        if wasPlaying { player.play() }
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

    public func setMetering(_ on: Bool) {
        guard on != isMetering else { return }
        isMetering = on
        let mixer = engine.mainMixerNode
        if on {
            let meter = meter
            mixer.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in meter.process(buffer) }
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
        player.stop()
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
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        engine.prepare()
        if wasPlaying {
            try? engine.start()
            seek(to: resumeAt)
            player.play()
        } else {
            startFrame = AVAudioFramePosition(resumeAt * file.processingFormat.sampleRate)
        }
    }
}
