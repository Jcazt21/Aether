import Foundation
public import HiFiClient
public import TagKit

public enum LabelParser {
    /// "(C) 2026 CircoLoco Records" → "CircoLoco Records". Strips ©/℗/(C)/(P) markers and a leading year.
    public static func label(fromCopyright copyright: String?) -> String? {
        guard let copyright else { return nil }
        let stripped = copyright.replacing(/^\s*(?:(?:\([CP]\)|\[[CP]\]|℗|©)\s*)*(?:\d{4}\s*)?(?:[,\-–]\s*)?/, with: "")
        let label = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }
}

public enum TagBuilder {
    public static func tags(track: TidalTrack, album: TidalAlbum?, genre: String?, artwork: TrackTags.Artwork?) -> TrackTags {
        TrackTags(
            title: track.displayTitle,
            artist: track.allArtistNames,
            album: track.album?.title ?? album?.title,
            albumArtist: album?.primaryArtistName,
            genre: genre,
            label: LabelParser.label(fromCopyright: album?.copyright ?? track.copyright),
            key: track.musicalKey,
            isrc: track.isrc,
            year: album?.releaseDate,
            bpm: track.bpm,
            trackNumber: track.trackNumber,
            discNumber: track.volumeNumber,
            artwork: artwork)
    }

    public static func replayGainFields(_ info: PlaybackInfo) -> [String: String] {
        var fields: [String: String] = [:]
        if let v = info.trackReplayGain { fields["REPLAYGAIN_TRACK_GAIN"] = String(format: "%.2f dB", v) }
        if let v = info.trackPeakAmplitude { fields["REPLAYGAIN_TRACK_PEAK"] = String(format: "%.6f", v) }
        if let v = info.albumReplayGain { fields["REPLAYGAIN_ALBUM_GAIN"] = String(format: "%.2f dB", v) }
        if let v = info.albumPeakAmplitude { fields["REPLAYGAIN_ALBUM_PEAK"] = String(format: "%.6f", v) }
        return fields
    }
}
