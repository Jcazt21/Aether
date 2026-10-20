import Foundation
import Testing
@testable import HiFiClient
import TestSupport

@Suite struct HiFiClientTests {
    static let trackJSON = """
    {"id":505935155,"title":"Dreams","duration":236,"replayGain":-10.44,"peak":0.987523,"trackNumber":11,
     "volumeNumber":1,"version":"Extended Mix","copyright":"(P) 2026 CircoLoco Records","bpm":null,"key":"A",
     "keyScale":"MINOR","isrc":"QM6MZ2647627","explicit":false,"audioQuality":"LOSSLESS",
     "mediaMetadata":{"tags":["LOSSLESS","HIRES_LOSSLESS"]},
     "artist":{"id":8955910,"name":"Prospa","type":"MAIN"},
     "artists":[{"id":8955910,"name":"Prospa","type":"MAIN"},{"id":34851570,"name":"Rohan Pinnock-Hamilton","type":"MAIN"},
                {"id":1,"name":"Someone","type":"FEATURED"}],
     "album":{"id":505935144,"title":"Free Your Mind","cover":"8a14a78b-51ae-47e7-805e-597284a629c7"}}
    """

    static let albumJSON = """
    {"id":505935144,"title":"Free Your Mind","releaseDate":"2026-06-12","copyright":"(C) 2026 CircoLoco Records",
     "cover":"8a14a78b-51ae-47e7-805e-597284a629c7","numberOfTracks":11,"upc":"820200597014","audioQuality":"LOSSLESS",
     "mediaMetadata":{"tags":["LOSSLESS","HIRES_LOSSLESS"]},"artists":[{"id":8955910,"name":"Prospa","type":"MAIN"}]}
    """

    private func client(_ routes: @escaping @Sendable (URLComponents) -> (Int, String)) -> HiFiClient {
        let base = StubURLProtocol.register { request in
            let (status, body) = routes(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!)
            return (status, Data(body.utf8))
        }
        return HiFiClient(baseURL: base, session: StubURLProtocol.session())
    }

    @Test func decodesTrackComputedProperties() throws {
        let track = try JSONDecoder().decode(TidalTrack.self, from: Data(Self.trackJSON.utf8))
        #expect(track.displayTitle == "Dreams (Extended Mix)")
        #expect(track.primaryArtistName == "Prospa")
        #expect(track.allArtistNames == "Prospa, Rohan Pinnock-Hamilton")
        #expect(track.supportsHiRes)
        #expect(track.musicalKey == "Am")
    }

    @Test func searchTracksHitsSearchEndpoint() async throws {
        let c = client { url in
            #expect(url.path == "/search/")
            #expect(url.queryItems?.contains(URLQueryItem(name: "s", value: "prospa dreams")) == true)
            return (200, #"{"version":"2.10","data":{"limit":50,"offset":0,"totalNumberOfItems":1,"items":[\#(Self.trackJSON)]}}"#)
        }
        let page = try await c.searchTracks("prospa dreams")
        #expect(page.items.map(\.id) == [505935155])
    }

    @Test func searchAlbumsReadsTopHitsShape() async throws {
        let c = client { _ in
            (200, #"{"version":"2.10","data":{"albums":{"limit":25,"offset":0,"totalNumberOfItems":1,"items":[\#(Self.albumJSON)]}}}"#)
        }
        let page = try await c.searchAlbums("free your mind")
        #expect(page.items.first?.year == "2026")
        #expect(page.items.first?.primaryArtistName == "Prospa")
    }

    @Test func albumFlattensItems() async throws {
        let c = client { url in
            #expect(url.path == "/album/")
            let album = Self.albumJSON.dropLast() + #","items":[{"item":\#(Self.trackJSON),"type":"track"},{"item":{"id":9,"title":"Video","duration":1},"type":"video"}]}"#
            return (200, #"{"version":"2.10","data":\#(album)}"#)
        }
        let result = try await c.album(id: 505935144)
        #expect(result.album.title == "Free Your Mind")
        #expect(result.tracks.map(\.id) == [505935155])
    }

    @Test func playbackInfoAndHTTPErrors() async throws {
        let c = client { url in
            if url.queryItems?.contains(URLQueryItem(name: "quality", value: "HI_RES_LOSSLESS")) == true {
                return (200, #"{"version":"2.10","data":{"trackId":1,"audioQuality":"HI_RES_LOSSLESS","manifestMimeType":"application/dash+xml","manifest":"PE1QRC8+","bitDepth":24,"sampleRate":96000}}"#)
            }
            return (503, "busy")
        }
        let info = try await c.playbackInfo(trackID: 1, quality: .hiResLossless)
        #expect(info.sampleRate == 96_000)
        #expect(info.bitDepth == 24)
        await #expect(throws: HiFiError.http(503)) { try await c.playbackInfo(trackID: 1, quality: .lossless) }
    }

    @Test func coverURLUsesSlashedUUID() {
        let c = HiFiClient(baseURL: URL(string: "http://127.0.0.1:8000")!)
        #expect(c.coverURL("8a14a78b-51ae-47e7").absoluteString == "https://resources.tidal.com/images/8a14a78b/51ae/47e7/1280x1280.jpg")
    }
}
