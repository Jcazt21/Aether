import CryptoKit
import Foundation
import Testing
@testable import FlacKit
import TagKit

@Suite struct IntegrityVerifierTests {
    /// Writes the reference MD5 (of the PCM we generated) into STREAMINFO, like Tidal's dfLa provides.
    private func sealedFixture(bits: Int = 24) throws -> (URL, [UInt8]) {
        let (url, pcm) = try AudioFixture.makeFLAC(seconds: 3, bits: bits)
        var header = try FlacMetadataIO.read(url)
        var si = try header.streamInfo()
        si.md5 = Array(Insecure.MD5.hash(data: pcm))
        header.blocks[0] = si.block
        try FlacMetadataIO.write(header.blocks, to: url)
        return (url, pcm)
    }

    @Test func verifiedWhenMD5MatchesSource() throws {
        let (url, pcm) = try sealedFixture()
        let report = try IntegrityVerifier.verify(flacAt: url, expectedSamples: UInt64(pcm.count / 6))
        #expect(report.verdict == .verified)
        #expect(report.isPass)
        #expect(report.md5Actual == report.md5Expected)
        #expect(report.failure == nil)
    }

    @Test func failsOnWrongReferenceMD5() throws {
        let (url, _) = try sealedFixture()
        var header = try FlacMetadataIO.read(url)
        var si = try header.streamInfo()
        si.md5[0] ^= 0xFF
        header.blocks[0] = si.block
        try FlacMetadataIO.write(header.blocks, to: url)
        let report = try IntegrityVerifier.verify(flacAt: url)
        #expect(report.verdict == .failed)
        #expect(report.failure == "MD5 no coincide con la fuente")
    }

    @Test func failsOnSampleCountMismatchBeforeDecoding() throws {
        let (url, pcm) = try sealedFixture()
        let report = try IntegrityVerifier.verify(flacAt: url, expectedSamples: UInt64(pcm.count / 6) + 1)
        #expect(report.verdict == .failed)
        #expect(report.md5Actual == nil)
        #expect(report.failure?.hasPrefix("Muestras") == true)
    }

    @Test func noReferenceWhenStreamInfoMD5IsZero() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1)
        var header = try FlacMetadataIO.read(url)
        var si = try header.streamInfo()
        si.md5 = Array(repeating: 0, count: 16)
        header.blocks[0] = si.block
        try FlacMetadataIO.write(header.blocks, to: url)
        #expect(try IntegrityVerifier.verify(flacAt: url).verdict == .verifiedNoReference)
    }

    @Test func verifiedFieldValueFormat() {
        let report = IntegrityReport(verdict: .verified, frames: 1, samples: 1, expectedSamples: nil,
                                     md5Expected: "ab", md5Actual: "ab", failure: nil)
        let value = IntegrityVerifier.verifiedFieldValue(report, at: Date(timeIntervalSince1970: 0))
        #expect(value == "md5:ab;1970-01-01T00:00:00Z")
    }

    /// Full offline rehearsal of Harvester's path: split a real FLAC into DASH-like segments,
    /// reassemble through FMP4Flac + FlacAssembler, then verify against the source MD5.
    @Test func dashRoundTripIsBitPerfect() throws {
        let (source, pcm) = try sealedFixture()
        let sourceBytes = [UInt8](try Data(contentsOf: source))
        let header = try FlacMetadataIO.read(source)
        let si = try header.streamInfo()
        let scan = try FlacFrameScanner.scan(fileAt: source, collectOffsets: true)
        let offsets = scan.frameOffsets! + [sourceBytes.count]
        let frames = (0..<scan.frames).map { Array(sourceBytes[offsets[$0]..<offsets[$0 + 1]]) }

        let config = try FMP4Flac.parseInit(MP4Fixture.initSegment(streamInfo: si))
        let part = FileManager.default.temporaryDirectory.appending(path: ".e2e-\(UUID().uuidString).aether-part")
        let assembler = try FlacAssembler(partURL: part, headerBlocks: config.metadataBlocks + [.padding(8192)])
        let block = UInt32(si.maxBlockSize)
        let tail = UInt32(si.totalSamples - UInt64(frames.count - 1) * UInt64(block))
        // Segments of 43 frames like Tidal; the stream's last frame is shorter, so it gets its own fragment.
        let body = Array(frames.dropLast())
        var start = 0
        while start < body.count {
            let chunk = Array(body[start..<min(start + 43, body.count)])
            try assembler.append(segment: MP4Fixture.mediaSegment(frames: chunk, duration: block))
            start += 43
        }
        try assembler.append(segment: MP4Fixture.mediaSegment(frames: [frames.last!], duration: tail))
        #expect(assembler.checkpoint.samplesWritten == si.totalSamples)
        try assembler.finish()

        let report = try IntegrityVerifier.verify(flacAt: part, expectedSamples: UInt64(pcm.count / 6))
        #expect(report.verdict == .verified)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AETHER_SPIKE_FLAC"] != nil))
    func realTidalFileMeetsBudget() throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["AETHER_SPIKE_FLAC"]!)
        let clock = ContinuousClock()
        var report: IntegrityReport?
        let elapsed = try clock.measure { report = try IntegrityVerifier.verify(flacAt: url) }
        #expect(report?.verdict == .verified)
        #expect(elapsed < .milliseconds(1500))
    }
}
