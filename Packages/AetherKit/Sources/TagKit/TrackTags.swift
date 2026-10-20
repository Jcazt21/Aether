public import Foundation

/// Format-agnostic tag model used by Harvester (writing) and Cosmos (reading/editing).
public struct TrackTags: Equatable, Sendable, Codable {
    public struct Artwork: Equatable, Sendable, Codable {
        public var data: Data
        public var mimeType: String

        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var comment: String?
    public var label: String?
    public var key: String?
    public var isrc: String?
    public var composer: String?
    public var remixer: String?
    /// Year or full ISO date ("2026" or "2026-06-12").
    public var year: String?
    public var bpm: Double?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var artwork: Artwork?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, comment: String? = nil, label: String? = nil, key: String? = nil,
                isrc: String? = nil, composer: String? = nil, remixer: String? = nil, year: String? = nil,
                bpm: Double? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, artwork: Artwork? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.comment = comment
        self.label = label
        self.key = key
        self.isrc = isrc
        self.composer = composer
        self.remixer = remixer
        self.year = year
        self.bpm = bpm
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artwork = artwork
    }

    public var withoutArtwork: TrackTags {
        var copy = self
        copy.artwork = nil
        return copy
    }

    /// "Sin tags" in Cosmos: no usable title or artist.
    public var isEffectivelyEmpty: Bool { title?.nilIfBlank == nil || artist?.nilIfBlank == nil }

    public static func formatBPM(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    public static func leadingInt(_ text: String) -> Int? {
        Int(text.prefix { $0.isNumber })
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
