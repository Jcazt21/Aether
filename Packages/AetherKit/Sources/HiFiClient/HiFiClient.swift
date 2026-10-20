public import Foundation

public enum HiFiError: Error, Equatable, Sendable {
    case http(Int)
    case decoding(String)
    case unsupportedManifest(String)
}

private struct Envelope<T: Decodable>: Decodable { let data: T }
private struct AlbumsHits: Decodable { let albums: Page<TidalAlbum> }
private struct AlbumItem: Decodable { let item: TidalTrack?; let type: String }

private struct AlbumDetailDTO: Decodable {
    let album: TidalAlbum
    let items: [AlbumItem]

    init(from decoder: any Decoder) throws {
        album = try TidalAlbum(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        items = try container.decodeIfPresent([LenientItem].self, forKey: .items)?.compactMap(\.value) ?? []
    }

    private enum Keys: String, CodingKey { case items }

    /// Video items don't decode as tracks; skip them instead of failing the album.
    private struct LenientItem: Decodable {
        let value: AlbumItem?
        init(from decoder: any Decoder) throws { value = try? AlbumItem(from: decoder) }
    }
}

public struct HiFiClient: Sendable {
    public let baseURL: URL
    public let imageBaseURL: URL
    private let session: URLSession

    public init(baseURL: URL, imageBaseURL: URL = URL(string: "https://resources.tidal.com/images")!,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.imageBaseURL = imageBaseURL
        self.session = session
    }

    public func ping() async -> Bool {
        guard let (_, response) = try? await session.data(from: baseURL) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    public func searchTracks(_ query: String, limit: Int = 50, offset: Int = 0) async throws -> Page<TidalTrack> {
        try await get("search/", ["s": query, "limit": "\(limit)", "offset": "\(offset)"], as: Envelope<Page<TidalTrack>>.self).data
    }

    public func searchAlbums(_ query: String, limit: Int = 25) async throws -> Page<TidalAlbum> {
        try await get("search/", ["al": query, "limit": "\(limit)"], as: Envelope<AlbumsHits>.self).data.albums
    }

    public func album(id: Int) async throws -> (album: TidalAlbum, tracks: [TidalTrack]) {
        let dto = try await get("album/", ["id": "\(id)", "limit": "500"], as: Envelope<AlbumDetailDTO>.self).data
        let ref = TidalAlbumRef(id: dto.album.id, title: dto.album.title, cover: dto.album.cover)
        let tracks = dto.items.filter { $0.type == "track" }.compactMap(\.item).map { track in
            var t = track
            if t.album == nil { t.album = ref }
            return t
        }
        return (dto.album, tracks)
    }

    public func playbackInfo(trackID: Int, quality: AudioQuality) async throws -> PlaybackInfo {
        try await get("track/", ["id": "\(trackID)", "quality": quality.rawValue], as: Envelope<PlaybackInfo>.self).data
    }

    public func coverURL(_ cover: String, size: Int = 1280) -> URL {
        imageBaseURL.appending(path: cover.replacingOccurrences(of: "-", with: "/")).appending(path: "\(size)x\(size).jpg")
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String], as type: T.Type) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HiFiError.http(status) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw HiFiError.decoding(String(describing: error)) }
    }
}
