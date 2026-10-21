import Foundation
import HiFiClient
import Testing
@testable import Harvester

@Suite struct SpotifyImportTests {
    @Test func extractsPlaylistID() {
        #expect(SpotifyImport.playlistID(from: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc") == "37i9dQZF1DXcBWIGoYBM5M")
        #expect(SpotifyImport.playlistID(from: "https://open.spotify.com/intl-es/playlist/37i9dQZF1DXcBWIGoYBM5M") == "37i9dQZF1DXcBWIGoYBM5M")
        #expect(SpotifyImport.playlistID(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M") == "37i9dQZF1DXcBWIGoYBM5M")
        #expect(SpotifyImport.playlistID(from: "https://open.spotify.com/album/37i9dQZF1DXcBWIGoYBM5M") == nil)
        #expect(SpotifyImport.playlistID(from: "prospa dreams") == nil)
    }

    @Test func parsesTrackListFromEmbedPage() throws {
        let html = """
        <html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":
        {"name":"Deep Cuts","trackList":[{"title":"Dreams","subtitle":"Prospa, Rohan Pinnock-Hamilton"},{"title":"Tone","subtitle":"Fixture"},{"title":"","subtitle":"x"}]}}}}}}</script></html>
        """
        let playlist = try SpotifyImport.parse(html: html)
        #expect(playlist.name == "Deep Cuts")
        #expect(playlist.tracks == [SpotifyTrack(title: "Dreams", artists: "Prospa, Rohan Pinnock-Hamilton"),
                                    SpotifyTrack(title: "Tone", artists: "Fixture")])
        #expect(throws: SpotifyError.unreadable) { try SpotifyImport.parse(html: "<html></html>") }
    }

    @Test func matcherPrefersRightTrackAndRejectsUnrelated() throws {
        let dreams = try TagBuilderTests.track()
        let wanted = SpotifyTrack(title: "Dreams", artists: "Prospa")
        #expect(TrackMatcher.best(for: wanted, in: [dreams])?.id == dreams.id)
        #expect(TrackMatcher.best(for: SpotifyTrack(title: "Completely Different", artists: "Someone"), in: [dreams]) == nil)
    }
}
