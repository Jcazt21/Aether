import Foundation
import Testing
@testable import Aether

@MainActor
@Suite struct PlayerQueueTests {
    @Test func navigatesWithinBounds() {
        let urls = (1...3).map { URL(filePath: "/m/\($0).flac") }
        var q = PlayQueue(urls: urls, index: 1)
        #expect(q.current == urls[1])
        #expect(q.next() == urls[2])
        #expect(q.next() == nil)
        #expect(q.current == urls[2])
        #expect(q.previous() == urls[1])
        #expect(q.previous() == urls[0])
        #expect(q.previous() == nil)
    }

    @Test func signalSummary() {
        let s = SignalPath(sourceRate: 96_000, bitDepth: 24, deviceRate: 96_000, deviceName: "RME ADI-2", isBitPerfect: true)
        #expect(s.summary == "24/96 → RME ADI-2 · 96 kHz · BIT-PERFECT")
        let r = SignalPath(sourceRate: 44_100, bitDepth: 16, deviceRate: 48_000, deviceName: "MacBook Pro", isBitPerfect: false)
        #expect(r.summary == "16/44.1 → MacBook Pro · 48 kHz · REMUESTREADO")
    }
}
