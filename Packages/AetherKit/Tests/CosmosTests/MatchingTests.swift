import Foundation
import Testing
@testable import Cosmos
import TagKit

@Suite struct MatchingTests {
    private func item(_ path: String, artist: String? = nil, title: String? = nil, isrc: String? = nil, codec: AudioFormatInfo.Codec = .flac) -> LibraryItem {
        LibraryItem(relativePath: path, fileSize: 1, modified: .distantPast,
                    format: AudioFormatInfo(codec: codec, sampleRate: 44_100, bitDepth: 16, channels: 2, duration: 1, bitRate: nil),
                    tags: TrackTags(title: title, artist: artist, isrc: isrc), hasArtwork: false, verifiedStamp: nil)
    }

    @Test func normalizationFoldsCaseDiacriticsPunctuation() {
        #expect(MatchKey.normalize("Joe Rolét — No Hesitating!") == "joe rolet no hesitating")
        #expect(MatchKey.normalize("Rhythm & Blues") == "rhythm and blues")
        #expect(MatchKey.primaryArtist("Prospa, Rohan Pinnock-Hamilton") == "prospa")
        #expect(MatchKey.primaryArtist("Kettama feat. Someone") == "kettama")
        #expect(MatchKey.primaryArtist("Max Dean & Luke Dean") == "max dean")
    }

    @Test func strictAndLooseKeys() {
        #expect(MatchKey.strict(artist: "Prospa", title: "Dreams (Extended Mix)") == "prospa|dreams extended mix")
        #expect(MatchKey.strict(artist: "Prospa", title: "Dreams (Original Mix)") == "prospa|dreams")
        #expect(MatchKey.loose(artist: "Prospa", title: "Dreams (Extended Mix)") == "prospa|dreams")
    }

    @Test func duplicateGroupsUseTagsOrFileNames() {
        let items = [
            item("UK House/Prospa - Dreams.flac", artist: "Prospa", title: "Dreams"),
            item("Inbox/Prospa - Dreams.mp3", codec: .mp3),
            item("UK House/Prospa - Baby.flac", artist: "Prospa", title: "Baby"),
        ]
        let groups = DuplicateDetector.groups(in: items)
        #expect(groups == [DuplicateGroup(id: "prospa|dreams", itemIDs: ["Inbox/Prospa - Dreams.mp3", "UK House/Prospa - Dreams.flac"])])
    }

    @Test func lookupPrefersISRCThenStrictThenLoose() {
        let lookup = MasterLookup(items: [
            item("UK House/a.flac", artist: "Prospa", title: "Dreams", isrc: "QM6MZ2647627"),
            item("UK House/b.flac", artist: "Kettama", title: "Pretty Green Eyes (Sunset Ibiza Mix)"),
        ])
        #expect(lookup.match(isrc: "QM6MZ2647627", artist: "X", title: "Y") == .exact(lookup.items[0]))
        #expect(lookup.match(isrc: nil, artist: "Prospa, Rohan Pinnock-Hamilton", title: "Dreams") == .exact(lookup.items[0]))
        #expect(lookup.match(isrc: nil, artist: "Kettama", title: "Pretty Green Eyes (Extended Mix)") == .similar(lookup.items[1]))
        #expect(lookup.match(isrc: nil, artist: "Kettama", title: "Comes and Goes") == nil)
    }
}
