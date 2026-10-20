import FlacKit
import Foundation
import Harvester
import HiFiClient
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
        #expect(job.readout == "EN COLA")
        #expect(job.stage == .idle)

        job.phase = .downloading(segment: 30, of: 60, bytes: 20_000_000, bytesPerSecond: 6_100_000)
        #expect(job.stage == .transferring)
        #expect(job.transferFraction == 0.5)
        #expect(job.readout.contains("30/60"))
        #expect(job.readout.contains("6.1 MB/s"))

        job.phase = .verifying(0.62)
        #expect(job.stage == .verifying)
        #expect(job.transferFraction == 1)
        #expect(job.readout == "VERIFICANDO · MD5 62 %")

        let report = IntegrityReport(verdict: .verified, frames: 1, samples: 1, expectedSamples: nil,
                                     md5Expected: "ee68086136375cebd3f65e8ead407a1f", md5Actual: "ee68086136375cebd3f65e8ead407a1f", failure: nil)
        job.phase = .verified(HarvestResult(fileURL: URL(filePath: "/tmp/x.flac"), report: report,
                                            format: FormatSummary(sampleRate: 44_100, bitDepth: 24, channels: 2, duration: 236),
                                            bytes: 41_000_000, finishedAt: .now))
        #expect(job.status == .verified)
        #expect(job.readout == "FLAC · 24/44.1 · VERIFICADO ee68…7a1f")
        #expect(job.readoutTone == .signal)

        job.phase = .failed("Integridad: MD5 no coincide con la fuente")
        #expect(job.stage == .failed)
        #expect(job.readoutTone == .fault)
    }
}
