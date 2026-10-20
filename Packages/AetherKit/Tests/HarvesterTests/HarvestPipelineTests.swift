import FlacKit
import Foundation
import HiFiClient
import TagKit
import Testing
@testable import Harvester
import TestSupport

@Suite struct HarvestPipelineTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "harvest-\(UUID().uuidString)/UK House")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pipeline(_ fake: FakeTidal) -> HarvestPipeline {
        let client = fake.client
        return HarvestPipeline(
            client: client,
            fetcher: SegmentFetcher(session: StubURLProtocol.session(), backoff: { _ in .milliseconds(1) }),
            albumLookup: { id in try? await client.album(id: id).album },
            now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func downloadsTagsAndVerifiesBitPerfect() async throws {
        let fake = try FakeTidal()
        let dest = try folder()
        let request = HarvestRequest(track: try FakeTidal.track(), destinationFolder: dest, genre: "UK House", policy: .hiResCapped96)
        let phases = Recorder<HarvestPhase>()
        let result = try await pipeline(fake).execute(request) { phases.append($0) }

        #expect(result.fileURL.lastPathComponent == "Fixture - Tone (Original Mix).flac")
        #expect(result.report.verdict == .verified)
        #expect(result.format == FormatSummary(sampleRate: 44_100, bitDepth: 24, channels: 2, duration: Double(fake.expectedSamples) / 44_100))
        let (tags, si, header) = try FlacTags.read(result.fileURL)
        #expect(si.totalSamples == fake.expectedSamples)
        #expect(tags.genre == "UK House")
        #expect(tags.label == "Test Records")
        #expect(tags.artwork?.data == Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let vorbis = try VorbisComment(payload: header.blocks(ofType: FlacBlockType.vorbisComment)[0].payload)
        #expect(vorbis.first("AETHER_VERIFIED") == "md5:\(si.md5Hex);1970-01-01T00:00:00Z")
        #expect(vorbis.first("REPLAYGAIN_TRACK_GAIN") == "-9.50 dB")
        #expect(try IntegrityVerifier.verify(flacAt: result.fileURL).verdict == .verified)

        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        #expect(names == ["Fixture - Tone (Original Mix).flac"])
        let recorded = phases.values
        #expect(recorded.first == .resolving)
        #expect(recorded.contains { if case .downloading = $0 { true } else { false } })
        #expect(recorded.contains { if case .verifying = $0 { true } else { false } })
    }

    @Test func expiredSignatureRefreshesManifestAndContinues() async throws {
        let fake = try FakeTidal(expireSegmentOnce: 2)
        let request = HarvestRequest(track: try FakeTidal.track(), destinationFolder: try folder(), genre: nil, policy: .hiRes)
        let result = try await pipeline(fake).execute(request) { _ in }
        #expect(result.report.verdict == .verified)
        #expect(fake.manifestRequestCount == 2)
    }

    @Test func corruptedSegmentFailsIntegrityAndLeavesNoFiles() async throws {
        let fake = try FakeTidal(corruptSegment: 1)
        let dest = try folder()
        let request = HarvestRequest(track: try FakeTidal.track(), destinationFolder: dest, genre: nil, policy: .hiRes)
        await #expect(throws: HarvestError.self) { try await pipeline(fake).execute(request) { _ in } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    @Test func capPolicyDowngradesAbove96k() async throws {
        let fake = try FakeTidal(reportedSampleRate: 192_000)
        let request = HarvestRequest(track: try FakeTidal.track(), destinationFolder: try folder(), genre: nil, policy: .hiResCapped96)
        _ = try await pipeline(fake).execute(request) { _ in }
        #expect(fake.manifestRequestCount == 2)  // HI_RES then LOSSLESS
    }

    @Test func throttleLimitsEmissionRate() {
        var throttle = ProgressThrottle(interval: .milliseconds(100))
        let t0 = ContinuousClock.now
        #expect(throttle.shouldEmit(now: t0) == true)
        #expect(throttle.shouldEmit(now: t0.advanced(by: .milliseconds(50))) == false)
        #expect(throttle.shouldEmit(now: t0.advanced(by: .milliseconds(120))) == true)
    }
}
