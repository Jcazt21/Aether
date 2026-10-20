import Foundation
import Testing
@testable import HiFiClient

@Suite struct DashManifestTests {
    /// Real structure from hifi-api (2026-10-20) with signed URLs replaced.
    static let mpd = """
    <?xml version='1.0' encoding='UTF-8'?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-main:2011" type="static" minBufferTime="PT3.993S" mediaPresentationDuration="PT3M56.249S"><Period id="0"><AdaptationSet id="0" contentType="audio" mimeType="audio/mp4" lang="und" segmentAlignment="true"><Representation id="FLAC_HIRES,44100,24" codecs="flac" bandwidth="1675585" audioSamplingRate="44100"><AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/><SegmentTemplate timescale="44100" initialization="https://cdn.example/init.mp4?token=a&amp;sig=b" media="https://cdn.example/$Number$.mp4?token=a&amp;sig=b" startNumber="1"><SegmentTimeline><S d="176128" r="58"/><S d="27042"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>
    """

    @Test func parsesTidalManifest() throws {
        let m = try DashManifest.parse(Data(Self.mpd.utf8))
        #expect(m.representationID == "FLAC_HIRES,44100,24")
        #expect(m.codecs == "flac")
        #expect(m.sampleRate == 44_100)
        #expect(m.channels == 2)
        #expect(m.bitDepth == 24)
        #expect(m.timescale == 44_100)
        #expect(m.segmentCount == 60)
        #expect(m.segmentNumbers == 1..<61)
        #expect(m.totalSamples == 10_418_594)
        #expect(m.presentationDuration == 236.249)
        #expect(m.initializationURL.absoluteString == "https://cdn.example/init.mp4?token=a&sig=b")
        #expect(m.mediaURL(number: 7).absoluteString == "https://cdn.example/7.mp4?token=a&sig=b")
        #expect(m.estimatedBytes == Int64(1_675_585.0 * 236.249 / 8))
    }

    @Test func playbackInfoDecodesBase64Manifest() throws {
        let info = PlaybackInfo(trackId: 1, audioQuality: "LOSSLESS", manifestMimeType: "application/dash+xml",
                                manifest: Data(Self.mpd.utf8).base64EncodedString(), bitDepth: 16, sampleRate: 44_100,
                                trackReplayGain: nil, trackPeakAmplitude: nil, albumReplayGain: nil, albumPeakAmplitude: nil)
        #expect(try info.dashManifest().segmentCount == 60)
    }

    @Test func rejectsNonDashManifest() {
        let info = PlaybackInfo(trackId: 1, audioQuality: "LOSSLESS", manifestMimeType: "application/vnd.tidal.bts",
                                manifest: "e30=", bitDepth: nil, sampleRate: nil, trackReplayGain: nil,
                                trackPeakAmplitude: nil, albumReplayGain: nil, albumPeakAmplitude: nil)
        #expect(throws: HiFiError.unsupportedManifest("application/vnd.tidal.bts")) { try info.dashManifest() }
    }

    @Test func missingTemplateThrows() {
        #expect(throws: DashError.missing("SegmentTemplate")) {
            try DashManifest.parse(Data(#"<MPD><Period><AdaptationSet><Representation id="x" codecs="flac" audioSamplingRate="44100"/></AdaptationSet></Period></MPD>"#.utf8))
        }
    }
}
