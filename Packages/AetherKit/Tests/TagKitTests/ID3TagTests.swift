import Testing
@testable import TagKit

@Suite struct ID3TagTests {
    @Test func textCodecLatin1AndUTF16() {
        #expect(ID3Text.encode("Prospa") == [0] + Array("Prospa".utf8))
        let encoded = ID3Text.encode("Rosalía ✓")
        #expect(encoded.prefix(3) == [1, 0xFF, 0xFE])
        #expect(ID3Text.decode(encoded) == ["Rosalía ✓"])
        #expect(ID3Text.decode([3] + Array("a".utf8) + [0] + Array("b".utf8)) == ["a", "b"])
        #expect(ID3Text.decode([2, 0x00, 0x41]) == ["A"])
    }

    @Test func v23RoundTripKeepsUnknownFramesAndPads() throws {
        var tag = ID3Tag(majorVersion: 3)
        tag.setText("TIT2", "Feel")
        tag.frames.append(ID3Frame(id: "GEOB", flags: 0, payload: [9, 9, 9]))
        let bytes = tag.serialize(minimumSize: 0, padding: 100)
        #expect(ID3Tag.declaredSize(header: Array(bytes.prefix(10))) == bytes.count)
        let parsed = try ID3Tag.parse(bytes)
        #expect(parsed.majorVersion == 3)
        #expect(parsed.text("TIT2") == "Feel")
        #expect(parsed.frames.contains(ID3Frame(id: "GEOB", flags: 0, payload: [9, 9, 9])))
    }

    @Test func serializeFillsMinimumSizeExactly() throws {
        var tag = ID3Tag(majorVersion: 4)
        tag.setText("TPE1", "Kettama")
        let bytes = tag.serialize(minimumSize: 500)
        #expect(bytes.count == 500)
        #expect(try ID3Tag.parse(bytes).text("TPE1") == "Kettama")
    }

    @Test func v24UsesSyncsafeFrameSizes() throws {
        var tag = ID3Tag(majorVersion: 4)
        tag.setText("TIT2", String(repeating: "x", count: 200))
        let bytes = tag.serialize(minimumSize: 0, padding: 0)
        // Frame size 201 as syncsafe = 0x00 0x00 0x01 0x49
        #expect(Array(bytes[14..<18]) == [0x00, 0x00, 0x01, 0x49])
        #expect(try ID3Tag.parse(bytes).text("TIT2")?.count == 200)
    }

    @Test func setTextKeepsPositionAndRemovesOnNil() {
        var tag = ID3Tag(frames: [ID3Frame(id: "TPE1", flags: 0, payload: ID3Text.encode("A")),
                                  ID3Frame(id: "TIT2", flags: 0, payload: ID3Text.encode("B"))])
        tag.setText("TPE1", "C")
        #expect(tag.frames.map(\.id) == ["TPE1", "TIT2"])
        tag.setText("TPE1", nil)
        #expect(tag.frames.map(\.id) == ["TIT2"])
    }

    @Test func rejectsID3v22() {
        let bytes: [UInt8] = Array("ID3".utf8) + [2, 0, 0, 0, 0, 0, 0]
        #expect(throws: ID3Error.unsupportedVersion(2)) { try ID3Tag.parse(bytes) }
    }

    @Test func undoesTagLevelUnsynchronisation() throws {
        // v2.3 tag with unsync flag; frame payload [0, FF, 00, E0] must decode to [0, FF, E0].
        let framePayload: [UInt8] = [0x00, 0xFF, 0x00, 0xE0]
        let frame: [UInt8] = Array("TXXX".utf8) + [0, 0, 0, 3] + [0, 0] + framePayload
        let bytes: [UInt8] = Array("ID3".utf8) + [3, 0, 0x80, 0, 0, 0, UInt8(frame.count)] + frame
        let parsed = try ID3Tag.parse(bytes)
        #expect(parsed.frames.first?.payload == [0x00, 0xFF, 0xE0])
    }
}
