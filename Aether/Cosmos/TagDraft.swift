import Observation
import SwiftUI
import TagKit

enum TagField: String, CaseIterable, Identifiable {
    case title, artist, remixer, album, albumArtist, label, year, isrc, genre, bpm, key, comment

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .remixer: "Remixer"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .label: "Label"
        case .year: "Year"
        case .isrc: "ISRC"
        case .genre: "Genre"
        case .bpm: "BPM"
        case .key: "Key"
        case .comment: "Comment"
        }
    }

    var isNumeric: Bool { self == .bpm }

    func get(_ t: TrackTags) -> String {
        switch self {
        case .title: t.title ?? ""
        case .artist: t.artist ?? ""
        case .remixer: t.remixer ?? ""
        case .album: t.album ?? ""
        case .albumArtist: t.albumArtist ?? ""
        case .label: t.label ?? ""
        case .year: t.year ?? ""
        case .isrc: t.isrc ?? ""
        case .genre: t.genre ?? ""
        case .bpm: t.bpm.map(TrackTags.formatBPM) ?? ""
        case .key: t.key ?? ""
        case .comment: t.comment ?? ""
        }
    }

    func set(_ t: inout TrackTags, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let s: String? = v.isEmpty ? nil : v
        switch self {
        case .title: t.title = s
        case .artist: t.artist = s
        case .remixer: t.remixer = s
        case .album: t.album = s
        case .albumArtist: t.albumArtist = s
        case .label: t.label = s
        case .year: t.year = s
        case .isrc: t.isrc = s?.uppercased()
        case .genre: t.genre = s
        case .bpm: t.bpm = s.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        case .key: t.key = s
        case .comment: t.comment = s
        }
    }
}

enum ArtworkChange: Equatable {
    case unchanged
    case set(TrackTags.Artwork)
    case removed
}

@MainActor
@Observable
final class TagDraft {
    private(set) var text: [TagField: String] = [:]
    private(set) var mixed: Set<TagField> = []
    private(set) var dirty: Set<TagField> = []
    var artwork: ArtworkChange = .unchanged
    let currentArtwork: TrackTags.Artwork?
    let artworkIsMixed: Bool

    init(tags: [TrackTags]) {
        let artworks = tags.map(\.artwork)
        let mixedArtwork = Set(artworks.map { $0?.data }).count > 1
        artworkIsMixed = mixedArtwork
        currentArtwork = mixedArtwork ? nil : artworks.first ?? nil
        for field in TagField.allCases {
            let values = Set(tags.map(field.get))
            if values.count > 1 { mixed.insert(field) } else { text[field] = values.first ?? "" }
        }
    }

    var hasChanges: Bool { !dirty.isEmpty || artwork != .unchanged }

    func binding(_ field: TagField) -> Binding<String> {
        Binding(get: { self.text[field] ?? "" }, set: { newValue in
            self.text[field] = newValue
            self.dirty.insert(field)
            self.mixed.remove(field)
        })
    }

    func applied(to tags: TrackTags) -> TrackTags {
        var result = tags
        for field in dirty { field.set(&result, text[field] ?? "") }
        switch artwork {
        case .unchanged: break
        case .set(let art): result.artwork = art
        case .removed: result.artwork = nil
        }
        return result
    }
}
