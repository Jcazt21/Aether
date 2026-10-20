import Testing
@testable import FlacKit
import TagKit

@Suite struct FMP4FlacTests {
    static let si = StreamInfo(minBlockSize: 4096, maxBlockSize: 4096, minFrameSize: 0, maxFrameSize: 0,
                               sampleRate: 44_100, channels: 2, bitsPerSample: 24, totalSamples: 10_418_594,
                               md5: Array(repeating: 0xEE, count: 16))

    @Test func findsNestedBoxesIncludingSampleEntryChildren() throws {
        let bytes = MP4Fixture.initSegment(streamInfo: Self.si)
        let dfLa = try #require(try MP4.find(["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"], in: bytes))
        #expect(dfLa.payload.count == 4 + 4 + 34)
    }

    @Test func parsesLargeSizeBoxes() throws {
        let payload: [UInt8] = [1, 2, 3]
        let bytes = MP4Fixture.be32(1) + Array("free".utf8) + [0, 0, 0, 0, 0, 0, 0, 19] + payload
        let boxes = try MP4.children(of: bytes, in: 0..<bytes.count)
        #expect(boxes == [MP4Box(type: "free", start: 0, payload: 16..<19)])
    }

    @Test func truncatedBoxThrows() {
        let bytes = MP4Fixture.be32(50) + Array("moov".utf8)
        #expect(throws: MP4Error.truncated) { try MP4.children(of: bytes, in: 0..<bytes.count) }
    }

    @Test func initYieldsStreamInfo() throws {
        let config = try FMP4Flac.parseInit(MP4Fixture.initSegment(streamInfo: Self.si))
        #expect(config.streamInfo == Self.si)
        #expect(config.metadataBlocks == [Self.si.block])
    }

    @Test func mediaSegmentYieldsFrameBytesAndSamples() throws {
        let frames: [[UInt8]] = [[0xFF, 0xF8, 1, 2], [0xFF, 0xF8, 3], [0xFF, 0xF8, 4, 5, 6]]
        let segment = MP4Fixture.mediaSegment(frames: frames)
        let parsed = try FMP4Flac.parseMediaSegment(segment)
        #expect(parsed.sampleCount == 3)
        #expect(parsed.samples == 3 * 4096)
        #expect(parsed.byteCount == 12)
        #expect(parsed.frameRanges.flatMap { Array(segment[$0]) } == frames.flatMap { $0 })
    }

    @Test func sizeMismatchIsAnError() {
        let segment = MP4Fixture.mediaSegment(frames: [[0xFF, 0xF8, 1, 2]], sizeOverride: 9)
        #expect(throws: MP4Error.segmentSizeMismatch(expected: 9, actual: 4)) { try FMP4Flac.parseMediaSegment(segment) }
    }
}
