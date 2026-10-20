import Accelerate
public import AVFAudio
import Synchronization

/// Written on the audio render thread, read by the UI at ≤ 30 Hz. One small lock, no allocation per read.
public final class MeterTap: Sendable {
    public struct Levels: Equatable, Sendable {
        public var peak: [Float]
        public var rms: [Float]
        public static let silent = Levels(peak: [0, 0], rms: [0, 0])
    }

    private let state = Mutex(Levels.silent)

    public init() {}

    public var current: Levels { state.withLock { $0 } }

    public func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frames = vDSP_Length(buffer.frameLength)
        var peaks = [Float](repeating: 0, count: channels)
        var rms = [Float](repeating: 0, count: channels)
        for ch in 0..<channels {
            vDSP_maxmgv(data[ch], 1, &peaks[ch], frames)
            vDSP_rmsqv(data[ch], 1, &rms[ch], frames)
        }
        state.withLock { levels in
            if levels.peak.count != channels { levels = Levels(peak: peaks, rms: rms); return }
            for ch in 0..<channels { levels.peak[ch] = max(peaks[ch], levels.peak[ch] * 0.85) }
            levels.rms = rms
        }
    }

    public func reset() { state.withLock { $0 = .silent } }
}
