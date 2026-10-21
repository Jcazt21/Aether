public import Foundation
public import HiFiClient
import TagKit

public struct SpotifyTrack: Sendable, Equatable {
    public let title: String
    public let artists: String
}

public struct SpotifyPlaylist: Sendable, Equatable {
    public let name: String
    public let tracks: [SpotifyTrack]
}

public enum SpotifyError: Error, Equatable {
    case notAPlaylist, unreachable, unreadable
}

/// Reads a public playlist from Spotify's embed page (no account, no API key). Spotify caps it at 100 tracks.
public enum SpotifyImport {
    public static func playlistID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.firstMatch(of: /open\.spotify\.com\/(?:embed\/)?(?:intl-[a-z]+\/)?playlist\/([A-Za-z0-9]{10,})/) {
            return String(match.1)
        }
        if let match = trimmed.firstMatch(of: /^spotify:playlist:([A-Za-z0-9]{10,})$/) { return String(match.1) }
        return nil
    }

    public static func fetch(id: String, session: URLSession = .shared) async throws -> SpotifyPlaylist {
        guard let url = URL(string: "https://open.spotify.com/embed/playlist/\(id)") else { throw SpotifyError.notAPlaylist }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpotifyError.unreachable }
            data = body
        } catch let error as SpotifyError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpotifyError.unreachable
        }
        return try parse(html: String(decoding: data, as: UTF8.self))
    }

    /// Finds the `trackList` array wherever it sits inside the page's `__NEXT_DATA__` JSON.
    public static func parse(html: String) throws -> SpotifyPlaylist {
        guard let match = html.firstMatch(of: /<script id="__NEXT_DATA__"[^>]*>(.*?)<\/script>/.dotMatchesNewlines()),
              let json = try? JSONSerialization.jsonObject(with: Data(String(match.1).utf8))
        else { throw SpotifyError.unreadable }
        guard let entity = find(in: json, where: { ($0["trackList"] as? [Any]) != nil }),
              let list = entity["trackList"] as? [[String: Any]]
        else { throw SpotifyError.unreadable }
        let tracks = list.compactMap { item -> SpotifyTrack? in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
            let artists = ((item["subtitle"] as? String) ?? "").replacingOccurrences(of: "\u{00a0}", with: " ")
            return SpotifyTrack(title: title, artists: artists.trimmingCharacters(in: .whitespaces))
        }
        guard !tracks.isEmpty else { throw SpotifyError.unreadable }
        return SpotifyPlaylist(name: (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Playlist de Spotify", tracks: tracks)
    }

    private static func find(in node: Any, where predicate: ([String: Any]) -> Bool) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if predicate(dict) { return dict }
            for value in dict.values { if let hit = find(in: value, where: predicate) { return hit } }
        } else if let array = node as? [Any] {
            for value in array { if let hit = find(in: value, where: predicate) { return hit } }
        }
        return nil
    }
}

/// Picks the Tidal track that best matches a Spotify title + artists; nil when nothing is convincing.
public enum TrackMatcher {
    public static func best(for wanted: SpotifyTrack, in candidates: [TidalTrack]) -> TidalTrack? {
        var best: (track: TidalTrack, score: Double)?
        for candidate in candidates {
            let title = similarity(candidate.displayTitle, wanted.title)
            guard title >= 0.5 else { continue }
            let artist = similarity(candidate.allArtistNames, wanted.artists)
            let score = title * 0.6 + artist * 0.4
            if score > (best?.score ?? -1) { best = (candidate, score) }
        }
        guard let best, best.score >= 0.6 else { return nil }
        return best.track
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1 }
        if na.contains(nb) || nb.contains(na) { return 0.85 }
        let ta = Set(tokens(a)), tb = Set(tokens(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(max(ta.count, tb.count))
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
