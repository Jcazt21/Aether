import Foundation
import Testing
@testable import Harvester
import TestSupport

@Suite struct HarvestEngineTests {
    private func engine(_ fake: FakeTidal, max: Int = 2) -> HarvestEngine {
        let client = fake.client
        let pipeline = HarvestPipeline(client: client,
                                       fetcher: SegmentFetcher(session: StubURLProtocol.session(), backoff: { _ in .milliseconds(1) }),
                                       albumLookup: { _ in nil })
        return HarvestEngine(pipeline: pipeline, checkpoints: nil, maxConcurrent: max)
    }

    private func requests(_ n: Int) throws -> [HarvestRequest] {
        let dest = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID().uuidString)")
        return try (0..<n).map { _ in HarvestRequest(track: try FakeTidal.track(), destinationFolder: dest, genre: nil, policy: .hiRes) }
    }

    @Test func runsAllJobsToVerifiedWithBoundedConcurrency() async throws {
        let fake = try FakeTidal(seconds: 1)
        let engine = engine(fake, max: 2)
        let reqs = try requests(4)
        await engine.enqueue(reqs)
        var verified = Set<UUID>()
        var maxActive = 0
        for await event in engine.events {
            maxActive = max(maxActive, await engine.activeCount)
            if case .verified = event.phase { verified.insert(event.id) }
            if verified.count == reqs.count { break }
        }
        #expect(verified == Set(reqs.map(\.id)))
        #expect(maxActive <= 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: reqs[0].destinationFolder.path)
        #expect(Set(files) == ["Fixture - Tone (Original Mix).flac", "Fixture - Tone (Original Mix) (2).flac",
                               "Fixture - Tone (Original Mix) (3).flac", "Fixture - Tone (Original Mix) (4).flac"])
    }

    @Test func cancelEmitsCancelledAndRemovesFromPending() async throws {
        let fake = try FakeTidal(seconds: 2)
        let engine = engine(fake, max: 1)
        let reqs = try requests(2)
        await engine.enqueue(reqs)
        await engine.cancel(reqs[1].id)
        var cancelled = false
        for await event in engine.events where event.id == reqs[1].id {
            if event.phase == .cancelled { cancelled = true; break }
        }
        #expect(cancelled)
        #expect(await engine.pendingRequests.map(\.id).contains(reqs[1].id) == false)
    }

    @Test func integrityFailureRetriesOnceThenFails() async throws {
        let fake = try FakeTidal(seconds: 1, corruptSegment: 1)
        let engine = engine(fake)
        let req = try requests(1)
        await engine.enqueue(req)
        var resolvingCount = 0
        for await event in engine.events {
            if event.phase == .resolving { resolvingCount += 1 }
            if case .failed(let message) = event.phase {
                #expect(!message.isEmpty)
                break
            }
        }
        #expect(resolvingCount == 2)
    }
}
