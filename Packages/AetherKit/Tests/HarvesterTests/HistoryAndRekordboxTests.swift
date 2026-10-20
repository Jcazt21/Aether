import FlacKit
import Foundation
import Testing
@testable import Harvester

@Suite struct HistoryAndRekordboxTests {
    static func entry(_ title: String, path: String, day: TimeInterval) -> HistoryEntry {
        HistoryEntry(id: UUID(), trackID: 1, title: title, artist: "Prospa & Co", album: "Free <Your> Mind", genre: "UK House",
                     fileURL: URL(filePath: path),
                     report: IntegrityReport(verdict: .verified, frames: 1, samples: 1, expectedSamples: nil,
                                             md5Expected: "ab", md5Actual: "ab", failure: nil),
                     format: FormatSummary(sampleRate: 44_100, bitDepth: 24, channels: 2, duration: 236.249),
                     bytes: 41_000_000, finishedAt: Date(timeIntervalSince1970: day))
    }

    @Test func historyPersistsNewestFirstAndRelocates() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString).json")
        let store = HistoryStore(fileURL: url)
        await store.append(Self.entry("A", path: "/Master/Por clasificar/A.flac", day: 0))
        await store.append(Self.entry("B", path: "/Master/Por clasificar/B.flac", day: 100))
        await store.relocate(from: URL(filePath: "/Master/Por clasificar/A.flac"), to: URL(filePath: "/Master/UK House/A.flac"))
        let reloaded = await HistoryStore(fileURL: url).all()
        #expect(reloaded.map(\.title) == ["B", "A"])
        #expect(reloaded[1].fileURL.path == "/Master/UK House/A.flac")
    }

    @Test func locationUsesLocalhostAndPercentEncoding() {
        #expect(RekordboxXML.location(URL(filePath: "/Users/jazar/Master/Tech House/Joe Rolét - X.flac"))
                == "file://localhost/Users/jazar/Master/Tech%20House/Joe%20Rol%C3%A9t%20-%20X.flac")
    }

    @Test func documentIsWellFormedWithDailyPlaylists() throws {
        let entries = [Self.entry("Dreams", path: "/M/a.flac", day: 0), Self.entry("Baby", path: "/M/b.flac", day: 90_000)]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let xml = RekordboxXML.document(entries: entries, calendar: calendar)
        let doc = try XMLDocument(xmlString: xml)
        let tracks = try doc.nodes(forXPath: "/DJ_PLAYLISTS/COLLECTION/TRACK") as! [XMLElement]
        #expect(tracks.count == 2)
        #expect(tracks[0].attribute(forName: "Album")?.stringValue == "Free <Your> Mind")
        #expect(tracks[0].attribute(forName: "Kind")?.stringValue == "FLAC File")
        #expect(tracks[0].attribute(forName: "TotalTime")?.stringValue == "236")
        #expect(tracks[0].attribute(forName: "BitRate")?.stringValue == "1388")
        let days = try doc.nodes(forXPath: "/DJ_PLAYLISTS/PLAYLISTS/NODE/NODE[@Name='Harvester']/NODE") as! [XMLElement]
        #expect(days.compactMap { $0.attribute(forName: "Name")?.stringValue } == ["1970-01-02", "1970-01-01"])
    }
}
