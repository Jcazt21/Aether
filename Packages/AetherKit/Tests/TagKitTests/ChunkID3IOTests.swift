import Foundation
import Testing
@testable import TagKit

@Suite struct ChunkID3IOTests {
    private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] { le32(v).reversed() }

    private func wav(extraChunks: [UInt8] = []) throws -> URL {
        let fmt = Array("fmt ".utf8) + le32(16) + [1, 0, 2, 0] + le32(44_100) + le32(176_400) + [4, 0, 16, 0]
        let data = Array("data".utf8) + le32(8) + [1, 2, 3, 4, 5, 6, 7, 8]
        let body = Array("WAVE".utf8) + fmt + data + extraChunks
        let url = Fixtures.tempURL("wav")
        try Data(Array("RIFF".utf8) + le32(body.count) + body).write(to: url)
        return url
    }

    private func aiff() throws -> URL {
        let comm = Array("COMM".utf8) + be32(18) + [0, 2, 0, 0, 0, 2, 0, 16, 0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]
        let ssnd = Array("SSND".utf8) + be32(16) + [0, 0, 0, 0, 0, 0, 0, 0, 9, 9, 9, 9, 9, 9, 9, 9]
        let body = Array("AIFF".utf8) + comm + ssnd
        let url = Fixtures.tempURL("aiff")
        try Data(Array("FORM".utf8) + be32(body.count) + body).write(to: url)
        return url
    }

    private func containerSize(_ bytes: [UInt8], littleEndian: Bool) -> Int {
        let s = Array(bytes[4..<8])
        return littleEndian ? s.reversed().reduce(0) { $0 << 8 | Int($1) } : s.reduce(0) { $0 << 8 | Int($1) }
    }

    @Test func wavRoundTripAndSizeField() throws {
        let url = try wav()
        try ChunkID3IO.write(TrackTags(title: "b2b sept", artist: "Jean"), to: url)
        let bytes = try Fixtures.bytes(url)
        #expect(containerSize(bytes, littleEndian: true) == bytes.count - 8)
        #expect(try ChunkID3IO.read(url).title == "b2b sept")
        try ChunkID3IO.write(TrackTags(title: "renamed", artist: "Jean"), to: url)
        let again = try Fixtures.bytes(url)
        #expect(containerSize(again, littleEndian: true) == again.count - 8)
        #expect(try ChunkID3IO.read(url).title == "renamed")
        let occurrences = again.indices.dropLast(3).filter { Array(again[$0..<($0 + 4)]) == Array("id3 ".utf8) }
        #expect(occurrences.count == 1)
        let dataRange = again.firstRange(of: Array("data".utf8))!
        #expect(Array(again[(dataRange.upperBound + 4)..<(dataRange.upperBound + 12)]) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func wavWithID3InTheMiddleIsRewritten() throws {
        var middle = ID3Tag()
        middle.setText("TIT2", "old")
        let tagBytes = middle.serialize(minimumSize: 0, padding: 0)
        let chunk = Array("id3 ".utf8) + le32(tagBytes.count) + tagBytes + (tagBytes.count % 2 == 1 ? [0] : [])
        let trailer = Array("LIST".utf8) + le32(4) + Array("INFO".utf8)
        let url = try wav(extraChunks: chunk + trailer)
        try ChunkID3IO.write(TrackTags(title: "new"), to: url)
        let bytes = try Fixtures.bytes(url)
        #expect(containerSize(bytes, littleEndian: true) == bytes.count - 8)
        #expect(try ChunkID3IO.read(url).title == "new")
        #expect(bytes.firstRange(of: Array("LIST".utf8)) != nil)
    }

    @Test func aiffRoundTrip() throws {
        let url = try aiff()
        try ChunkID3IO.write(TrackTags(title: "Feel", artist: "Franky Rizardo", bpm: 124), to: url)
        let bytes = try Fixtures.bytes(url)
        #expect(containerSize(bytes, littleEndian: false) == bytes.count - 8)
        let tags = try ChunkID3IO.read(url)
        #expect(tags.artist == "Franky Rizardo")
        #expect(tags.bpm == 124)
    }

    @Test func rejectsOtherFiles() throws {
        let url = Fixtures.tempURL("wav")
        try Data("fLaC".utf8).write(to: url)
        #expect(throws: ChunkError.notChunked) { try ChunkID3IO.read(url) }
    }
}
