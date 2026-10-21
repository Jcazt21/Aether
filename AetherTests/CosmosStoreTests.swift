import Cosmos
import Foundation
import TagKit
import Testing
@testable import Aether

@MainActor
@Suite struct CosmosStoreTests {
    private func item(_ path: String, artist: String? = nil, title: String? = nil, codec: AudioFormatInfo.Codec = .flac) -> LibraryItem {
        LibraryItem(relativePath: path, fileSize: 1, modified: .distantPast,
                    format: AudioFormatInfo(codec: codec, sampleRate: 44_100, bitDepth: 16, channels: 2, duration: 1, bitRate: 320),
                    tags: TrackTags(title: title, artist: artist), hasArtwork: false, verifiedStamp: nil)
    }

    @Test func filtersByScopeAndSearch() {
        let items = [
            item("UK House/Prospa - Dreams.flac", artist: "Prospa", title: "Dreams"),
            item("Inbox/x.mp3", codec: .mp3),
            item("Tech House/PAWSA - The Groovy Cat.flac", artist: "PAWSA", title: "The Groovy Cat"),
        ]
        #expect(CosmosStore.filter(items, scope: .cosmosAll, inbox: "Inbox", search: "", duplicates: []).count == 3)
        #expect(CosmosStore.filter(items, scope: .cosmosFolder("UK House"), inbox: "Inbox", search: "", duplicates: []).map(\.id) == ["UK House/Prospa - Dreams.flac"])
        #expect(CosmosStore.filter(items, scope: .cosmosInbox, inbox: "Inbox", search: "", duplicates: []).map(\.id) == ["Inbox/x.mp3"])
        #expect(CosmosStore.filter(items, scope: .cosmosReview(.untagged), inbox: "Inbox", search: "", duplicates: []).map(\.id) == ["Inbox/x.mp3"])
        #expect(CosmosStore.filter(items, scope: .cosmosReview(.lossy), inbox: "Inbox", search: "", duplicates: []).map(\.id) == ["Inbox/x.mp3"])
        #expect(CosmosStore.filter(items, scope: .cosmosReview(.duplicates), inbox: "Inbox", search: "", duplicates: ["UK House/Prospa - Dreams.flac"]).count == 1)
        #expect(CosmosStore.filter(items, scope: .cosmosAll, inbox: "Inbox", search: "groovy", duplicates: []).map(\.id) == ["Tech House/PAWSA - The Groovy Cat.flac"])
    }
}
