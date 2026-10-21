import TagKit

public struct TidalArtist: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let type: String?
}

public struct TidalAlbumRef: Codable, Sendable, Hashable {
    public let id: Int
    public let title: String
    public let cover: String?
}

public struct MediaMetadata: Codable, Sendable, Hashable {
    public let tags: [String]
}

public struct TidalTrack: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let version: String?
    public let duration: Int
    public let trackNumber: Int?
    public let volumeNumber: Int?
    public let isrc: String?
    public let bpm: Double?
    public let key: String?
    public let keyScale: String?
    public let copyright: String?
    public let explicit: Bool?
    public let audioQuality: String?
    public let mediaMetadata: MediaMetadata?
    public let artist: TidalArtist?
    public let artists: [TidalArtist]?
    public var album: TidalAlbumRef?
    public let replayGain: Double?
    public let peak: Double?

    public var displayTitle: String { FileNaming.titleWithVersion(title, version: version) }
    public var primaryArtistName: String { artist?.name ?? artists?.first?.name ?? "Unknown" }

    public var allArtistNames: String {
        let main = (artists ?? []).filter { $0.type == nil || $0.type == "MAIN" }.map(\.name)
        return main.isEmpty ? primaryArtistName : main.joined(separator: ", ")
    }

    public var supportsHiRes: Bool { mediaMetadata?.tags.contains("HIRES_LOSSLESS") ?? false }

    /// Tidal key ("A", "FSharp") + scale ("MINOR") → "Am", "F#".
    public var musicalKey: String? {
        guard let key, !key.isEmpty else { return nil }
        let note = key.replacingOccurrences(of: "Sharp", with: "#").replacingOccurrences(of: "Flat", with: "b")
        return keyScale?.uppercased() == "MINOR" ? note + "m" : note
    }
}

public struct TidalAlbum: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let version: String?
    public let releaseDate: String?
    public let copyright: String?
    public let cover: String?
    public let numberOfTracks: Int?
    public let upc: String?
    public let audioQuality: String?
    public let mediaMetadata: MediaMetadata?
    public let artists: [TidalArtist]?

    public var primaryArtistName: String { artists?.first?.name ?? "Unknown" }
    public var supportsHiRes: Bool { mediaMetadata?.tags.contains("HIRES_LOSSLESS") ?? false }
    public var year: String? { releaseDate.map { String($0.prefix(4)) } }
}

public struct Page<Item: Codable & Sendable>: Codable, Sendable {
    public let limit: Int
    public let offset: Int
    public let totalNumberOfItems: Int
    public let items: [Item]
}

public struct PlaybackInfo: Codable, Sendable {
    public let trackId: Int
    public let audioQuality: String
    public let manifestMimeType: String
    public let manifest: String
    public let bitDepth: Int?
    public let sampleRate: Int?
    public let trackReplayGain: Double?
    public let trackPeakAmplitude: Double?
    public let albumReplayGain: Double?
    public let albumPeakAmplitude: Double?

    public init(trackId: Int, audioQuality: String, manifestMimeType: String, manifest: String,
                bitDepth: Int?, sampleRate: Int?, trackReplayGain: Double?, trackPeakAmplitude: Double?,
                albumReplayGain: Double?, albumPeakAmplitude: Double?) {
        self.trackId = trackId
        self.audioQuality = audioQuality
        self.manifestMimeType = manifestMimeType
        self.manifest = manifest
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.trackReplayGain = trackReplayGain
        self.trackPeakAmplitude = trackPeakAmplitude
        self.albumReplayGain = albumReplayGain
        self.albumPeakAmplitude = albumPeakAmplitude
    }
}

public enum AudioQuality: String, Sendable, Codable {
    case hiResLossless = "HI_RES_LOSSLESS"
    case lossless = "LOSSLESS"
}
