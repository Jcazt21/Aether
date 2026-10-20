import Cosmos
import Foundation
import Harvester
import HiFiClient
import TagKit
import Testing
@testable import Aether

@MainActor
@Suite struct DuplicateGateTests {
    @Test func exactMatchesAreHeldForConfirmation() throws {
        let store = HarvesterStore(preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        store.masterLookup = MasterLookup(items: [LibraryItem(
            relativePath: "UK House/Prospa - Dreams.flac", fileSize: 1, modified: .distantPast,
            format: AudioFormatInfo(codec: .flac, sampleRate: 44_100, bitDepth: 16, channels: 2, duration: 1, bitRate: nil),
            tags: TrackTags(title: "Dreams", artist: "Prospa", isrc: "QM6MZ2647627"), hasArtwork: false, verifiedStamp: nil)])
        let dup = try JSONDecoder().decode(TidalTrack.self, from: Data(#"{"id":1,"title":"Dreams","duration":1,"isrc":"QM6MZ2647627","artist":{"id":1,"name":"Prospa"}}"#.utf8))
        let fresh = try JSONDecoder().decode(TidalTrack.self, from: Data(#"{"id":2,"title":"Baby","duration":1,"artist":{"id":1,"name":"Prospa"}}"#.utf8))

        store.requestEnqueue([dup, fresh])
        #expect(store.pendingDuplicates?.map(\.id) == [1])
        #expect(store.jobs.map(\.request.track.id) == [2])

        store.resolvePendingDuplicates(includeDuplicates: false)
        #expect(store.pendingDuplicates == nil)
        #expect(store.jobs.count == 1)
    }
}
