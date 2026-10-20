import Foundation
import Testing
@testable import AetherCore
import TestSupport

@MainActor
@Suite(.enabled(if: OutputDevice.defaultOutput() != nil), .serialized)
struct PlaybackEngineTests {
    @Test func loadReportsFormat() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1, bits: 24)
        let engine = PlaybackEngine()
        engine.bitPerfect = false
        let track = try engine.load(url, bitDepth: 24)
        #expect(track.sampleRate == 44_100)
        #expect(track.channels == 2)
        #expect(track.frames == 44_100)
        #expect(engine.state == .paused)
        #expect(engine.currentTime == 0)
    }

    @Test func seekWhilePausedMovesTheClock() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2)
        let engine = PlaybackEngine()
        engine.bitPerfect = false
        _ = try engine.load(url, bitDepth: 16)
        engine.seek(to: 1.25)
        #expect(abs(engine.currentTime - 1.25) < 0.001)
        engine.seek(to: 99)
        #expect(engine.currentTime <= 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func playsToTheEndAndFiresOnFinishOnce() async throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 0.4)
        let engine = PlaybackEngine()
        engine.bitPerfect = false
        _ = try engine.load(url, bitDepth: 16)
        var finishes = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            engine.onFinish = { finishes += 1; done.resume() }
            try? engine.play()
        }
        #expect(finishes == 1)
        #expect(engine.state == .idle)
    }

    @Test func seekDuringPlaybackDoesNotFireFinish() async throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 3)
        let engine = PlaybackEngine()
        engine.bitPerfect = false
        _ = try engine.load(url, bitDepth: 16)
        var finished = false
        engine.onFinish = { finished = true }
        try engine.play()
        engine.seek(to: 1)
        engine.seek(to: 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!finished)
        #expect(engine.currentTime >= 2)
        engine.stop()
    }
}
