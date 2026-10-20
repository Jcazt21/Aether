import Foundation
import Testing
@testable import TagKit

@Suite struct VorbisPictureTests {
    @Test func vorbisRoundTripIsCaseInsensitive() throws {
        var v = VorbisComment(vendor: "reference libFLAC 1.4.3")
        v.set("title", "Dreams")
        v.set("ARTIST", ["Prospa", "Rohan Pinnock-Hamilton"])
        v.set("Serato_Markers", "keep-me")
        let parsed = try VorbisComment(payload: v.payload)
        #expect(parsed.vendor == "reference libFLAC 1.4.3")
        #expect(parsed.first("TITLE") == "Dreams")
        #expect(parsed.values("artist") == ["Prospa", "Rohan Pinnock-Hamilton"])
        #expect(parsed.first("SERATO_MARKERS") == "keep-me")
    }

    @Test func setReplacesInPlaceAndRemovesOnNilOrEmpty() {
        var v = VorbisComment(fields: [.init(key: "A", value: "1"), .init(key: "TITLE", value: "old"), .init(key: "B", value: "2")])
        v.set("TITLE", "new")
        #expect(v.fields.map(\.key) == ["A", "TITLE", "B"])
        #expect(v.first("TITLE") == "new")
        v.set("TITLE", nil)
        #expect(v.first("TITLE") == nil)
        v.set("B", "")
        #expect(v.fields.map(\.key) == ["A"])
    }

    @Test func utf8ValuesSurvive() throws {
        var v = VorbisComment()
        v.set("ARTIST", "Rosalía")
        v.set("COMMENT", "Ünïcødé ✓")
        let parsed = try VorbisComment(payload: v.payload)
        #expect(parsed.first("ARTIST") == "Rosalía")
        #expect(parsed.first("COMMENT") == "Ünïcødé ✓")
    }

    @Test func pictureRoundTrip() throws {
        let pic = FlacPicture(pictureType: 3, mimeType: "image/jpeg", description: "cover",
                              width: 1280, height: 1280, depth: 24, colors: 0, data: [0xFF, 0xD8, 0xFF, 0xD9])
        #expect(try FlacPicture(payload: pic.payload) == pic)
    }

    @Test func frontCoverReadsPixelSize() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAEklEQVR4nGP4z8DwnwEIGHAwAFbmBfvxZqpZAAAAAElFTkSuQmCC")!
        let pic = FlacPicture.frontCover(data: png, mimeType: "image/png")
        #expect(pic.pictureType == 3)
        #expect(pic.width == 2)
        #expect(pic.height == 3)
    }
}
