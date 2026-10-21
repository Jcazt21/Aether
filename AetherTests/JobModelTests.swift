import FlacKit
import Foundation
@testable import Harvester
import HiFiClient
import Observation
import os
import Testing
@testable import Aether

@MainActor
@Suite struct JobModelTests {
    private func job() throws -> JobModel {
        let track = try JSONDecoder().decode(TidalTrack.self, from: Data(#"{"id":1,"title":"Dreams","version":"Extended Mix","duration":236,"artist":{"id":1,"name":"Prospa"},"album":{"id":2,"title":"Free Your Mind"}}"#.utf8))
        return JobModel(request: HarvestRequest(track: track, destinationFolder: URL(filePath: "/tmp"), genre: nil, policy: .hiRes))
    }

    @Test func derivesPresentationFromPhase() throws {
        let job = try job()
        #expect(job.title == "Dreams (Extended Mix)")
        #expect(job.subtitle == "Prospa · Free Your Mind")
        #expect(job.readout == "QUEUED")
        #expect(job.stage == .idle)

        job.phase = .downloading(segment: 30, of: 60, bytes: 20_000_000, bytesPerSecond: 6_100_000)
        #expect(job.stage == .transferring)
        #expect(job.transferFraction == 0.5)
        #expect(job.readout.contains("30/60"))
        #expect(job.readout.contains("6.1 MB/s"))

        job.phase = .verifying(0.62)
        #expect(job.stage == .verifying)
        #expect(job.transferFraction == 1)
        #expect(job.readout == "VERIFYING · MD5 62 %")

        let report = IntegrityReport(verdict: .verified, frames: 1, samples: 1, expectedSamples: nil,
                                     md5Expected: "ee68086136375cebd3f65e8ead407a1f", md5Actual: "ee68086136375cebd3f65e8ead407a1f", failure: nil)
        job.phase = .verified(HarvestResult(fileURL: URL(filePath: "/tmp/x.flac"), report: report,
                                            format: FormatSummary(sampleRate: 44_100, bitDepth: 24, channels: 2, duration: 236),
                                            bytes: 41_000_000, finishedAt: .now))
        #expect(job.status == .verified)
        #expect(job.readout == "FLAC · 24/44.1 · VERIFIED ee68…7a1f")
        #expect(job.readoutTone == .signal)

        job.phase = .failed("Integridad: MD5 no coincide con la fuente")
        #expect(job.stage == .failed)
        #expect(job.readoutTone == .fault)
    }

    @Test func progressTicksDoNotInvalidateSummaryCounts() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = HarvesterStore(preferences: Preferences(defaults: defaults))
        let request = try job().request
        store.register([request])
        let model = try #require(store.jobs.first)
        #expect(store.activeCount == 1)
        #expect(store.failedCount == 0)
        #expect(!store.hasFinishedJobs)

        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.activeCount; _ = store.failedCount; _ = store.hasFinishedJobs
        } onChange: { invalidated.withLock { $0 = true } }

        await store.handle(HarvestEvent(id: request.id, phase: .downloading(segment: 5, of: 20, bytes: 512_000, bytesPerSecond: 1_000_000)))
        #expect(!invalidated.withLock { $0 })
        #expect(model.phase != .queued)

        await store.handle(HarvestEvent(id: request.id, phase: .failed("boom")))
        #expect(store.activeCount == 0)
        #expect(store.failedCount == 1)
        #expect(store.hasFinishedJobs)
    }

    @Test func albumCacheCoalescesConcurrentRequests() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let album = try JSONDecoder().decode(TidalAlbum.self, from: Data(#"{"id":42,"title":"Free Your Mind"}"#.utf8))
        let cache = AlbumCache { id in
            calls.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(40))
            return id == 42 ? album : nil
        }
        async let a = cache.album(42), b = cache.album(42), c = cache.album(42)
        let results = await [a, b, c]
        #expect(results.compactMap { $0 }.count == 3)
        #expect(calls.withLock { $0 } == 1)
    }
}
