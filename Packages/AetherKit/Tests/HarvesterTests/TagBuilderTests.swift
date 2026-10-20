import Foundation
import Testing
@testable import Harvester
import HiFiClient
import TagKit

@Suite struct TagBuilderTests {
    static func track() throws -> TidalTrack {
        try JSONDecoder().decode(TidalTrack.self, from: Data("""
        {"id":505935155,"title":"Dreams","version":"Extended Mix","duration":236,"trackNumber":11,"volumeNumber":1,
         "isrc":"QM6MZ2647627","bpm":124,"key":"A","keyScale":"MINOR","copyright":"(P) 2026 CircoLoco Records",
         "artist":{"id":1,"name":"Prospa","type":"MAIN"},
         "artists":[{"id":1,"name":"Prospa","type":"MAIN"},{"id":2,"name":"Rohan Pinnock-Hamilton","type":"MAIN"}],
         "album":{"id":9,"title":"Free Your Mind","cover":"8a14a78b-51ae"}}
        """.utf8))
    }

    @Test(arguments: [
        ("(C) 2026 CircoLoco Records", "CircoLoco Records"),
        ("℗ 2019 Defected Records Limited", "Defected Records Limited"),
        ("(P) (C) 2021 Toolroom", "Toolroom"),
        ("2020 Hot Creations", "Hot Creations"),
        ("(P) 2026", nil),
        ("Columbia Records", "Columbia Records"),
    ] as [(String, String?)])
    func labelFromCopyright(input: String, expected: String?) {
        #expect(LabelParser.label(fromCopyright: input) == expected)
    }

    @Test func buildsRekordboxTags() throws {
        let album = try JSONDecoder().decode(TidalAlbum.self, from: Data("""
        {"id":9,"title":"Free Your Mind","releaseDate":"2026-06-12","copyright":"(C) 2026 CircoLoco Records",
         "artists":[{"id":1,"name":"Prospa","type":"MAIN"}]}
        """.utf8))
        let art = TrackTags.Artwork(data: Data([1]), mimeType: "image/jpeg")
        let tags = TagBuilder.tags(track: try Self.track(), album: album, genre: "UK House", artwork: art)
        #expect(tags == TrackTags(
            title: "Dreams (Extended Mix)", artist: "Prospa, Rohan Pinnock-Hamilton", album: "Free Your Mind",
            albumArtist: "Prospa", genre: "UK House", comment: nil, label: "CircoLoco Records", key: "Am",
            isrc: "QM6MZ2647627", composer: nil, remixer: nil, year: "2026-06-12", bpm: 124,
            trackNumber: 11, discNumber: 1, artwork: art))
    }

    @Test func fallsBackToTrackCopyrightWithoutAlbum() throws {
        let tags = TagBuilder.tags(track: try Self.track(), album: nil, genre: nil, artwork: nil)
        #expect(tags.label == "CircoLoco Records")
        #expect(tags.album == "Free Your Mind")
        #expect(tags.year == nil)
    }

    @Test func replayGainFieldsUseDecibelSuffix() {
        let info = PlaybackInfo(trackId: 1, audioQuality: "LOSSLESS", manifestMimeType: "", manifest: "", bitDepth: 16,
                                sampleRate: 44_100, trackReplayGain: -10.15, trackPeakAmplitude: 0.987523,
                                albumReplayGain: -10.44, albumPeakAmplitude: 0.988392)
        #expect(TagBuilder.replayGainFields(info) == [
            "REPLAYGAIN_TRACK_GAIN": "-10.15 dB", "REPLAYGAIN_TRACK_PEAK": "0.987523",
            "REPLAYGAIN_ALBUM_GAIN": "-10.44 dB", "REPLAYGAIN_ALBUM_PEAK": "0.988392",
        ])
    }

    @Test func qualityPolicyStartsAtRightTier() {
        #expect(QualityPolicy.hiResCapped96.initialQuality == .hiResLossless)
        #expect(QualityPolicy.hiRes.initialQuality == .hiResLossless)
        #expect(QualityPolicy.lossless.initialQuality == .lossless)
    }
}
