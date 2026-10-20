import AVFAudio
import Foundation
import Testing
@testable import AetherCore
import TestSupport

@Suite struct MeterAndWaveformTests {
    private func buffer(value: Float, frames: AVAudioFrameCount = 1024) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        for ch in 0..<2 { for i in 0..<Int(frames) { b.floatChannelData![ch][i] = (i % 2 == 0 ? value : -value) * (ch == 0 ? 1 : 0.5) } }
        return b
    }

    @Test func meterTracksPeakAndRMSWithDecay() {
        let meter = MeterTap()
        meter.process(buffer(value: 0.8))
        let first = meter.current
        #expect(abs(first.peak[0] - 0.8) < 0.0001)
        #expect(abs(first.peak[1] - 0.4) < 0.0001)
        #expect(abs(first.rms[0] - 0.8) < 0.0001)
        meter.process(buffer(value: 0))
        #expect(abs(meter.current.peak[0] - 0.8 * 0.85) < 0.0001)
        meter.reset()
        #expect(meter.current == .silent)
    }

    @Test func waveformPeaksFollowSignalAmplitude() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1)
        let peaks = try WaveformAnalyzer.peaks(for: url, bins: 100)
        #expect(peaks.count == 100)
        #expect(peaks.allSatisfy { $0 > 0.5 && $0 <= 0.61 })   // fixture amplitude = 0.6 FS
    }
}
