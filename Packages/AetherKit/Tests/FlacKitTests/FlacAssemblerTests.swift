import Foundation
import Testing
@testable import FlacKit
import TagKit
import TestSupport

@Suite struct FlacAssemblerTests {
    private let header = [FMP4FlacTests.si.block, FlacBlock.padding(64)]
    private let seg1 = MP4Fixture.mediaSegment(frames: [[0xFF, 0xF8, 1], [0xFF, 0xF8, 2]])
    private let seg2 = MP4Fixture.mediaSegment(frames: [[0xFF, 0xF8, 3, 3]])

    private func partURL() -> URL { FileManager.default.temporaryDirectory.appending(path: ".a-\(UUID().uuidString).aether-part") }

    @Test func writesHeaderThenFramesInOrder() throws {
        let url = partURL()
        let assembler = try FlacAssembler(partURL: url, headerBlocks: header)
        _ = try assembler.append(segment: seg1)
        _ = try assembler.append(segment: seg2)
        #expect(assembler.checkpoint.samplesWritten == 3 * 4096)
        #expect(assembler.checkpoint.segmentsWritten == 2)
        try assembler.finish()
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(bytes == (try FlacMetadataIO.serialize(header)) + [0xFF, 0xF8, 1, 0xFF, 0xF8, 2, 0xFF, 0xF8, 3, 3])
    }

    @Test func resumesFromCheckpointDiscardingPartialTail() throws {
        let url = partURL()
        let first = try FlacAssembler(partURL: url, headerBlocks: header)
        _ = try first.append(segment: seg1)
        let checkpoint = first.checkpoint
        _ = try first.append(segment: seg2)   // simulate a crash after a partial write…
        try first.finish()
        let handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: [0xDE, 0xAD])   // …with garbage past the checkpoint
        try handle.close()

        let resumed = try FlacAssembler(resuming: url, from: checkpoint)
        _ = try resumed.append(segment: seg2)
        try resumed.finish()
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(bytes == (try FlacMetadataIO.serialize(header)) + [0xFF, 0xF8, 1, 0xFF, 0xF8, 2, 0xFF, 0xF8, 3, 3])
        #expect(resumed.checkpoint.segmentsWritten == 2)
    }
}
