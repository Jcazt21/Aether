# Aether v1 · Plan 04 — Harvester (motor de descarga + UI)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Buscar en Tidal, encolar, descargar DASH → FLAC nativo etiquetado, verificar automáticamente, dejarlo en la carpeta del Master y publicarlo en `rekordbox.xml`, con una UI de cola limpia y técnica.

**Architecture:** Módulo `HiFiClient` (modelos Tidal + parser MPD + cliente HTTP). Módulo `Harvester`: `HarvestPipeline` (pasos puros y testeables), `HarvestEngine` (actor: cola, concurrencia, eventos), `SegmentFetcher` (reintentos), `TagBuilder`, `HistoryStore`, `RekordboxXML`, `CheckpointStore`. En la app, `HarvesterStore` (`@MainActor @Observable`) consume `AsyncStream<HarvestEvent>` y actualiza un `JobModel` por fila. Las pruebas del motor corren contra un "Tidal falso" en `URLProtocol` con FLAC reales generados por AudioToolbox.

**Tech Stack:** Swift 6, URLSession, XMLParser, Synchronization (`Mutex`), SwiftUI (Table, searchable, toolbar), UserNotifications, Swift Testing, XCTest (UI).

**Spec:** `docs/superpowers/plans/2026-10-20-aether-v1-00-overview.md` (§2, §4, §6, §7 barra de progreso, §8 comandos, §9.1–9.4)

## Global Constraints

- macOS 27, Swift 6, cero dependencias de terceros. Trabajo pesado en funciones `@concurrent`, nunca en el MainActor.
- `URLSession` de audio: `urlCache = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`, `httpMaximumConnectionsPerHost = 6`, `waitsForConnectivity = true`, timeout de recurso 120 s.
- Concurrencia por defecto 3 pistas (1–4). Segmentos de una pista en secuencia.
- Reintentos por segmento: 4 intentos, backoff 0.5 s / 1 s / 2 s. HTTP 403 → refrescar manifiesto una vez y reintentar el mismo número de segmento.
- Fallo de integridad → borrar `.aether-part`, **un** reintento completo automático; después `failed`.
- Progreso emitido como máximo cada 100 ms por trabajo (los cambios de fase se emiten siempre).
- Política por defecto `hiResCapped96`: si `sampleRate > 96000`, pedir `LOSSLESS`.
- Nombre final `{artista principal} - {título (versión)}.flac`, único en la carpeta. GENRE = nombre de la carpeta destino salvo la carpeta de entrada.
- Copy en español; lecturas técnicas en SF Mono.

Rutas relativas a `~/Documents/Projects/Aether`. Pruebas de paquete: `swift test --package-path Packages/AetherKit`. App: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' test -quiet`.

---

### Task 1: Target `TestSupport` compartido (fixtures y stub HTTP)

**Files:**
- Modify: `Packages/AetherKit/Package.swift`
- Move: `Packages/AetherKit/Tests/FlacKitTests/AudioFixture.swift` → `Packages/AetherKit/Tests/TestSupport/AudioFixture.swift`
- Move: `Packages/AetherKit/Tests/FlacKitTests/MP4Fixture.swift` → `Packages/AetherKit/Tests/TestSupport/MP4Fixture.swift`
- Create: `Packages/AetherKit/Tests/TestSupport/StubURLProtocol.swift`
- Create: `Packages/AetherKit/Tests/TestSupport/ProgressBox.swift`
- Create: `Packages/AetherKit/Tests/TestSupport/Recorder.swift`
- Modify: `Packages/AetherKit/Tests/FlacKitTests/PCMDigestTests.swift` (quitar `ProgressBox`, `import TestSupport`)
- Modify: todos los archivos de `Tests/FlacKitTests/` → añadir `import TestSupport`

**Interfaces:**
- Produces (todo `public`): `AudioFixture.makeFLAC(...)`, `MP4Fixture.{be32, box, initSegment, mediaSegment}`, `ProgressBox`, `Recorder<Value>` (`append`, `values`), `Counter` (`increment()`, `value`), `StubURLProtocol.register(_ handler: @escaping @Sendable (URLRequest) throws -> (status: Int, body: Data)) -> URL` (devuelve una URL base `http://<uuid>.stub` única por prueba), `StubURLProtocol.session() -> URLSession`.

- [ ] **Step 1: Mover fixtures y declarar el target**

```bash
mkdir -p Packages/AetherKit/Tests/TestSupport
git mv Packages/AetherKit/Tests/FlacKitTests/AudioFixture.swift Packages/AetherKit/Tests/TestSupport/
git mv Packages/AetherKit/Tests/FlacKitTests/MP4Fixture.swift Packages/AetherKit/Tests/TestSupport/
```

En `Package.swift` añadir a `targets:` y actualizar las dependencias de `FlacKitTests`:

```swift
.target(name: "TestSupport", dependencies: ["TagKit"], path: "Tests/TestSupport", swiftSettings: settings),
.testTarget(name: "FlacKitTests", dependencies: ["FlacKit", "TagKit", "TestSupport"], swiftSettings: settings),
```

En `AudioFixture.swift` y `MP4Fixture.swift`: marcar `public` los `enum` y sus `static func`, y `public struct Failure` + `public let status`. En `MP4Fixture.swift` cambiar `import TagKit` por `public import TagKit`.

- [ ] **Step 2: `ProgressBox` y stub HTTP**

`Packages/AetherKit/Tests/TestSupport/ProgressBox.swift`:

```swift
import Synchronization

public final class ProgressBox: Sendable {
    private let storage = Mutex<[Double]>([])
    public init() {}
    public var values: [Double] {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
```

`Packages/AetherKit/Tests/TestSupport/Recorder.swift` (los `Mutex` no son copiables: no pueden capturarse directamente en closures `@escaping`, así que se envuelven en clases):

```swift
import Synchronization

public final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    public init() {}
    public func append(_ value: Value) { storage.withLock { $0.append(value) } }
    public var values: [Value] { storage.withLock { $0 } }
}

public final class Counter: Sendable {
    private let storage = Mutex(0)
    public init() {}
    @discardableResult public func increment() -> Int { storage.withLock { $0 += 1; return $0 } }
    public var value: Int { storage.withLock { $0 } }
}
```

Borrar la declaración `final class ProgressBox` de `PCMDigestTests.swift`.

`Packages/AetherKit/Tests/TestSupport/StubURLProtocol.swift`:

```swift
public import Foundation
import Synchronization

/// Routes requests by host to per-test handlers so suites can run in parallel.
public final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) throws -> (status: Int, body: Data)
    private static let handlers = Mutex<[String: Handler]>([:])

    /// Registers a handler and returns a unique base URL (`http://<uuid>.stub`) that routes to it.
    public static func register(_ handler: @escaping Handler) -> URL {
        let host = "\(UUID().uuidString.lowercased()).stub"
        handlers.withLock { $0[host] = handler }
        return URL(string: "http://\(host)")!
    }

    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override public class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".stub") == true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let handler = Self.handlers.withLock { $0[request.url?.host ?? ""] }
        do {
            guard let handler else { throw URLError(.cannotFindHost) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {}
}
```

Añadir `import TestSupport` al principio de cada archivo en `Tests/FlacKitTests/`.

- [ ] **Step 3: Verificar que nada se rompió**

Run: `swift test --package-path Packages/AetherKit`
Expected: todas las suites existentes PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "test: extract shared TestSupport target with audio fixtures and HTTP stub"
```

---

### Task 2: `HiFiClient` — modelos Tidal y cliente HTTP

**Files:**
- Modify: `Packages/AetherKit/Package.swift`
- Create: `Packages/AetherKit/Sources/HiFiClient/TidalModels.swift`
- Create: `Packages/AetherKit/Sources/HiFiClient/HiFiClient.swift`
- Test: `Packages/AetherKit/Tests/HiFiClientTests/HiFiClientTests.swift`

**Interfaces:**
- Consumes: `FileNaming.titleWithVersion` (TagKit).
- Produces:
  - `public struct TidalArtist: Codable, Sendable, Hashable { id: Int; name: String; type: String? }`
  - `public struct TidalAlbumRef: Codable, Sendable, Hashable { id: Int; title: String; cover: String? }`
  - `public struct TidalTrack: Codable, Sendable, Hashable, Identifiable` con `id, title, version, duration, trackNumber, volumeNumber, isrc, bpm: Double?, key, keyScale, copyright, explicit, audioQuality, mediaMetadata: MediaMetadata?, artist: TidalArtist?, artists: [TidalArtist]?, album: TidalAlbumRef?, replayGain, peak`; computed `displayTitle`, `primaryArtistName`, `allArtistNames`, `supportsHiRes`, `musicalKey: String?`
  - `public struct TidalAlbum: Codable, Sendable, Hashable, Identifiable` con `id, title, version, releaseDate, copyright, cover, numberOfTracks, upc, audioQuality, mediaMetadata, artists: [TidalArtist]?`; computed `primaryArtistName`, `supportsHiRes`, `year`
  - `public struct MediaMetadata: Codable, Sendable, Hashable { tags: [String] }`
  - `public struct Page<Item: Codable & Sendable>: Codable, Sendable { limit, offset, totalNumberOfItems: Int; items: [Item] }`
  - `public struct PlaybackInfo: Codable, Sendable` con `trackId, audioQuality, manifestMimeType, manifest, bitDepth: Int?, sampleRate: Int?, trackReplayGain, trackPeakAmplitude, albumReplayGain, albumPeakAmplitude: Double?`
  - `public enum AudioQuality: String, Sendable, Codable { case hiResLossless = "HI_RES_LOSSLESS", lossless = "LOSSLESS" }`
  - `public enum HiFiError: Error, Equatable { case http(Int); case decoding(String); case unsupportedManifest(String) }`
  - `public struct HiFiClient: Sendable` con `baseURL`, `imageBaseURL`, `init(baseURL: URL, imageBaseURL: URL = URL(string: "https://resources.tidal.com/images")!, session: URLSession = .shared)`, `ping() async -> Bool`, `searchTracks(_:limit:offset:) async throws -> Page<TidalTrack>`, `searchAlbums(_:limit:) async throws -> Page<TidalAlbum>`, `album(id:) async throws -> (album: TidalAlbum, tracks: [TidalTrack])`, `playbackInfo(trackID:quality:) async throws -> PlaybackInfo`, `coverURL(_ cover: String, size: Int = 1280) -> URL`

- [ ] **Step 1: Targets**

```swift
.library(name: "AetherKit", targets: ["ByteKit", "TagKit", "FlacKit", "HiFiClient"]),
```

```swift
.target(name: "HiFiClient", dependencies: ["TagKit"], swiftSettings: settings),
.testTarget(name: "HiFiClientTests", dependencies: ["HiFiClient", "TestSupport"], swiftSettings: settings),
```

- [ ] **Step 2: Pruebas que fallan (formas reales de la hifi-api v2.10, §2)**

`Packages/AetherKit/Tests/HiFiClientTests/HiFiClientTests.swift`:

```swift
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
```

Run: `swift test --package-path Packages/AetherKit --filter HiFiClientTests`
Expected: FAIL de compilación — `cannot find 'TidalTrack' in scope`.

- [ ] **Step 3: Modelos**

`Packages/AetherKit/Sources/HiFiClient/TidalModels.swift`:

```swift
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
    public var primaryArtistName: String { artist?.name ?? artists?.first?.name ?? "Desconocido" }

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

    public var primaryArtistName: String { artists?.first?.name ?? "Desconocido" }
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
}

public enum AudioQuality: String, Sendable, Codable {
    case hiResLossless = "HI_RES_LOSSLESS"
    case lossless = "LOSSLESS"
}
```

- [ ] **Step 4: Cliente**

`Packages/AetherKit/Sources/HiFiClient/HiFiClient.swift`:

```swift
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
```

- [ ] **Step 5: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter HiFiClientTests`
Expected: 6 PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(hificlient): add Tidal models and hifi-api HTTP client"
```

---

### Task 3: Parser del manifiesto DASH

**Files:**
- Create: `Packages/AetherKit/Sources/HiFiClient/DashManifest.swift`
- Test: `Packages/AetherKit/Tests/HiFiClientTests/DashManifestTests.swift`

**Interfaces:**
- Produces:
  - `public struct DashManifest: Equatable, Sendable` con `representationID`, `codecs`, `sampleRate: Int`, `channels: Int?`, `bandwidth: Int?`, `timescale: Int`, `initializationURL: URL`, `mediaTemplate: String`, `startNumber: Int`, `segmentDurations: [Int]`, `presentationDuration: Double?`; computed `segmentCount`, `segmentNumbers: Range<Int>`, `totalSamples: UInt64`, `bitDepth: Int?`, `estimatedBytes: Int64?`; `func mediaURL(number: Int) -> URL`; `static func parse(_ xml: Data) throws -> DashManifest`
  - `extension PlaybackInfo { func dashManifest() throws -> DashManifest }`
  - `public enum DashError: Error, Equatable { case missing(String) }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/HiFiClientTests/DashManifestTests.swift`:

```swift
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
```

Run: `swift test --package-path Packages/AetherKit --filter DashManifestTests`
Expected: FAIL de compilación — `cannot find 'DashManifest' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/HiFiClient/DashManifest.swift`:

```swift
public import Foundation

public enum DashError: Error, Equatable, Sendable { case missing(String) }

public struct DashManifest: Equatable, Sendable {
    public var representationID: String
    public var codecs: String
    public var sampleRate: Int
    public var channels: Int?
    public var bandwidth: Int?
    public var timescale: Int
    public var initializationURL: URL
    public var mediaTemplate: String
    public var startNumber: Int
    public var segmentDurations: [Int]
    public var presentationDuration: Double?

    public var segmentCount: Int { segmentDurations.count }
    public var segmentNumbers: Range<Int> { startNumber..<(startNumber + segmentCount) }

    /// PCM frames in the stream (timeline units rescaled to the sample rate).
    public var totalSamples: UInt64 {
        let units = segmentDurations.reduce(UInt64(0)) { $0 + UInt64($1) }
        return timescale == sampleRate ? units : units * UInt64(sampleRate) / UInt64(timescale)
    }

    /// "FLAC_HIRES,44100,24" → 24.
    public var bitDepth: Int? { representationID.split(separator: ",").last.flatMap { Int($0) } }

    public var estimatedBytes: Int64? {
        guard let bandwidth, let presentationDuration else { return nil }
        return Int64(Double(bandwidth) * presentationDuration / 8)
    }

    public func mediaURL(number: Int) -> URL {
        URL(string: mediaTemplate
            .replacingOccurrences(of: "$Number$", with: String(number))
            .replacingOccurrences(of: "$RepresentationID$", with: representationID))!
    }

    public static func parse(_ xml: Data) throws -> DashManifest {
        let delegate = MPDParserDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        guard let rep = delegate.representation else { throw DashError.missing("Representation") }
        guard let template = delegate.template else { throw DashError.missing("SegmentTemplate") }
        guard let initString = template["initialization"], let initURL = URL(string: initString) else {
            throw DashError.missing("initialization")
        }
        guard let media = template["media"] else { throw DashError.missing("media") }
        guard let rate = rep["audioSamplingRate"].flatMap(Int.init) else { throw DashError.missing("audioSamplingRate") }
        return DashManifest(
            representationID: rep["id"] ?? "",
            codecs: rep["codecs"] ?? "",
            sampleRate: rate,
            channels: delegate.channels,
            bandwidth: rep["bandwidth"].flatMap(Int.init),
            timescale: template["timescale"].flatMap(Int.init) ?? rate,
            initializationURL: initURL,
            mediaTemplate: media,
            startNumber: template["startNumber"].flatMap(Int.init) ?? 1,
            segmentDurations: delegate.durations,
            presentationDuration: delegate.presentationDuration)
    }
}

extension PlaybackInfo {
    public func dashManifest() throws -> DashManifest {
        guard manifestMimeType == "application/dash+xml", let data = Data(base64Encoded: manifest) else {
            throw HiFiError.unsupportedManifest(manifestMimeType)
        }
        return try DashManifest.parse(data)
    }
}

/// Collects the first audio Representation of the first Period. XML entities (&amp;) are decoded by XMLParser.
private final class MPDParserDelegate: NSObject, XMLParserDelegate {
    var representation: [String: String]?
    var template: [String: String]?
    var channels: Int?
    var durations: [Int] = []
    var presentationDuration: Double?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "MPD":
            presentationDuration = attributes["mediaPresentationDuration"].flatMap(Self.seconds(fromISO8601:))
        case "Representation" where representation == nil:
            representation = attributes
        case "AudioChannelConfiguration" where channels == nil:
            channels = attributes["value"].flatMap(Int.init)
        case "SegmentTemplate" where template == nil:
            template = attributes
        case "S":
            guard let d = attributes["d"].flatMap(Int.init) else { return }
            let repeats = attributes["r"].flatMap(Int.init) ?? 0
            durations.append(contentsOf: repeatElement(d, count: max(repeats, 0) + 1))
        default:
            break
        }
    }

    /// "PT3M56.249S" → 236.249
    static func seconds(fromISO8601 value: String) -> Double? {
        guard value.hasPrefix("PT") else { return nil }
        var total = 0.0
        var number = ""
        for ch in value.dropFirst(2) {
            switch ch {
            case "H": total += (Double(number) ?? 0) * 3600; number = ""
            case "M": total += (Double(number) ?? 0) * 60; number = ""
            case "S": total += Double(number) ?? 0; number = ""
            default: number.append(ch)
            }
        }
        return (total * 1000).rounded() / 1000
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter DashManifestTests`
Expected: 4 PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(hificlient): parse Tidal DASH manifests and segment timelines"
```

---

### Task 4: Harvester — modelos, `TagBuilder`, `LabelParser` y `SegmentFetcher`

**Files:**
- Modify: `Packages/AetherKit/Package.swift`
- Create: `Packages/AetherKit/Sources/Harvester/HarvestModels.swift`
- Create: `Packages/AetherKit/Sources/Harvester/TagBuilder.swift`
- Create: `Packages/AetherKit/Sources/Harvester/SegmentFetcher.swift`
- Test: `Packages/AetherKit/Tests/HarvesterTests/TagBuilderTests.swift`
- Test: `Packages/AetherKit/Tests/HarvesterTests/SegmentFetcherTests.swift`

**Interfaces:**
- Consumes: `TidalTrack`, `TidalAlbum`, `PlaybackInfo` (Task 2), `TrackTags`, `IntegrityReport`.
- Produces:
  - `public enum QualityPolicy: String, Codable, Sendable, CaseIterable { case hiResCapped96, hiRes, lossless; var initialQuality: AudioQuality; var title: String }`
  - `public struct HarvestRequest: Codable, Sendable, Hashable, Identifiable { id: UUID; track: TidalTrack; destinationFolder: URL; genre: String?; policy: QualityPolicy; createdAt: Date; init(track:destinationFolder:genre:policy:) }`
  - `public struct FormatSummary: Codable, Sendable, Equatable { sampleRate: Int; bitDepth: Int; channels: Int; duration: Double; var label: String }`
  - `public struct HarvestResult: Codable, Sendable, Equatable { fileURL: URL; report: IntegrityReport; format: FormatSummary; bytes: Int64; finishedAt: Date }`
  - `public enum HarvestPhase: Sendable, Equatable { queued, resolving, downloading(segment: Int, of: Int, bytes: Int64, bytesPerSecond: Double), verifying(Double), verified(HarvestResult), failed(String), cancelled; var isActive: Bool; var isTerminal: Bool }`
  - `public struct HarvestEvent: Sendable { id: UUID; phase: HarvestPhase }`
  - `public enum HarvestError: Error, Equatable { case http(Int); case integrity(String); case cancelled }`
  - `public enum LabelParser { static func label(fromCopyright: String?) -> String? }`
  - `public enum TagBuilder { static func tags(track:album:genre:artwork:) -> TrackTags; static func replayGainFields(_ info: PlaybackInfo) -> [String: String] }`
  - `public struct SegmentFetcher: Sendable { init(session: URLSession, maxAttempts: Int = 4, backoff: @escaping @Sendable (Int) -> Duration = { .milliseconds(500 << $0) }); func fetch(_ url: URL) async throws -> [UInt8]; func fetchOptional(_ url: URL) async -> Data?; static func makeAudioSession() -> URLSession }`

- [ ] **Step 1: Target**

```swift
.library(name: "AetherKit", targets: ["ByteKit", "TagKit", "FlacKit", "HiFiClient", "Harvester"]),
```

```swift
.target(name: "Harvester", dependencies: ["HiFiClient", "FlacKit", "TagKit"], swiftSettings: settings),
.testTarget(name: "HarvesterTests", dependencies: ["Harvester", "TestSupport"], swiftSettings: settings),
```

- [ ] **Step 2: Pruebas que fallan**

`Packages/AetherKit/Tests/HarvesterTests/TagBuilderTests.swift`:

```swift
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
```

`Packages/AetherKit/Tests/HarvesterTests/SegmentFetcherTests.swift`:

```swift
import Foundation
import Testing
@testable import Harvester
import TestSupport

@Suite struct SegmentFetcherTests {
    private func fetcher() -> SegmentFetcher {
        SegmentFetcher(session: StubURLProtocol.session(), maxAttempts: 4, backoff: { _ in .milliseconds(1) })
    }

    @Test func retriesTransientFailuresThenSucceeds() async throws {
        let calls = Counter()
        let base = StubURLProtocol.register { _ in
            calls.increment() < 3 ? (503, Data()) : (200, Data([1, 2, 3]))
        }
        let bytes = try await fetcher().fetch(base.appending(path: "seg"))
        #expect(bytes == [1, 2, 3])
        #expect(calls.value == 3)
    }

    @Test func forbiddenIsNotRetried() async {
        let calls = Counter()
        let base = StubURLProtocol.register { _ in calls.increment(); return (403, Data()) }
        await #expect(throws: HarvestError.http(403)) { try await fetcher().fetch(base.appending(path: "seg")) }
        #expect(calls.value == 1)
    }

    @Test func givesUpAfterMaxAttempts() async {
        let base = StubURLProtocol.register { _ in (500, Data()) }
        await #expect(throws: HarvestError.http(500)) { try await fetcher().fetch(base.appending(path: "seg")) }
    }

    @Test func optionalFetchSwallowsErrors() async {
        let base = StubURLProtocol.register { _ in (404, Data()) }
        #expect(await fetcher().fetchOptional(base.appending(path: "cover.jpg")) == nil)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter "TagBuilderTests|SegmentFetcherTests"`
Expected: FAIL de compilación — `cannot find 'LabelParser' in scope`.

- [ ] **Step 3: Modelos**

`Packages/AetherKit/Sources/Harvester/HarvestModels.swift`:

```swift
public import FlacKit
public import Foundation
public import HiFiClient

public enum QualityPolicy: String, Codable, Sendable, CaseIterable {
    case hiResCapped96, hiRes, lossless

    public var initialQuality: AudioQuality { self == .lossless ? .lossless : .hiResLossless }

    public var title: String {
        switch self {
        case .hiResCapped96: "Hi-Res ≤ 96 kHz (CDJ)"
        case .hiRes: "Hi-Res máximo"
        case .lossless: "Siempre 16 bit / 44.1 kHz"
        }
    }
}

public struct HarvestRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var track: TidalTrack
    public var destinationFolder: URL
    public var genre: String?
    public var policy: QualityPolicy
    public var createdAt: Date

    public init(track: TidalTrack, destinationFolder: URL, genre: String?, policy: QualityPolicy) {
        id = UUID()
        self.track = track
        self.destinationFolder = destinationFolder
        self.genre = genre
        self.policy = policy
        createdAt = Date()
    }
}

public struct FormatSummary: Codable, Sendable, Equatable {
    public var sampleRate: Int
    public var bitDepth: Int
    public var channels: Int
    public var duration: Double

    public init(sampleRate: Int, bitDepth: Int, channels: Int, duration: Double) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.duration = duration
    }

    /// "FLAC · 24/96" style, kHz without trailing zeros.
    public var label: String {
        let khz = Double(sampleRate) / 1000
        let rate = khz.rounded() == khz ? String(Int(khz)) : String(format: "%.1f", khz)
        return "FLAC · \(bitDepth)/\(rate)"
    }
}

public struct HarvestResult: Codable, Sendable, Equatable {
    public var fileURL: URL
    public var report: IntegrityReport
    public var format: FormatSummary
    public var bytes: Int64
    public var finishedAt: Date
}

public enum HarvestPhase: Sendable, Equatable {
    case queued
    case resolving
    case downloading(segment: Int, of: Int, bytes: Int64, bytesPerSecond: Double)
    case verifying(Double)
    case verified(HarvestResult)
    case failed(String)
    case cancelled

    public var isActive: Bool {
        switch self {
        case .resolving, .downloading, .verifying: true
        default: false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .verified, .failed, .cancelled: true
        default: false
        }
    }
}

public struct HarvestEvent: Sendable {
    public var id: UUID
    public var phase: HarvestPhase
}

public enum HarvestError: Error, Equatable, Sendable {
    case http(Int)
    case integrity(String)
    case cancelled
}
```

- [ ] **Step 4: `TagBuilder` y `LabelParser`**

`Packages/AetherKit/Sources/Harvester/TagBuilder.swift`:

```swift
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
```

- [ ] **Step 5: `SegmentFetcher`**

`Packages/AetherKit/Sources/Harvester/SegmentFetcher.swift`:

```swift
public import Foundation

public struct SegmentFetcher: Sendable {
    private let session: URLSession
    private let maxAttempts: Int
    private let backoff: @Sendable (Int) -> Duration

    public init(session: URLSession, maxAttempts: Int = 4,
                backoff: @escaping @Sendable (Int) -> Duration = { .milliseconds(500 << $0) }) {
        self.session = session
        self.maxAttempts = maxAttempts
        self.backoff = backoff
    }

    /// Audio session: no URL cache (never duplicate tens of MB in ~/Library/Caches), fresh responses only.
    public static func makeAudioSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    /// Retries network errors, 429 and 5xx with backoff. 4xx (notably 403 = expired signature) fail immediately.
    public func fetch(_ url: URL) async throws -> [UInt8] {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return [UInt8](data) }
                let retryable = status == 429 || status >= 500
                guard retryable, attempt + 1 < maxAttempts else { throw HarvestError.http(status) }
            } catch let error as URLError where error.code != .cancelled && attempt + 1 < maxAttempts {
                // fall through to backoff
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            }
            try await Task.sleep(for: backoff(attempt))
            attempt += 1
        }
    }

    public func fetchOptional(_ url: URL) async -> Data? {
        (try? await fetch(url)).map { Data($0) }
    }
}
```

- [ ] **Step 6: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter "TagBuilderTests|SegmentFetcherTests"`
Expected: 14 PASS (6 parametrizadas de etiqueta + 4 + 4).

- [ ] **Step 7: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(harvester): add request models, rekordbox tag builder and retrying segment fetcher"
```

---

### Task 5: `HarvestPipeline` — resolver, descargar, verificar, finalizar (contra un Tidal falso)

**Files:**
- Create: `Packages/AetherKit/Sources/Harvester/HarvestPipeline.swift`
- Create: `Packages/AetherKit/Sources/Harvester/ProgressThrottle.swift`
- Create: `Packages/AetherKit/Tests/HarvesterTests/FakeTidal.swift`
- Test: `Packages/AetherKit/Tests/HarvesterTests/HarvestPipelineTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4, `FMP4Flac`, `FlacAssembler`, `IntegrityVerifier`, `FlacTags`, `FlacMetadataIO`, `VorbisComment`, `FlacPicture`, `FileNaming`.
- Produces:
  - `struct ProgressThrottle { init(interval: Duration = .milliseconds(100)); mutating func shouldEmit(now: ContinuousClock.Instant) -> Bool }` (internal)
  - `struct ThroughputMeter { mutating func add(_ bytes: Int, at: ContinuousClock.Instant); var bytesPerSecond: Double }` (internal)
  - `public struct HarvestPipeline: Sendable` con `init(client: HiFiClient, fetcher: SegmentFetcher, albumLookup: @escaping @Sendable (Int) async -> TidalAlbum?, now: @escaping @Sendable () -> Date = Date.init)`, `func execute(_ request: HarvestRequest, resume: AssemblerCheckpoint? = nil, checkpoint: (@Sendable (AssemblerCheckpoint) -> Void)? = nil, emit: @escaping @Sendable (HarvestPhase) -> Void) async throws -> HarvestResult`, `static func partURL(for: HarvestRequest) -> URL`

- [ ] **Step 1: Tidal falso con FLAC reales**

`Packages/AetherKit/Tests/HarvesterTests/FakeTidal.swift`:

```swift
import CryptoKit
import FlacKit
import Foundation
import HiFiClient
import Synchronization
import TagKit
import TestSupport

/// Serves /track, /album, init and media segments built from a real AudioToolbox-encoded FLAC.
final class FakeTidal: Sendable {
    private final class State: Sendable {
        let forbiddenOnce = Mutex<Set<Int>>([])
        let manifestRequests = Counter()
    }

    let base: URL
    let streamInfo: StreamInfo
    let expectedSamples: UInt64
    private let state = State()

    var manifestRequestCount: Int { state.manifestRequests.value }
    var client: HiFiClient { HiFiClient(baseURL: base, imageBaseURL: base.appending(path: "images"), session: StubURLProtocol.session()) }

    init(seconds: Double = 3, bits: Int = 24, sampleRate: Int = 44_100, reportedSampleRate: Int? = nil,
         corruptSegment: Int? = nil, expireSegmentOnce: Int? = nil) throws {
        let (url, pcm) = try AudioFixture.makeFLAC(seconds: seconds, sampleRate: Double(sampleRate), bits: bits)
        var header = try FlacMetadataIO.read(url)
        var si = try header.streamInfo()
        si.md5 = Array(Insecure.MD5.hash(data: pcm))
        header.blocks[0] = si.block
        try FlacMetadataIO.write(header.blocks, to: url)
        streamInfo = si
        expectedSamples = UInt64(pcm.count / (2 * bits / 8))

        let bytes = [UInt8](try Data(contentsOf: url))
        let scan = try FlacFrameScanner.scan(fileAt: url, collectOffsets: true)
        let offsets = scan.frameOffsets! + [bytes.count]
        let frames = (0..<scan.frames).map { Array(bytes[offsets[$0]..<offsets[$0 + 1]]) }
        let block = Int(si.maxBlockSize)
        var segments: [[UInt8]] = []
        var durations: [Int] = []
        let body = Array(frames.dropLast())
        for start in stride(from: 0, to: body.count, by: 43) {
            let chunk = Array(body[start..<min(start + 43, body.count)])
            segments.append(MP4Fixture.mediaSegment(frames: chunk, duration: UInt32(block)))
            durations.append(chunk.count * block)
        }
        let tail = Int(si.totalSamples) - (frames.count - 1) * block
        segments.append(MP4Fixture.mediaSegment(frames: [frames.last!], duration: UInt32(tail)))
        durations.append(tail)
        if let bad = corruptSegment {
            var seg = segments[bad - 1]
            seg[seg.count - 100] ^= 0x01
            segments[bad - 1] = seg
        }
        if let expire = expireSegmentOnce { state.forbiddenOnce.withLock { _ = $0.insert(expire) } }

        let initSegment = MP4Fixture.initSegment(streamInfo: si)
        let timeline = durations.map { #"<S d="\#($0)"/>"# }.joined()
        let state = state
        let rate = reportedSampleRate ?? sampleRate
        let segs = segments
        base = StubURLProtocol.register { request in
            let url = request.url!
            let origin = "http://\(url.host!)"
            switch url.path {
            case "/track/":
                state.manifestRequests.increment()
                let mpd = """
                <MPD mediaPresentationDuration="PT\(seconds)S"><Period><AdaptationSet mimeType="audio/mp4"><Representation id="FLAC,\(sampleRate),\(bits)" codecs="flac" bandwidth="1000000" audioSamplingRate="\(sampleRate)"><AudioChannelConfiguration value="2"/><SegmentTemplate timescale="\(sampleRate)" initialization="\(origin)/init.mp4" media="\(origin)/seg/$Number$.mp4" startNumber="1"><SegmentTimeline>\(timeline)</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>
                """
                let json = #"{"version":"2.10","data":{"trackId":1,"audioQuality":"HI_RES_LOSSLESS","manifestMimeType":"application/dash+xml","manifest":"\#(Data(mpd.utf8).base64EncodedString())","bitDepth":\#(bits),"sampleRate":\#(rate),"trackReplayGain":-9.5,"trackPeakAmplitude":0.99}}"#
                return (200, Data(json.utf8))
            case "/album/":
                return (200, Data(#"{"version":"2.10","data":{"id":9,"title":"Fixture EP","releaseDate":"2026-01-02","copyright":"(C) 2026 Test Records","artists":[{"id":1,"name":"Fixture","type":"MAIN"}],"items":[]}}"#.utf8))
            case "/init.mp4":
                return (200, Data(initSegment))
            case let path where path.hasPrefix("/seg/"):
                let n = Int(url.deletingPathExtension().lastPathComponent)!
                if state.forbiddenOnce.withLock({ $0.remove(n) != nil }) { return (403, Data()) }
                return (200, Data(segs[n - 1]))
            case let path where path.hasPrefix("/images/"):
                return (200, Data([0xFF, 0xD8, 0xFF, 0xD9]))
            default:
                return (404, Data())
            }
        }
    }

    static func track() throws -> TidalTrack {
        try JSONDecoder().decode(TidalTrack.self, from: Data("""
        {"id":1,"title":"Tone","version":"Original Mix","duration":3,"trackNumber":1,"volumeNumber":1,
         "artist":{"id":1,"name":"Fixture","type":"MAIN"},"artists":[{"id":1,"name":"Fixture","type":"MAIN"}],
         "album":{"id":9,"title":"Fixture EP","cover":"aa-bb"}}
        """.utf8))
    }
}
```

- [ ] **Step 2: Pruebas que fallan**

`Packages/AetherKit/Tests/HarvesterTests/HarvestPipelineTests.swift`:

```swift
import FlacKit
import Foundation
import HiFiClient
import TagKit
import Testing
@testable import Harvester
import TestSupport

@Suite struct HarvestPipelineTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "harvest-\(UUID().uuidString)/UK House")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pipeline(_ fake: FakeTidal) -> HarvestPipeline {
        let client = fake.client
        return HarvestPipeline(
            client: client,
            fetcher: SegmentFetcher(session: StubURLProtocol.session(), backoff: { _ in .milliseconds(1) }),
            albumLookup: { id in try? await client.album(id: id).album },
            now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func downloadsTagsAndVerifiesBitPerfect() async throws {
        let fake = try FakeTidal()
        let dest = try folder()
        let request = HarvestRequest(track: try FakeTidal.track(), destinationFolder: dest, genre: "UK House", policy: .hiResCapped96)
        let phases = Recorder<HarvestPhase>()
        let result = try await pipeline(fake).execute(request) { phases.append($0) }

        #expect(result.fileURL.lastPathComponent == "Fixture - Tone (Original Mix).flac")
        #expect(result.report.verdict == .verified)
        #expect(result.format == FormatSummary(sampleRate: 44_100, bitDepth: 24, channels: 2, duration: Double(fake.expectedSamples) / 44_100))
        let (tags, si, header) = try FlacTags.read(result.fileURL)
        #expect(si.totalSamples == fake.expectedSamples)
        #expect(tags.genre == "UK House")
        #expect(tags.label == "Test Records")
        #expect(tags.artwork?.data == Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let vorbis = try VorbisComment(payload: header.blocks(ofType: FlacBlockType.vorbisComment)[0].payload)
        #expect(vorbis.first("AETHER_VERIFIED") == "md5:\(si.md5Hex);1970-01-01T00:00:00Z")
        #expect(vorbis.first("REPLAYGAIN_TRACK_GAIN") == "-9.50 dB")
        #expect(try IntegrityVerifier.verify(flacAt: result.fileURL).verdict == .verified)

        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        #expect(names == ["Fixture - Tone (Original Mix).flac"])
        let recorded = phases.values
        #expect(recorded.first == .resolving)
        #expect(recorded.contains { if case .downloading = $0 { true } else { false } })
        #expect(recorded.contains { if case .verifying = $0 { true } else { false } })
    }

    @Test func expiredSignatureRefreshesManifestAndContinues() async throws {
        let fake = try FakeTidal(expireSegmentOnce: 2)
        let request = HarvestRequest(track: try FakeTidal.track(), destinationFolder: try folder(), genre: nil, policy: .hiRes)
        let result = try await pipeline(fake).execute(request) { _ in }
        #expect(result.report.verdict == .verified)
        #expect(fake.manifestRequestCount == 2)
    }

    @Test func corruptedSegmentFailsIntegrityAndLeavesNoFiles() async throws {
        let fake = try FakeTidal(corruptSegment: 1)
        let dest = try folder()
        let request = HarvestRequest(track: try FakeTidal.track(), destinationFolder: dest, genre: nil, policy: .hiRes)
        await #expect(throws: HarvestError.self) { try await pipeline(fake).execute(request) { _ in } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    @Test func capPolicyDowngradesAbove96k() async throws {
        let fake = try FakeTidal(reportedSampleRate: 192_000)
        let request = HarvestRequest(track: try FakeTidal.track(), destinationFolder: try folder(), genre: nil, policy: .hiResCapped96)
        _ = try await pipeline(fake).execute(request) { _ in }
        #expect(fake.manifestRequestCount == 2)  // HI_RES then LOSSLESS
    }

    @Test func throttleLimitsEmissionRate() {
        var throttle = ProgressThrottle(interval: .milliseconds(100))
        let t0 = ContinuousClock.now
        #expect(throttle.shouldEmit(now: t0))
        #expect(!throttle.shouldEmit(now: t0.advanced(by: .milliseconds(50))))
        #expect(throttle.shouldEmit(now: t0.advanced(by: .milliseconds(120))))
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter HarvestPipelineTests`
Expected: FAIL de compilación — `cannot find 'HarvestPipeline' in scope`.

- [ ] **Step 3: Utilidades de progreso**

`Packages/AetherKit/Sources/Harvester/ProgressThrottle.swift`:

```swift
struct ProgressThrottle {
    private let interval: Duration
    private var last: ContinuousClock.Instant?

    init(interval: Duration = .milliseconds(100)) { self.interval = interval }

    mutating func shouldEmit(now: ContinuousClock.Instant = .now) -> Bool {
        if let last, now - last < interval { return false }
        last = now
        return true
    }
}

/// Exponentially smoothed throughput (bytes/s) — stable readout, no per-sample array.
struct ThroughputMeter {
    private var lastSample: ContinuousClock.Instant?
    private(set) var bytesPerSecond: Double = 0

    mutating func add(_ bytes: Int, at now: ContinuousClock.Instant = .now) {
        defer { lastSample = now }
        guard let last = lastSample else { return }
        let seconds = Double((now - last).components.attoseconds) / 1e18 + Double((now - last).components.seconds)
        guard seconds > 0 else { return }
        let instant = Double(bytes) / seconds
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
    }
}
```

- [ ] **Step 4: Pipeline**

`Packages/AetherKit/Sources/Harvester/HarvestPipeline.swift`:

```swift
public import FlacKit
public import Foundation
public import HiFiClient
import OSLog
import TagKit

public struct HarvestPipeline: Sendable {
    private static let log = Logger(subsystem: "com.jazar.Aether", category: "harvester")
    private static let signposter = OSSignposter(logger: log)

    private let client: HiFiClient
    private let fetcher: SegmentFetcher
    private let albumLookup: @Sendable (Int) async -> TidalAlbum?
    private let now: @Sendable () -> Date

    public init(client: HiFiClient, fetcher: SegmentFetcher,
                albumLookup: @escaping @Sendable (Int) async -> TidalAlbum?,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.fetcher = fetcher
        self.albumLookup = albumLookup
        self.now = now
    }

    public static func partURL(for request: HarvestRequest) -> URL {
        request.destinationFolder.appending(path: ".\(request.id.uuidString).aether-part")
    }

    @concurrent
    public func execute(_ request: HarvestRequest, resume: AssemblerCheckpoint? = nil,
                        checkpoint: (@Sendable (AssemblerCheckpoint) -> Void)? = nil,
                        emit: @escaping @Sendable (HarvestPhase) -> Void) async throws -> HarvestResult {
        let part = Self.partURL(for: request)
        do {
            return try await run(request, part: part, resume: resume, checkpoint: checkpoint, emit: emit)
        } catch {
            if !(error is CancellationError) { try? FileManager.default.removeItem(at: part) }
            throw error
        }
    }

    private func run(_ request: HarvestRequest, part: URL, resume: AssemblerCheckpoint?,
                     checkpoint: (@Sendable (AssemblerCheckpoint) -> Void)?,
                     emit: @escaping @Sendable (HarvestPhase) -> Void) async throws -> HarvestResult {
        let track = request.track
        emit(.resolving)

        // 1. Resolve — metadata and artwork in parallel with the manifest, so the FLAC header is final before audio.
        async let album = albumLookup(track.album?.id ?? 0)
        async let artwork = fetchArtwork(track)
        var info = try await client.playbackInfo(trackID: track.id, quality: request.policy.initialQuality)
        if request.policy == .hiResCapped96, (info.sampleRate ?? 0) > 96_000 {
            info = try await client.playbackInfo(trackID: track.id, quality: .lossless)
        }
        var manifest = try info.dashManifest()
        let config = try FMP4Flac.parseInit(try await fetcher.fetch(manifest.initializationURL))
        let tags = TagBuilder.tags(track: track, album: await album, genre: request.genre,
                                   artwork: await artwork.map { TrackTags.Artwork(data: $0, mimeType: "image/jpeg") })

        // 2. Download — header first, then frames segment by segment.
        try FileManager.default.createDirectory(at: request.destinationFolder, withIntermediateDirectories: true)
        let assembler: FlacAssembler
        if let resume, FileManager.default.fileExists(atPath: part.path) {
            assembler = try FlacAssembler(resuming: part, from: resume)
        } else {
            let header = FlacHeader(blocks: config.metadataBlocks, audioOffset: 0)
            var blocks = try FlacTags.blocks(applying: tags, to: header, extraFields: TagBuilder.replayGainFields(info))
            blocks.append(.padding(8192))
            assembler = try FlacAssembler(partURL: part, headerBlocks: blocks)
        }

        let downloadInterval = Self.signposter.beginInterval("download", id: Self.signposter.makeSignpostID())
        var throttle = ProgressThrottle()
        var meter = ThroughputMeter()
        var received: Int64 = 0
        let numbers = Array(manifest.segmentNumbers)
        for (index, number) in numbers.enumerated().dropFirst(assembler.checkpoint.segmentsWritten) {
            try Task.checkCancellation()
            let bytes: [UInt8]
            do {
                bytes = try await fetcher.fetch(manifest.mediaURL(number: number))
            } catch HarvestError.http(403) {
                Self.log.info("segment \(number) expired; refreshing manifest")
                info = try await client.playbackInfo(trackID: track.id, quality: AudioQuality(rawValue: info.audioQuality) ?? .lossless)
                manifest = try info.dashManifest()
                bytes = try await fetcher.fetch(manifest.mediaURL(number: number))
            }
            try assembler.append(segment: bytes)
            checkpoint?(assembler.checkpoint)
            received += Int64(bytes.count)
            meter.add(bytes.count)
            if throttle.shouldEmit() || index == numbers.count - 1 {
                emit(.downloading(segment: index + 1, of: numbers.count, bytes: received, bytesPerSecond: meter.bytesPerSecond))
            }
        }
        try assembler.finish()
        Self.signposter.endInterval("download", downloadInterval)

        // 3. Verify — frame CRCs, sample counts (vs. MPD timeline) and PCM MD5 vs. the source MD5.
        emit(.verifying(0))
        let verifyInterval = Self.signposter.beginInterval("verify", id: Self.signposter.makeSignpostID())
        var verifyThrottle = ProgressThrottle()
        let report = try IntegrityVerifier.verify(flacAt: part, expectedSamples: manifest.totalSamples) { fraction in
            if verifyThrottle.shouldEmit() { emit(.verifying(fraction)) }
        }
        Self.signposter.endInterval("verify", verifyInterval)
        guard report.verdict == .verified else { throw HarvestError.integrity(report.failure ?? "Integridad") }

        // 4. Finalize — stamp verification (in place, inside padding) and move atomically.
        try FlacTags.write(tags, to: part, extraFields: TagBuilder.replayGainFields(info).merging(
            [IntegrityVerifier.verifiedFieldKey: IntegrityVerifier.verifiedFieldValue(report, at: now())]) { $1 })
        let base = FileNaming.baseName(artist: track.primaryArtistName, title: track.displayTitle, fallback: "tidal-\(track.id)")
        let final = try Self.moveToUniqueName(part, folder: request.destinationFolder, baseName: base)

        let si = config.streamInfo
        let size = (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return HarvestResult(
            fileURL: final, report: report,
            format: FormatSummary(sampleRate: Int(si.sampleRate), bitDepth: Int(si.bitsPerSample),
                                  channels: Int(si.channels), duration: si.duration),
            bytes: size, finishedAt: now())
    }
}

extension HarvestPipeline {
    private func fetchArtwork(_ track: TidalTrack) async -> Data? {
        guard let cover = track.album?.cover else { return nil }
        return await fetcher.fetchOptional(client.coverURL(cover))
    }

    /// Concurrent jobs may target the same name: retry with the next free counter instead of failing.
    static func moveToUniqueName(_ source: URL, folder: URL, baseName: String) throws -> URL {
        for _ in 0..<20 {
            let candidate = FileNaming.uniqueURL(in: folder, baseName: baseName, extension: "flac")
            do {
                try FileManager.default.moveItem(at: source, to: candidate)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
```

- [ ] **Step 5: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter HarvestPipelineTests`
Expected: 5 PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(harvester): download, tag and verify DASH tracks into native FLAC"
```

---

### Task 6: `HarvestEngine` (actor de cola) y `CheckpointStore` (reanudación)

**Files:**
- Create: `Packages/AetherKit/Sources/Harvester/HarvestEngine.swift`
- Create: `Packages/AetherKit/Sources/Harvester/CheckpointStore.swift`
- Test: `Packages/AetherKit/Tests/HarvesterTests/HarvestEngineTests.swift`

**Interfaces:**
- Consumes: `HarvestPipeline`, `AssemblerCheckpoint`.
- Produces:
  - `public actor CheckpointStore { init(fileURL: URL); func checkpoint(for id: UUID) -> AssemblerCheckpoint?; func save(_ c: AssemblerCheckpoint, for id: UUID); func remove(_ id: UUID) }` — persiste cada 5 segmentos o al quitar.
  - `public actor HarvestEngine` con `nonisolated let events: AsyncStream<HarvestEvent>`, `init(pipeline: HarvestPipeline, checkpoints: CheckpointStore?, maxConcurrent: Int = 3)`, `func setMaxConcurrent(_:)`, `func setPipeline(_:)`, `func enqueue(_ requests: [HarvestRequest])`, `func cancel(_ id: UUID)`, `func cancelAll()`, `var pendingRequests: [HarvestRequest]`, `var activeCount: Int`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/HarvesterTests/HarvestEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import Harvester
import TestSupport

@Suite struct HarvestEngineTests {
    private func engine(_ fake: FakeTidal, max: Int = 2) -> HarvestEngine {
        let client = fake.client
        let pipeline = HarvestPipeline(client: client,
                                       fetcher: SegmentFetcher(session: StubURLProtocol.session(), backoff: { _ in .milliseconds(1) }),
                                       albumLookup: { _ in nil })
        return HarvestEngine(pipeline: pipeline, checkpoints: nil, maxConcurrent: max)
    }

    private func requests(_ n: Int) throws -> [HarvestRequest] {
        let dest = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID().uuidString)")
        return try (0..<n).map { _ in HarvestRequest(track: try FakeTidal.track(), destinationFolder: dest, genre: nil, policy: .hiRes) }
    }

    @Test func runsAllJobsToVerifiedWithBoundedConcurrency() async throws {
        let fake = try FakeTidal(seconds: 1)
        let engine = engine(fake, max: 2)
        let reqs = try requests(4)
        await engine.enqueue(reqs)
        var verified = Set<UUID>()
        var maxActive = 0
        for await event in engine.events {
            maxActive = max(maxActive, await engine.activeCount)
            if case .verified = event.phase { verified.insert(event.id) }
            if verified.count == reqs.count { break }
        }
        #expect(verified == Set(reqs.map(\.id)))
        #expect(maxActive <= 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: reqs[0].destinationFolder.path)
        #expect(Set(files) == ["Fixture - Tone (Original Mix).flac", "Fixture - Tone (Original Mix) (2).flac",
                               "Fixture - Tone (Original Mix) (3).flac", "Fixture - Tone (Original Mix) (4).flac"])
    }

    @Test func cancelEmitsCancelledAndRemovesFromPending() async throws {
        let fake = try FakeTidal(seconds: 2)
        let engine = engine(fake, max: 1)
        let reqs = try requests(2)
        await engine.enqueue(reqs)
        await engine.cancel(reqs[1].id)
        var cancelled = false
        for await event in engine.events where event.id == reqs[1].id {
            if event.phase == .cancelled { cancelled = true; break }
        }
        #expect(cancelled)
        #expect(await engine.pendingRequests.map(\.id).contains(reqs[1].id) == false)
    }

    @Test func integrityFailureRetriesOnceThenFails() async throws {
        let fake = try FakeTidal(seconds: 1, corruptSegment: 1)
        let engine = engine(fake)
        let req = try requests(1)
        await engine.enqueue(req)
        var resolvingCount = 0
        for await event in engine.events {
            if event.phase == .resolving { resolvingCount += 1 }
            if case .failed(let message) = event.phase {
                #expect(!message.isEmpty)
                break
            }
        }
        #expect(resolvingCount == 2)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter HarvestEngineTests`
Expected: FAIL de compilación — `cannot find 'HarvestEngine' in scope`.

- [ ] **Step 2: `CheckpointStore`**

`Packages/AetherKit/Sources/Harvester/CheckpointStore.swift`:

```swift
public import FlacKit
public import Foundation

/// Persists download checkpoints so an interrupted `.aether-part` resumes instead of restarting.
public actor CheckpointStore {
    private let fileURL: URL
    private var checkpoints: [UUID: AssemblerCheckpoint]
    private var unsaved = 0

    public init(fileURL: URL) {
        self.fileURL = fileURL
        checkpoints = (try? JSONDecoder().decode([UUID: AssemblerCheckpoint].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    public func checkpoint(for id: UUID) -> AssemblerCheckpoint? { checkpoints[id] }

    public func save(_ checkpoint: AssemblerCheckpoint, for id: UUID) {
        checkpoints[id] = checkpoint
        unsaved += 1
        if unsaved >= 5 { persist() }
    }

    public func remove(_ id: UUID) {
        guard checkpoints.removeValue(forKey: id) != nil else { return }
        persist()
    }

    private func persist() {
        unsaved = 0
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(checkpoints).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 3: `HarvestEngine`**

`Packages/AetherKit/Sources/Harvester/HarvestEngine.swift`:

```swift
import FlacKit
public import Foundation

public actor HarvestEngine {
    public nonisolated let events: AsyncStream<HarvestEvent>
    private let continuation: AsyncStream<HarvestEvent>.Continuation
    private var pipeline: HarvestPipeline
    private let checkpoints: CheckpointStore?
    private var maxConcurrent: Int
    private var queue: [HarvestRequest] = []
    private var running: [UUID: (request: HarvestRequest, task: Task<Void, Never>)] = [:]

    public init(pipeline: HarvestPipeline, checkpoints: CheckpointStore?, maxConcurrent: Int = 3) {
        (events, continuation) = AsyncStream.makeStream(of: HarvestEvent.self, bufferingPolicy: .bufferingNewest(512))
        self.pipeline = pipeline
        self.checkpoints = checkpoints
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public var activeCount: Int { running.count }
    /// Queued + running, oldest first — what must be restored after a relaunch.
    public var pendingRequests: [HarvestRequest] { running.values.map(\.request).sorted { $0.createdAt < $1.createdAt } + queue }

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = min(max(value, 1), 4)
        pump()
    }

    public func setPipeline(_ pipeline: HarvestPipeline) { self.pipeline = pipeline }

    public func enqueue(_ requests: [HarvestRequest]) {
        for request in requests {
            queue.append(request)
            continuation.yield(HarvestEvent(id: request.id, phase: .queued))
        }
        pump()
    }

    public func cancel(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
            continuation.yield(HarvestEvent(id: id, phase: .cancelled))
        }
        running[id]?.task.cancel()
    }

    public func cancelAll() {
        for request in queue { continuation.yield(HarvestEvent(id: request.id, phase: .cancelled)) }
        queue.removeAll()
        running.values.forEach { $0.task.cancel() }
    }

    private func pump() {
        while running.count < maxConcurrent, !queue.isEmpty {
            let request = queue.removeFirst()
            let pipeline = pipeline
            let checkpoints = checkpoints
            let continuation = continuation
            let task = Task.detached(priority: .utility) {
                await Self.run(request, pipeline: pipeline, checkpoints: checkpoints, continuation: continuation)
                await self.finished(request.id)
            }
            running[request.id] = (request, task)
        }
    }

    private func finished(_ id: UUID) {
        running[id] = nil
        pump()
    }

    private static func run(_ request: HarvestRequest, pipeline: HarvestPipeline, checkpoints: CheckpointStore?,
                            continuation: AsyncStream<HarvestEvent>.Continuation) async {
        let id = request.id
        let emit: @Sendable (HarvestPhase) -> Void = { continuation.yield(HarvestEvent(id: id, phase: $0)) }
        let save: @Sendable (AssemblerCheckpoint) -> Void = { c in Task { await checkpoints?.save(c, for: id) } }
        for attempt in 0..<2 {
            do {
                let resume = attempt == 0 ? await checkpoints?.checkpoint(for: id) : nil
                let result = try await pipeline.execute(request, resume: resume, checkpoint: save, emit: emit)
                await checkpoints?.remove(id)
                emit(.verified(result))
                return
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: HarvestPipeline.partURL(for: request))
                await checkpoints?.remove(id)
                emit(.cancelled)
                return
            } catch HarvestError.integrity where attempt == 0 {
                await checkpoints?.remove(id)   // one automatic full retry from scratch
                continue
            } catch {
                await checkpoints?.remove(id)
                emit(.failed(Self.message(for: error)))
                return
            }
        }
    }

    public static func message(for error: any Error) -> String {
        switch error {
        case HarvestError.integrity(let reason): "Integridad: \(reason)"
        case HarvestError.http(let code): "HTTP \(code)"
        case let error as URLError where error.code == .notConnectedToInternet: "Sin conexión"
        case let error as URLError where error.code == .cannotConnectToHost: "hifi-api no responde"
        default: String(describing: error)
        }
    }
}
```

- [ ] **Step 4: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter HarvestEngineTests`
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(harvester): add concurrent download queue with cancel, retry and resume"
```

---

### Task 7: `HistoryStore` y `RekordboxXML`

**Files:**
- Create: `Packages/AetherKit/Sources/Harvester/HistoryStore.swift`
- Create: `Packages/AetherKit/Sources/Harvester/RekordboxXML.swift`
- Test: `Packages/AetherKit/Tests/HarvesterTests/HistoryAndRekordboxTests.swift`

**Interfaces:**
- Produces:
  - `public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable { id: UUID; trackID: Int; title: String; artist: String; album: String?; genre: String?; fileURL: URL; report: IntegrityReport; format: FormatSummary; bytes: Int64; finishedAt: Date; init(request: HarvestRequest, result: HarvestResult) }`
  - `public actor HistoryStore { init(fileURL: URL, limit: Int = 5000); func all() -> [HistoryEntry]; func append(_:); func relocate(from: URL, to: URL) }` — más reciente primero.
  - `public enum RekordboxXML { static func document(entries: [HistoryEntry], calendar: Calendar = .current) -> String; static func write(entries: [HistoryEntry], to url: URL) throws; static func location(_ url: URL) -> String }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/HarvesterTests/HistoryAndRekordboxTests.swift`:

```swift
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
```

Run: `swift test --package-path Packages/AetherKit --filter HistoryAndRekordboxTests`
Expected: FAIL de compilación — `cannot find 'HistoryEntry' in scope`.

- [ ] **Step 2: Implementar historial**

`Packages/AetherKit/Sources/Harvester/HistoryStore.swift`:

```swift
public import FlacKit
public import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var trackID: Int
    public var title: String
    public var artist: String
    public var album: String?
    public var genre: String?
    public var fileURL: URL
    public var report: IntegrityReport
    public var format: FormatSummary
    public var bytes: Int64
    public var finishedAt: Date

    public init(id: UUID, trackID: Int, title: String, artist: String, album: String?, genre: String?, fileURL: URL,
                report: IntegrityReport, format: FormatSummary, bytes: Int64, finishedAt: Date) {
        self.id = id
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.fileURL = fileURL
        self.report = report
        self.format = format
        self.bytes = bytes
        self.finishedAt = finishedAt
    }

    public init(request: HarvestRequest, result: HarvestResult) {
        self.init(id: request.id, trackID: request.track.id, title: request.track.displayTitle,
                  artist: request.track.allArtistNames, album: request.track.album?.title, genre: request.genre,
                  fileURL: result.fileURL, report: result.report, format: result.format, bytes: result.bytes,
                  finishedAt: result.finishedAt)
    }
}

public actor HistoryStore {
    private let fileURL: URL
    private let limit: Int
    private var entries: [HistoryEntry]

    public init(fileURL: URL, limit: Int = 5000) {
        self.fileURL = fileURL
        self.limit = limit
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: Data(contentsOf: fileURL))) ?? []
    }

    public func all() -> [HistoryEntry] { entries }

    public func append(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    /// Keeps history (and the rekordbox XML generated from it) in sync with Cosmos moves/renames.
    public func relocate(from old: URL, to new: URL) {
        guard let index = entries.firstIndex(where: { $0.fileURL.standardizedFileURL == old.standardizedFileURL }) else { return }
        entries[index].fileURL = new
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 3: Implementar rekordbox XML**

`Packages/AetherKit/Sources/Harvester/RekordboxXML.swift`:

```swift
public import Foundation

/// rekordbox "rekordbox xml" import format. Jean points rekordbox › Preferences › Advanced › rekordbox xml
/// at this file once; Harvester downloads then appear under Harvester › <day> playlists.
public enum RekordboxXML {
    public static func location(_ url: URL) -> String {
        let absolute = URL(filePath: url.path(percentEncoded: false)).absoluteString   // file:///… percent-encoded
        return absolute.replacingOccurrences(of: "file:///", with: "file://localhost/")
    }

    public static func document(entries: [HistoryEntry], calendar: Calendar = .current) -> String {
        let ordered = entries.sorted { $0.finishedAt < $1.finishedAt }
        var ids: [UUID: Int] = [:]
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += #"<DJ_PLAYLISTS Version="1.0.0">"# + "\n"
        xml += #"  <PRODUCT Name="Aether" Version="1.0" Company="Aether"/>"# + "\n"
        xml += #"  <COLLECTION Entries="\#(ordered.count)">"# + "\n"
        for (index, entry) in ordered.enumerated() {
            let id = index + 1
            ids[entry.id] = id
            let bitRate = entry.format.duration > 0 ? Int(Double(entry.bytes) * 8 / entry.format.duration / 1000) : 0
            let attributes: [(String, String)] = [
                ("TrackID", "\(id)"), ("Name", entry.title), ("Artist", entry.artist), ("Album", entry.album ?? ""),
                ("Genre", entry.genre ?? ""), ("Kind", "FLAC File"), ("Size", "\(entry.bytes)"),
                ("TotalTime", "\(Int(entry.format.duration))"), ("SampleRate", "\(entry.format.sampleRate)"),
                ("BitRate", "\(bitRate)"), ("DateAdded", day(entry.finishedAt, calendar)),
                ("Location", location(entry.fileURL)),
            ]
            xml += "    <TRACK " + attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ") + "/>\n"
        }
        xml += "  </COLLECTION>\n"

        let byDay = Dictionary(grouping: ordered) { day($0.finishedAt, calendar) }
        let days = byDay.keys.sorted(by: >)
        xml += "  <PLAYLISTS>\n"
        xml += #"    <NODE Type="0" Name="ROOT" Count="1">"# + "\n"
        xml += #"      <NODE Type="0" Name="Harvester" Count="\#(days.count)">"# + "\n"
        for key in days {
            let items = byDay[key]!
            xml += #"        <NODE Type="1" Name="\#(key)" KeyType="0" Entries="\#(items.count)">"# + "\n"
            for item in items { xml += #"          <TRACK Key="\#(ids[item.id]!)"/>"# + "\n" }
            xml += "        </NODE>\n"
        }
        xml += "      </NODE>\n    </NODE>\n  </PLAYLISTS>\n</DJ_PLAYLISTS>\n"
        return xml
    }

    public static func write(entries: [HistoryEntry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(document(entries: entries).utf8).write(to: url, options: .atomic)
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
```

- [ ] **Step 4: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter HistoryAndRekordboxTests`
Expected: 3 PASS. (`BitRate` = 41 000 000 × 8 / 236.249 / 1000 = 1388.)

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(harvester): persist download history and export rekordbox XML playlists"
```

---

### Task 8: `HarvesterStore` y `JobModel` en la app

**Files:**
- Create: `Aether/Harvester/JobModel.swift`
- Create: `Aether/Harvester/HarvesterStore.swift`
- Create: `Aether/Harvester/AppPaths.swift`
- Modify: `Aether/App/AppModel.swift`
- Modify: `Aether/App/AetherApp.swift` (inyectar `model.harvester`)
- Test: `AetherTests/JobModelTests.swift`

**Interfaces:**
- Consumes: `HarvestEngine`, `HarvestPipeline`, `HiFiClient`, `HistoryStore`, `CheckpointStore`, `RekordboxXML`, `Preferences`.
- Produces:
  - `enum AppPaths { static var support: URL; static var queue: URL; static var history: URL; static var checkpoints: URL }` (`~/Library/Application Support/Aether/…`)
  - `@MainActor @Observable final class JobModel: Identifiable` con `id`, `request`, `phase`, computed `title`, `subtitle`, `status: StatusGlyph.Status`, `stage: HairlineProgress.Stage`, `transferFraction`, `verifyFraction`, `readout: String`, `readoutTone: Readout.Tone`
  - `@MainActor @Observable final class HarvesterStore` con `jobs: [JobModel]`, `history: [HistoryEntry]`, `searchQuery`, `searchScope: SearchScope`, `trackResults`, `albumResults`, `isSearching`, `searchError: String?`, `selectedTrackIDs: Set<Int>`, `destination: URL`, `destinationFolders: [URL]`, `activeCount`, `failedCount`; métodos `search() async`, `loadAlbum(_:) async -> [TidalTrack]`, `enqueue(_ tracks: [TidalTrack])`, `enqueueSelection()`, `cancel(_ id: UUID)`, `retryFailed()`, `clearFinished()`, `refreshDestinationFolders()`, `applyPreferences()`, `start() async` (consume eventos + restaura cola)
  - `enum SearchScope: String, CaseIterable { tracks, albums }`

- [ ] **Step 1: Prueba que falla**

`AetherTests/JobModelTests.swift`:

```swift
import FlacKit
import Foundation
import Harvester
import HiFiClient
import Testing
@testable import Aether

@MainActor
@Suite struct JobModelTests {
    private func job() throws -> JobModel {
        let track = try JSONDecoder().decode(TidalTrack.self, from: Data(#"{"id":1,"title":"Dreams","version":"Extended Mix","duration":236,"artist":{"id":1,"name":"Prospa"},"album":{"id":2,"title":"Free Your Mind"}}"#.utf8))
        return JobModel(request: HarvestRequest(track: track, destinationFolder: URL(filePath: "/tmp"), genre: nil, policy: .hiRes))
    }

    @Test func derivesPresentationFromPhase() throws {
        let job = try job()
        #expect(job.title == "Dreams (Extended Mix)")
        #expect(job.subtitle == "Prospa · Free Your Mind")
        #expect(job.readout == "EN COLA")
        #expect(job.stage == .idle)

        job.phase = .downloading(segment: 30, of: 60, bytes: 20_000_000, bytesPerSecond: 6_100_000)
        #expect(job.stage == .transferring)
        #expect(job.transferFraction == 0.5)
        #expect(job.readout.contains("30/60"))
        #expect(job.readout.contains("6.1 MB/s"))

        job.phase = .verifying(0.62)
        #expect(job.stage == .verifying)
        #expect(job.transferFraction == 1)
        #expect(job.readout == "VERIFICANDO · MD5 62 %")

        let report = IntegrityReport(verdict: .verified, frames: 1, samples: 1, expectedSamples: nil,
                                     md5Expected: "ee68086136375cebd3f65e8ead407a1f", md5Actual: "ee68086136375cebd3f65e8ead407a1f", failure: nil)
        job.phase = .verified(HarvestResult(fileURL: URL(filePath: "/tmp/x.flac"), report: report,
                                            format: FormatSummary(sampleRate: 44_100, bitDepth: 24, channels: 2, duration: 236),
                                            bytes: 41_000_000, finishedAt: .now))
        #expect(job.status == .verified)
        #expect(job.readout == "FLAC · 24/44.1 · VERIFICADO ee68…7a1f")
        #expect(job.readoutTone == .signal)

        job.phase = .failed("Integridad: MD5 no coincide con la fuente")
        #expect(job.stage == .failed)
        #expect(job.readoutTone == .fault)
    }
}
```

Run: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' test -only-testing:AetherTests/JobModelTests -quiet`
Expected: FAIL — `cannot find 'JobModel' in scope`.

- [ ] **Step 2: Rutas de soporte**

`Aether/Harvester/AppPaths.swift`:

```swift
import Foundation

enum AppPaths {
    static var support: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Aether", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var queue: URL { support.appending(path: "harvester-queue.json") }
    static var history: URL { support.appending(path: "harvester-history.json") }
    static var checkpoints: URL { support.appending(path: "harvester-checkpoints.json") }
}
```

- [ ] **Step 3: `JobModel`**

`Aether/Harvester/JobModel.swift`:

```swift
import Foundation
import Harvester
import Observation

/// One observable per queue row: a progress tick invalidates only its own row.
@MainActor
@Observable
final class JobModel: Identifiable {
    let id: UUID
    let request: HarvestRequest
    var phase: HarvestPhase = .queued

    init(request: HarvestRequest) {
        id = request.id
        self.request = request
    }

    var title: String { request.track.displayTitle }

    var subtitle: String {
        [request.track.allArtistNames, request.track.album?.title].compactMap { $0 }.joined(separator: " · ")
    }

    var status: StatusGlyph.Status {
        switch phase {
        case .queued: .queued
        case .resolving, .downloading: .working
        case .verifying: .verifying
        case .verified: .verified
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    var stage: HairlineProgress.Stage {
        switch phase {
        case .queued, .resolving, .cancelled: .idle
        case .downloading: .transferring
        case .verifying: .verifying
        case .verified: .verified
        case .failed: .failed
        }
    }

    var transferFraction: Double {
        switch phase {
        case .downloading(let segment, let total, _, _): total > 0 ? Double(segment) / Double(total) : 0
        case .verifying, .verified: 1
        default: 0
        }
    }

    var verifyFraction: Double {
        switch phase {
        case .verifying(let f): f
        case .verified: 1
        default: 0
        }
    }

    var readout: String {
        switch phase {
        case .queued: "EN COLA"
        case .resolving: "RESOLVIENDO"
        case .downloading(let segment, let total, let bytes, let rate):
            "\(bytes.formatted(.byteCount(style: .file))) · \(String(format: "%.1f", rate / 1_000_000)) MB/s · \(segment)/\(total)"
        case .verifying(let f): "VERIFICANDO · MD5 \(Int(f * 100)) %"
        case .verified(let result): "\(result.format.label) · VERIFICADO \(result.report.shortMD5)"
        case .failed(let message): message
        case .cancelled: "CANCELADO"
        }
    }

    var readoutTone: Readout.Tone {
        switch phase {
        case .verified: .signal
        case .failed: .fault
        case .queued, .cancelled: .tertiary
        default: .secondary
        }
    }
}
```

- [ ] **Step 4: `HarvesterStore`**

`Aether/Harvester/HarvesterStore.swift`:

```swift
import AppKit
import Foundation
import Harvester
import HiFiClient
import Observation
import UserNotifications

enum SearchScope: String, CaseIterable {
    case tracks, albums
    var title: String { self == .tracks ? "Pistas" : "Álbumes" }
}

@MainActor
@Observable
final class HarvesterStore {
    private(set) var jobs: [JobModel] = []
    private(set) var history: [HistoryEntry] = []
    var searchQuery = ""
    var searchScope: SearchScope = .tracks
    private(set) var trackResults: [TidalTrack] = []
    private(set) var albumResults: [TidalAlbum] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    var selectedTrackIDs: Set<Int> = []
    var destination: URL
    private(set) var destinationFolders: [URL] = []

    var activeCount: Int { jobs.count { !$0.phase.isTerminal } }
    var failedCount: Int { jobs.count { if case .failed = $0.phase { true } else { false } } }

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var client: HiFiClient
    @ObservationIgnored private let engine: HarvestEngine
    @ObservationIgnored private let historyStore = HistoryStore(fileURL: AppPaths.history)
    @ObservationIgnored private var jobsByID: [UUID: JobModel] = [:]
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var batchVerified = 0
    @ObservationIgnored private var batchFailed = 0

    init(preferences: Preferences) {
        self.preferences = preferences
        destination = preferences.inboxFolder
        client = HiFiClient(baseURL: preferences.hifiBaseURL)
        engine = HarvestEngine(pipeline: Self.pipeline(client: client),
                               checkpoints: CheckpointStore(fileURL: AppPaths.checkpoints),
                               maxConcurrent: preferences.maxConcurrentDownloads)
    }

    private static func pipeline(client: HiFiClient) -> HarvestPipeline {
        let session = SegmentFetcher.makeAudioSession()
        let albums = AlbumCache(client: client)
        return HarvestPipeline(client: HiFiClient(baseURL: client.baseURL, session: session),
                               fetcher: SegmentFetcher(session: session),
                               albumLookup: { await albums.album($0) })
    }

    // MARK: Lifecycle

    func start() async {
        history = await historyStore.all()
        refreshDestinationFolders()
        if let data = try? Data(contentsOf: AppPaths.queue),
           let pending = try? JSONDecoder().decode([HarvestRequest].self, from: data), !pending.isEmpty {
            register(pending)
            await engine.enqueue(pending)
        }
        for await event in engine.events { await handle(event) }
    }

    func applyPreferences() {
        client = HiFiClient(baseURL: preferences.hifiBaseURL)
        let pipeline = Self.pipeline(client: client)
        let max = preferences.maxConcurrentDownloads
        Task { await engine.setPipeline(pipeline); await engine.setMaxConcurrent(max) }
    }

    // MARK: Search

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { trackResults = []; albumResults = []; searchError = nil; return }
        isSearching = true
        defer { isSearching = false }
        do {
            switch searchScope {
            case .tracks: trackResults = try await client.searchTracks(query).items
            case .albums: albumResults = try await client.searchAlbums(query).items
            }
            searchError = nil
        } catch is CancellationError {
        } catch {
            searchError = HarvestEngine.message(for: error)
        }
    }

    func loadAlbum(_ album: TidalAlbum) async -> [TidalTrack] {
        (try? await client.album(id: album.id).tracks) ?? []
    }

    // MARK: Queue

    func enqueue(_ tracks: [TidalTrack]) {
        let genre = destination.standardizedFileURL == preferences.inboxFolder.standardizedFileURL ? nil : destination.lastPathComponent
        let policy = QualityPolicy(rawValue: preferences.qualityPolicyRaw) ?? .hiResCapped96
        let requests = tracks.map { HarvestRequest(track: $0, destinationFolder: destination, genre: genre, policy: policy) }
        register(requests)
        Task { await engine.enqueue(requests) }
        requestNotificationPermissionOnce()
    }

    func enqueueSelection() {
        enqueue(trackResults.filter { selectedTrackIDs.contains($0.id) })
    }

    func cancel(_ id: UUID) { Task { await engine.cancel(id) } }

    func retryFailed() {
        let failed = jobs.filter { if case .failed = $0.phase { true } else { false } }
        jobs.removeAll { job in failed.contains { $0.id == job.id } }
        failed.forEach { jobsByID[$0.id] = nil }
        enqueue(failed.map(\.request.track))
    }

    func clearFinished() {
        jobs.removeAll { $0.phase.isTerminal }
        jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
    }

    func refreshDestinationFolders() {
        let master = preferences.masterFolder
        let children = (try? FileManager.default.contentsOfDirectory(at: master, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        destinationFolders = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Events

    private func register(_ requests: [HarvestRequest]) {
        for request in requests where jobsByID[request.id] == nil {
            let job = JobModel(request: request)
            jobsByID[request.id] = job
            jobs.append(job)
        }
    }

    private func handle(_ event: HarvestEvent) async {
        guard let job = jobsByID[event.id] else { return }
        job.phase = event.phase
        if case .verified(let result) = event.phase {
            batchVerified += 1
            let entry = HistoryEntry(request: job.request, result: result)
            await historyStore.append(entry)
            history.insert(entry, at: 0)
            if preferences.rekordboxXMLEnabled {
                let entries = history
                let url = preferences.rekordboxXMLURL
                Task.detached(priority: .utility) { try? RekordboxXML.write(entries: entries, to: url) }
            }
        }
        if case .failed = event.phase { batchFailed += 1 }
        if event.phase.isTerminal || event.phase == .queued { await persistQueueAndActivity() }
    }

    private func persistQueueAndActivity() async {
        let pending = await engine.pendingRequests
        try? JSONEncoder().encode(pending).write(to: AppPaths.queue, options: .atomic)

        let active = activeCount
        NSApp.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
        if active > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Harvester downloads")
        } else if active == 0, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
            notifyBatchFinished()
        }
    }

    // MARK: Notifications (only when the app is in the background — HIG 7.1/7.3)

    @ObservationIgnored private var askedForNotifications = false

    private func requestNotificationPermissionOnce() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func notifyBatchFinished() {
        defer { batchVerified = 0; batchFailed = 0 }
        guard !NSApp.isActive, batchVerified + batchFailed > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Harvester terminó"
        content.body = batchFailed == 0
            ? "\(batchVerified) pistas verificadas"
            : "\(batchVerified) verificadas · \(batchFailed) fallidas"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Album metadata is shared by every track of an album: fetch once.
private actor AlbumCache {
    private let client: HiFiClient
    private var cache: [Int: TidalAlbum] = [:]

    init(client: HiFiClient) { self.client = client }

    func album(_ id: Int) async -> TidalAlbum? {
        if let hit = cache[id] { return hit }
        guard id != 0, let album = try? await client.album(id: id).album else { return nil }
        cache[id] = album
        return album
    }
}
```

> `HiFiClient(baseURL:session:)` dentro de `pipeline(client:)` usa la sesión de audio también para `/track` y portadas: así ninguna respuesta de Harvester pasa por `URLCache`.

- [ ] **Step 5: Conectar al `AppModel` y a la app**

`Aether/App/AppModel.swift` — añadir propiedad e inicialización:

```swift
import Observation

@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    let harvester: HarvesterStore
    var route: Route = .harvesterSearch
    var isInspectorPresented = false

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        harvester = HarvesterStore(preferences: preferences)
        // Owned by the model, not a view: downloads keep reporting with the window closed.
        Task { [harvester] in await harvester.start() }
    }
}
```

`Aether/App/AetherApp.swift` — en el `Window`, tras `.environment(model.preferences)`:

```swift
                .environment(model.harvester)
```

- [ ] **Step 6: Verificar**

Run: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' test -only-testing:AetherTests -quiet`
Expected: `JobModelTests` y `PreferencesTests` PASS.

- [ ] **Step 7: Commit**

```bash
git add Aether AetherTests
git commit -m "feat(app): add Harvester store with per-row job models, history and rekordbox export"
```

---

### Task 9: UI — búsqueda, álbum, destino y comandos

**Files:**
- Create: `Aether/Harvester/HarvesterSearchView.swift`
- Create: `Aether/Harvester/AlbumTracksView.swift`
- Create: `Aether/Harvester/TrackTable.swift`
- Create: `Aether/Harvester/QualityBadge.swift`
- Create: `Aether/Harvester/DestinationMenu.swift`
- Modify: `Aether/Shell/RootView.swift` (ruta `.harvesterSearch`)
- Modify: `Aether/App/AetherCommands.swift` (menú Harvester)

**Interfaces:**
- Consumes: `HarvesterStore`, `TidalTrack`, `TidalAlbum`, tokens del plan 01.
- Produces: `HarvesterSearchView`, `TrackTable(tracks:selection:)`, `QualityBadge(hiRes: Bool)`, `DestinationMenu`.

- [ ] **Step 1: Componentes pequeños**

`Aether/Harvester/QualityBadge.swift`:

```swift
import SwiftUI

struct QualityBadge: View {
    let hiRes: Bool

    var body: some View {
        Text(hiRes ? "HI-RES" : "LOSSLESS")
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(hiRes ? AnyShapeStyle(Tokens.signal) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Tokens.hairline))
            .accessibilityLabel(hiRes ? "Alta resolución" : "Sin pérdida")
    }
}
```

`Aether/Harvester/DestinationMenu.swift`:

```swift
import SwiftUI

/// Toolbar menu: where Harvester writes. Folder name becomes GENRE (except the inbox).
struct DestinationMenu: View {
    @Environment(HarvesterStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Menu {
            Picker("Destino", selection: $store.destination) {
                ForEach(store.destinationFolders, id: \.self) { folder in
                    Text(folder.lastPathComponent).tag(folder)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(store.destination.lastPathComponent, systemImage: "folder")
        }
        .help("Carpeta de destino en Master")
        .onAppear { store.refreshDestinationFolders() }
    }
}
```

`Aether/Harvester/TrackTable.swift`:

```swift
import HiFiClient
import SwiftUI

struct TrackTable: View {
    let tracks: [TidalTrack]
    @Binding var selection: Set<Int>
    @Environment(HarvesterStore.self) private var store

    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("Título") { track in
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).lineLimit(1)
                    if let version = track.version, !version.isEmpty {
                        Text(version).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Artista") { Text($0.allArtistNames).lineLimit(1) }
                .width(min: 120, ideal: 200)
            TableColumn("Álbum") { Text($0.album?.title ?? "").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 100, ideal: 180)
            TableColumn("Duración") { track in
                Readout(Duration.seconds(track.duration).formatted(.time(pattern: .minuteSecond)))
            }
            .width(64)
            TableColumn("Calidad") { QualityBadge(hiRes: $0.supportsHiRes) }
                .width(78)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            Button("Descargar \(ids.count == 1 ? "pista" : "\(ids.count) pistas")") {
                store.enqueue(tracks.filter { ids.contains($0.id) })
            }
            .disabled(ids.isEmpty)
            Divider()
            Button("Copiar enlace de Tidal") {
                let links = tracks.filter { ids.contains($0.id) }.map { "https://tidal.com/track/\($0.id)" }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
            }
        } primaryAction: { ids in
            store.enqueue(tracks.filter { ids.contains($0.id) })
        }
    }
}
```

- [ ] **Step 2: Vista de búsqueda y de álbum**

`Aether/Harvester/HarvesterSearchView.swift`:

```swift
import HiFiClient
import SwiftUI

struct HarvesterSearchView: View {
    @Environment(HarvesterStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            content
                .navigationDestination(for: TidalAlbum.self) { AlbumTracksView(album: $0) }
        }
        .searchable(text: $store.searchQuery, placement: .toolbar, prompt: "Buscar en Tidal")
        .task(id: "\(store.searchScope.rawValue)|\(store.searchQuery)") {
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            await store.search()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Ámbito", selection: $store.searchScope) {
                    ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            ToolbarItem { DestinationMenu() }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.enqueueSelection()
                } label: {
                    Label("Descargar", systemImage: "arrow.down.circle")
                }
                .disabled(store.selectedTrackIDs.isEmpty || store.searchScope != .tracks)
                .help("Descargar selección (⌘D)")
            }
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var store = store
        if let error = store.searchError {
            ContentUnavailableView("No se pudo buscar", systemImage: "bolt.horizontal.circle",
                                   description: Text(error))
        } else if store.searchQuery.count < 2 {
            ContentUnavailableView("Buscar en Tidal", systemImage: "magnifyingglass",
                                   description: Text("Escribe un artista, una pista o un álbum."))
        } else {
            switch store.searchScope {
            case .tracks:
                TrackTable(tracks: store.trackResults, selection: $store.selectedTrackIDs)
                    .overlay { if store.isSearching && store.trackResults.isEmpty { ProgressView().controlSize(.small) } }
            case .albums:
                List(store.albumResults) { album in
                    NavigationLink(value: album) { AlbumRow(album: album) }
                }
                .overlay { if store.isSearching && store.albumResults.isEmpty { ProgressView().controlSize(.small) } }
            }
        }
    }
}

private struct AlbumRow: View {
    let album: TidalAlbum

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).lineLimit(1)
                Text(album.primaryArtistName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Readout([album.year, album.numberOfTracks.map { "\($0) pistas" }].compactMap { $0 }.joined(separator: " · "))
            QualityBadge(hiRes: album.supportsHiRes)
        }
        .padding(.vertical, 2)
    }
}
```

`Aether/Harvester/AlbumTracksView.swift`:

```swift
import HiFiClient
import SwiftUI

struct AlbumTracksView: View {
    let album: TidalAlbum
    @Environment(HarvesterStore.self) private var store
    @State private var tracks: [TidalTrack] = []
    @State private var selection: Set<Int> = []

    var body: some View {
        TrackTable(tracks: tracks, selection: $selection)
            .navigationTitle(album.title)
            .navigationSubtitle([album.primaryArtistName, album.year].compactMap { $0 }.joined(separator: " · "))
            .task { tracks = await store.loadAlbum(album) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.enqueue(selection.isEmpty ? tracks : tracks.filter { selection.contains($0.id) })
                    } label: {
                        Label(selection.isEmpty ? "Descargar álbum" : "Descargar selección", systemImage: "arrow.down.circle")
                    }
                    .disabled(tracks.isEmpty)
                }
            }
    }
}
```

- [ ] **Step 3: Enrutar y comandos**

En `Aether/Shell/RootView.swift`, en `DetailRouter`, sustituir el caso `.harvesterSearch` por:

```swift
        case .harvesterSearch:
            HarvesterSearchView()
```

En `Aether/App/AetherCommands.swift`, añadir dentro de `body`:

```swift
        CommandMenu("Harvester") {
            Button("Descargar selección") { model.harvester.enqueueSelection() }
                .keyboardShortcut("d")
                .disabled(model.harvester.selectedTrackIDs.isEmpty)
            Button("Reintentar fallidas") { model.harvester.retryFailed() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.harvester.failedCount == 0)
            Divider()
            Button("Limpiar terminadas") { model.harvester.clearFinished() }
        }
```

- [ ] **Step 4: Probar a mano contra la hifi-api local**

Run: compilar y abrir la app (`xcodebuild … build` y abrir `Aether.app` desde Xcode con ⌘R).
Expected: escribir "prospa dreams" → tabla en < 1 s con badge HI-RES; doble clic en una fila encola; ⌘D descarga la selección; "Álbumes" lista álbumes y al entrar se ven sus pistas.

- [ ] **Step 5: Commit**

```bash
git add Aether
git commit -m "feat(harvester-ui): add Tidal search, album browsing and destination picker"
```

---

### Task 10: UI — cola con barra limpia, historial, badge y Settings de Harvester

**Files:**
- Create: `Aether/Harvester/HarvesterQueueView.swift`
- Create: `Aether/Harvester/JobRow.swift`
- Create: `Aether/Harvester/HarvesterHistoryView.swift`
- Modify: `Aether/Shell/RootView.swift` (rutas `.harvesterQueue`, `.harvesterHistory`; `.onChange` de preferencias)
- Modify: `Aether/Shell/SidebarView.swift` (badge de la Cola)
- Modify: `Aether/Settings/SettingsView.swift` (pestaña Harvester)
- Modify: `AetherUITests/AetherUITests.swift`

**Interfaces:**
- Consumes: `JobModel`, `HarvesterStore`, `HairlineProgress`, `StatusGlyph`, `Readout`.

- [ ] **Step 1: Fila de trabajo**

`Aether/Harvester/JobRow.swift`:

```swift
import SwiftUI

struct JobRow: View {
    let job: JobModel
    @Environment(HarvesterStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(spacing: Tokens.Space.m) {
                StatusGlyph(job.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title).lineLimit(1)
                    Text(job.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Tokens.Space.l)
                Readout(job.readout, tone: job.readoutTone)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
            HairlineProgress(transfer: job.transferFraction, verify: job.verifyFraction, stage: job.stage)
        }
        .padding(.vertical, Tokens.Space.s)
        .contentShape(.rect)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var menu: some View {
        switch job.phase {
        case .verified(let result):
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.fileURL]) }
            Button("Copiar MD5") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.report.md5Actual ?? "", forType: .string)
            }
        case .failed:
            Button("Reintentar") { store.retryFailed() }
        case .cancelled:
            EmptyView()
        default:
            Button("Cancelar") { store.cancel(job.id) }
        }
    }
}
```

- [ ] **Step 2: Cola e historial**

`Aether/Harvester/HarvesterQueueView.swift`:

```swift
import SwiftUI

struct HarvesterQueueView: View {
    @Environment(HarvesterStore.self) private var store
    @State private var selection: JobModel.ID?

    var body: some View {
        Group {
            if store.jobs.isEmpty {
                ContentUnavailableView("Cola vacía", systemImage: "arrow.down.circle",
                                       description: Text("Busca en Tidal y pulsa ⌘D para descargar."))
            } else {
                List(store.jobs, selection: $selection) { job in
                    JobRow(job: job)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Cola")
        .navigationSubtitle(store.activeCount > 0 ? "\(store.activeCount) activas" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.retryFailed() } label: { Label("Reintentar fallidas", systemImage: "arrow.clockwise") }
                    .disabled(store.failedCount == 0)
                Button { store.clearFinished() } label: { Label("Limpiar terminadas", systemImage: "checkmark.circle.badge.xmark") }
                    .disabled(!store.jobs.contains { $0.phase.isTerminal })
            }
        }
        .onKeyPress(.delete) {
            guard let id = selection else { return .ignored }
            store.cancel(id)
            return .handled
        }
    }
}
```

`Aether/Harvester/HarvesterHistoryView.swift`:

```swift
import Harvester
import SwiftUI

struct HarvesterHistoryView: View {
    @Environment(HarvesterStore.self) private var store
    @State private var selection: Set<HistoryEntry.ID> = []

    var body: some View {
        Table(store.history, selection: $selection) {
            TableColumn("Título") { Text($0.title).lineLimit(1) }.width(min: 180, ideal: 280)
            TableColumn("Artista") { Text($0.artist).lineLimit(1) }.width(min: 120, ideal: 180)
            TableColumn("Formato") { Readout($0.format.label) }.width(96)
            TableColumn("MD5") { Readout($0.report.shortMD5, tone: .signal) }.width(90)
            TableColumn("Carpeta") { Text($0.fileURL.deletingLastPathComponent().lastPathComponent).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 120)
            TableColumn("Fecha") { Readout($0.finishedAt.formatted(date: .abbreviated, time: .shortened)) }.width(130)
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            Button("Mostrar en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(store.history.filter { ids.contains($0.id) }.map(\.fileURL))
            }
        }
        .navigationTitle("Historial")
        .overlay {
            if store.history.isEmpty {
                ContentUnavailableView("Sin historial", systemImage: "clock",
                                       description: Text("Las descargas verificadas aparecerán aquí."))
            }
        }
    }
}
```

- [ ] **Step 3: Enrutar, badge y preferencias**

`DetailRouter` en `RootView.swift`:

```swift
        case .harvesterQueue:
            HarvesterQueueView()
        case .harvesterHistory:
            HarvesterHistoryView()
```

En `RootView.body`, tras `.background(Tokens.canvas)` del detalle, añadir al `NavigationSplitView`:

```swift
        .onChange(of: model.preferences.hifiBaseURL) { model.harvester.applyPreferences() }
        .onChange(of: model.preferences.maxConcurrentDownloads) { model.harvester.applyPreferences() }
```

En `SidebarView.swift`, leer el store y poner badge:

```swift
struct SidebarView: View {
    @Binding var route: Route
    @Environment(HarvesterStore.self) private var harvester

    var body: some View {
        List(selection: Binding<Route?>(get: { route }, set: { if let new = $0 { route = new } })) {
            Section("Harvester") {
                Label("Buscar", systemImage: "magnifyingglass").tag(Route.harvesterSearch)
                Label("Cola", systemImage: "arrow.down.circle").tag(Route.harvesterQueue)
                    .badge(harvester.activeCount)
                Label("Historial", systemImage: "clock").tag(Route.harvesterHistory)
            }
            Section("Cosmos") {
                Label("Master", systemImage: "folder").tag(Route.cosmosAll)
            }
        }
        .listStyle(.sidebar)
    }
}
```

- [ ] **Step 4: Pestaña de Settings**

En `SettingsView.swift`, añadir `Tab("Harvester", systemImage: "arrow.down.circle") { HarvesterSettings() }` y:

```swift
import Harvester

private struct HarvesterSettings: View {
    @Environment(Preferences.self) private var preferences
    @State private var connection: Bool?

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker("Calidad", selection: $preferences.qualityPolicyRaw) {
                    ForEach(QualityPolicy.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Stepper("Descargas simultáneas: \(preferences.maxConcurrentDownloads)",
                        value: $preferences.maxConcurrentDownloads, in: 1...4)
            } header: { SectionLabel("Descarga") }
            Section {
                Toggle("Mantener rekordbox.xml", isOn: $preferences.rekordboxXMLEnabled)
                LabeledContent("Archivo") {
                    HStack {
                        Readout(preferences.rekordboxXMLURL.path(percentEncoded: false))
                        Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([preferences.rekordboxXMLURL]) }
                    }
                }
                Text("En rekordbox: Preferencias › Avanzado › Base de datos › rekordbox xml → elige este archivo.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { SectionLabel("rekordbox") }
            Section {
                LabeledContent("hifi-api") {
                    HStack {
                        Readout(preferences.hifiBaseURL.absoluteString)
                        Button("Probar") {
                            Task { connection = await HiFiClient(baseURL: preferences.hifiBaseURL).ping() }
                        }
                        if let connection {
                            Image(systemName: connection ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(connection ? Tokens.signal : Tokens.fault)
                                .accessibilityLabel(connection ? "Conectado" : "Sin conexión")
                        }
                    }
                }
            } header: { SectionLabel("Conexión") }
        }
        .formStyle(.grouped)
    }
}
```

(`import HiFiClient` también al principio del archivo.)

- [ ] **Step 5: Prueba de UI de la cola**

Añadir a `AetherUITests/AetherUITests.swift`:

```swift
    @MainActor
    func testQueueShowsEmptyStateAndShortcut() {
        let app = XCUIApplication()
        app.launch()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Cola vacía"].waitForExistence(timeout: 5))
    }
```

- [ ] **Step 6: Verificación de extremo a extremo (manual, hifi-api local)**

1. Buscar "prospa dreams", destino "UK House", ⌘D.
2. ⌘2: la fila muestra `RESOLVIENDO` → bytes y MB/s con la línea de acento avanzando → `VERIFICANDO · MD5 n %` con la línea verde → `FLAC · 24/44.1 · VERIFICADO ee68…7a1f`.
3. `~/Master/UK House/Prospa - Dreams (Extended Mix).flac` existe (o el título que devuelva Tidal); `metaflac --list` (si está instalado) muestra GENRE=UK House, LABEL, AETHER_VERIFIED.
4. `~/Music/Aether/rekordbox.xml` contiene la pista; importarlo en rekordbox.
5. Cerrar la app a mitad de una descarga y reabrir: la pista retoma (no empieza de cero) y termina verificada.
6. Activity Monitor durante 3 descargas: memoria < 220 MB.

- [ ] **Step 7: Commit**

```bash
git add Aether AetherUITests
git commit -m "feat(harvester-ui): add download queue with two-pass hairline progress, history and settings"
```
