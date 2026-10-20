import Foundation
import Testing
@testable import TagKit

@Suite struct FlacMetadataIOTests {
    @Test func streamInfoRoundTrip() throws {
        let si = Fixtures.streamInfo
        #expect(si.payload.count == 34)
        let parsed = try StreamInfo(payload: si.payload)
        #expect(parsed == si)
        #expect(parsed.duration == 10_418_594.0 / 96_000.0)
        #expect(parsed.md5Hex == "000102030405060708090a0b0c0d0e0f")
        #expect(parsed.hasMD5)
    }

    @Test func parsesTidalStreamInfoBytes() throws {
        // STREAMINFO captured from a Tidal init segment (2026-10-20): 44.1 kHz, 2 ch, 24 bit, 10_418_594 samples.
        let payload: [UInt8] = [0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                0x0A, 0xC4, 0x43, 0x70, 0x00, 0x9E, 0xF9, 0xA2,
                                0xEE, 0x68, 0x08, 0x61, 0x36, 0x37, 0x5C, 0xEB, 0xD3, 0xF6, 0x5E, 0x8E, 0xAD, 0x40, 0x7A, 0x1F]
        let si = try StreamInfo(payload: payload)
        #expect(si.sampleRate == 44_100)
        #expect(si.channels == 2)
        #expect(si.bitsPerSample == 24)
        #expect(si.totalSamples == 10_418_594)
        #expect(si.md5Hex == "ee68086136375cebd3f65e8ead407a1f")
    }

    @Test func readsHeaderAndAudioOffset() throws {
        let blocks = [Fixtures.streamInfo.block, FlacBlock(type: FlacBlockType.seekTable, payload: [1, 2, 3]), .padding(100)]
        let url = try Fixtures.flacFile(blocks: blocks)
        let header = try FlacMetadataIO.read(url)
        #expect(header.blocks == blocks)
        #expect(header.audioOffset == 4 + (4 + 34) + (4 + 3) + (4 + 100))
        #expect(try header.streamInfo() == Fixtures.streamInfo)
    }

    @Test func rejectsNonFlac() throws {
        let url = Fixtures.tempURL("flac")
        try Data("RIFF0000WAVE".utf8).write(to: url)
        #expect(throws: FlacError.notFlac) { try FlacMetadataIO.read(url) }
    }

    @Test func skipsLeadingID3() throws {
        let flac = try FlacMetadataIO.serialize([Fixtures.streamInfo.block]) + [0xFF, 0xF8]
        let id3: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0, 0, 0, 5] + [0, 0, 0, 0, 0]
        let header = try FlacMetadataIO.parse(id3 + flac)
        #expect(header.audioOffset == id3.count + 4 + 4 + 34)
    }

    @Test func layoutReusesRegionWithPadding() {
        let blocks = [Fixtures.streamInfo.block]
        let exact = FlacMetadataIO.layout(blocks, regionLength: 4 + 38, padding: 8192)
        #expect(exact == blocks)
        let padded = FlacMetadataIO.layout(blocks, regionLength: 4 + 38 + 50, padding: 8192)
        #expect(padded.last == .padding(46))
        let tooSmall = FlacMetadataIO.layout(blocks + [FlacBlock(type: 4, payload: Array(repeating: 1, count: 100))], regionLength: 60, padding: 8192)
        #expect(tooSmall.last == .padding(8192))
        let gapOfThree = FlacMetadataIO.layout(blocks, regionLength: 4 + 38 + 3, padding: 8192)
        #expect(gapOfThree.last == .padding(8192))
    }

    @Test func writeInPlaceWhenPaddingSuffices() throws {
        let audio = Array(repeating: UInt8(0xAB), count: 10_000)
        let url = try Fixtures.flacFile(blocks: [Fixtures.streamInfo.block, .padding(1000)], audio: audio)
        let sizeBefore = try Fixtures.bytes(url).count
        try FlacMetadataIO.write([Fixtures.streamInfo.block, FlacBlock(type: 4, payload: Array(repeating: 7, count: 300))], to: url)
        let after = try Fixtures.bytes(url)
        #expect(after.count == sizeBefore)
        #expect(Array(after.suffix(audio.count)) == audio)
        let header = try FlacMetadataIO.read(url)
        #expect(header.blocks.count == 3)
        #expect(header.blocks[2] == .padding(1000 - 300 - 4))
    }

    @Test func writeGrowsFileWhenNeeded() throws {
        let audio = Array(repeating: UInt8(0xCD), count: 5000)
        let url = try Fixtures.flacFile(blocks: [Fixtures.streamInfo.block], audio: audio)
        let big = FlacBlock(type: FlacBlockType.picture, payload: Array(repeating: 9, count: 20_000))
        try FlacMetadataIO.write([Fixtures.streamInfo.block, big], to: url)
        let header = try FlacMetadataIO.read(url)
        #expect(header.blocks == [Fixtures.streamInfo.block, big, .padding(8192)])
        #expect(Array(try Fixtures.bytes(url).suffix(audio.count)) == audio)
    }

    @Test func writeRequiresStreamInfoFirst() throws {
        let url = try Fixtures.flacFile(blocks: [Fixtures.streamInfo.block])
        #expect(throws: FlacError.missingStreamInfo) {
            try FlacMetadataIO.write([.padding(10)], to: url)
        }
    }
}
