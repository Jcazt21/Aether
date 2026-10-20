import Foundation
import Testing
@testable import TagKit

@Suite struct ID3FileIOTests {
    private let audio: [UInt8] = [0xFF, 0xFB, 0x90, 0x64] + Array(repeating: 0x11, count: 4000)

    private func mp3(with tag: ID3Tag?) throws -> URL {
        let url = Fixtures.tempURL("mp3")
        try Data((tag?.serialize(minimumSize: 0, padding: 512) ?? []) + audio).write(to: url)
        return url
    }

    @Test func writesNewV23TagOnUntaggedFile() throws {
        let url = try mp3(with: nil)
        try ID3FileIO.write(FlacTagsTests.sample, to: url)
        let (tag, _) = try ID3FileIO.readTag(url)
        #expect(tag?.majorVersion == 3)
        #expect(tag?.text("TYER") == "2026")
        #expect(tag?.text("TPUB") == "CircoLoco Records")
        #expect(tag?.text("TKEY") == "8A")
        let tags = try ID3FileIO.read(url)
        #expect(tags.title == "Dreams (Extended Mix)")
        #expect(tags.artwork == FlacTagsTests.sample.artwork)
        #expect(tags.year == "2026")
        #expect(Array(try Fixtures.bytes(url).suffix(audio.count)) == audio)
    }

    @Test func editsInPlaceWithinPaddingAndKeepsGEOB() throws {
        var existing = ID3Tag(majorVersion: 4)
        existing.setText("TIT2", "Old")
        existing.frames.append(ID3Frame(id: "GEOB", flags: 0, payload: Array(repeating: 7, count: 64)))
        let url = try mp3(with: existing)
        let sizeBefore = try Fixtures.bytes(url).count

        try ID3FileIO.write(TrackTags(title: "Comes and Goes", artist: "Kettama", year: "2019-05-01"), to: url)

        #expect(try Fixtures.bytes(url).count == sizeBefore)
        let (tag, _) = try ID3FileIO.readTag(url)
        #expect(tag?.majorVersion == 4)
        #expect(tag?.text("TDRC") == "2019-05-01")
        #expect(tag?.frames.contains { $0.id == "GEOB" } == true)
        #expect(try ID3FileIO.read(url).title == "Comes and Goes")
    }

    @Test func commentAndNumbers() throws {
        let url = try mp3(with: nil)
        try ID3FileIO.write(TrackTags(title: "T", comment: "warm-up", trackNumber: 3, discNumber: 2), to: url)
        let tags = try ID3FileIO.read(url)
        #expect(tags.comment == "warm-up")
        #expect(tags.trackNumber == 3)
        #expect(tags.discNumber == 2)
    }

    @Test func genreNumericPrefixIsStripped() {
        var tag = ID3Tag()
        tag.setText("TCON", "(18)Techno")
        #expect(TrackTags(id3: tag).genre == "Techno")
    }
}
