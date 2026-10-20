import Foundation
import SwiftUI
import TagKit
import Testing
@testable import Aether

@MainActor
@Suite struct TagDraftTests {
    @Test func mixedValuesAreDetectedAndOnlyDirtyFieldsApply() {
        let a = TrackTags(title: "Dreams", artist: "Prospa", genre: "UK House", bpm: 128)
        let b = TrackTags(title: "Baby", artist: "Prospa", genre: "House", bpm: 128)
        let draft = TagDraft(tags: [a, b])
        #expect(draft.mixed == [.title, .genre])
        #expect(draft.text[.artist] == "Prospa")
        #expect(draft.text[.bpm] == "128")
        #expect(!draft.hasChanges)

        draft.binding(.genre).wrappedValue = "UK House"
        #expect(draft.dirty == [.genre])
        let newB = draft.applied(to: b)
        #expect(newB.genre == "UK House")
        #expect(newB.title == "Baby")
    }

    @Test func numericFieldsParseAndClear() {
        let draft = TagDraft(tags: [TrackTags(bpm: 124.5)])
        #expect(draft.text[.bpm] == "124.50")
        draft.binding(.bpm).wrappedValue = "126"
        #expect(draft.applied(to: TrackTags()).bpm == 126)
        draft.binding(.bpm).wrappedValue = ""
        #expect(draft.applied(to: TrackTags(bpm: 1)).bpm == nil)
    }

    @Test func artworkChangeApplies() {
        let draft = TagDraft(tags: [TrackTags(artwork: .init(data: Data([1]), mimeType: "image/jpeg"))])
        draft.artwork = .removed
        #expect(draft.hasChanges)
        #expect(draft.applied(to: TrackTags(artwork: .init(data: Data([1]), mimeType: "image/jpeg"))).artwork == nil)
    }
}
