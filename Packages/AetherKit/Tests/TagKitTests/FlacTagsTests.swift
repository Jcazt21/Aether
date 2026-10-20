import Foundation
import Testing
@testable import TagKit

@Suite struct FlacTagsTests {
    static let sample = TrackTags(
        title: "Dreams (Extended Mix)", artist: "Prospa, Rohan Pinnock-Hamilton", album: "Free Your Mind",
        albumArtist: "Prospa", genre: "UK House", comment: nil, label: "CircoLoco Records", key: "8A",
        isrc: "QM6MZ2647627", composer: nil, remixer: nil, year: "2026-06-12", bpm: 128,
        trackNumber: 11, discNumber: 1,
        artwork: .init(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), mimeType: "image/jpeg"))

    @Test func bpmFormatting() {
        #expect(TrackTags.formatBPM(128) == "128")
        #expect(TrackTags.formatBPM(124.5) == "124.50")
        #expect(TrackTags.leadingInt("3/12") == 3)
        #expect(TrackTags.leadingInt("x") == nil)
    }

    @Test func vorbisMappingWritesRekordboxKeys() {
        var v = VorbisComment()
        Self.sample.apply(to: &v)
        #expect(v.first("LABEL") == "CircoLoco Records")
        #expect(v.first("ORGANIZATION") == "CircoLoco Records")
        #expect(v.first("INITIALKEY") == "8A")
        #expect(v.first("BPM") == "128")
        #expect(v.first("DATE") == "2026-06-12")
        #expect(v.first("TRACKNUMBER") == "11")
        #expect(v.first("COMMENT") == nil)
    }

    @Test func fileRoundTripPreservesUnknownBlocksAndAudio() throws {
        let seek = FlacBlock(type: FlacBlockType.seekTable, payload: Array(repeating: 3, count: 18))
        var existing = VorbisComment(vendor: "libFLAC")
        existing.set("SERATO_MARKERS_V2", "opaque")
        existing.set("TITLE", "Old")
        let audio = Array(repeating: UInt8(0x5A), count: 2048)
        let url = try Fixtures.flacFile(
            blocks: [Fixtures.streamInfo.block, seek, FlacBlock(type: FlacBlockType.vorbisComment, payload: existing.payload)],
            audio: audio)

        try FlacTags.write(Self.sample, to: url, extraFields: ["AETHER_VERIFIED": "md5:00"])
        let (tags, si, header) = try FlacTags.read(url)

        #expect(tags == Self.sample)
        #expect(si == Fixtures.streamInfo)
        #expect(header.blocks.contains(seek))
        let vorbis = try VorbisComment(payload: header.blocks(ofType: FlacBlockType.vorbisComment)[0].payload)
        #expect(vorbis.vendor == "libFLAC")
        #expect(vorbis.first("SERATO_MARKERS_V2") == "opaque")
        #expect(vorbis.first("AETHER_VERIFIED") == "md5:00")
        #expect(Array(try Fixtures.bytes(url).suffix(audio.count)) == audio)
    }

    @Test func removingArtworkDropsOnlyFrontCover() throws {
        let back = FlacPicture(pictureType: 4, mimeType: "image/jpeg", data: [1, 2, 3])
        let front = FlacPicture(pictureType: 3, mimeType: "image/jpeg", data: [4, 5, 6])
        let url = try Fixtures.flacFile(blocks: [
            Fixtures.streamInfo.block,
            FlacBlock(type: FlacBlockType.picture, payload: back.payload),
            FlacBlock(type: FlacBlockType.picture, payload: front.payload),
        ])
        var tags = try FlacTags.read(url).tags
        #expect(tags.artwork?.data == Data([4, 5, 6]))
        tags.artwork = nil
        try FlacTags.write(tags, to: url)
        let header = try FlacTags.read(url).header
        let pictures = try header.blocks(ofType: FlacBlockType.picture).map { try FlacPicture(payload: $0.payload) }
        #expect(pictures == [back])
    }

    @Test func readsLegacyKeyNames() {
        let v = VorbisComment(fields: [.init(key: "ORGANIZATION", value: "Defected"), .init(key: "KEY", value: "Am"),
                                       .init(key: "YEAR", value: "2019"), .init(key: "BPM", value: "124,5")])
        let tags = TrackTags(vorbis: v, frontCover: nil)
        #expect(tags.label == "Defected")
        #expect(tags.key == "Am")
        #expect(tags.year == "2019")
        #expect(tags.bpm == 124.5)
    }
}
