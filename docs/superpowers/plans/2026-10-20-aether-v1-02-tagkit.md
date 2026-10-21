# Aether v1 · Plan 02 — TagKit (FLAC/Vorbis, ID3, chunks WAV/AIFF, nomenclatura)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Leer y escribir metadatos de audio sin tocar el audio: bloques FLAC (STREAMINFO, VORBIS_COMMENT, PICTURE, PADDING) con escritura in-place, ID3v2.3/2.4 para MP3, chunk ID3 para WAV/AIFF, un modelo unificado `TrackTags` y reglas de nombres de archivo.

**Architecture:** Módulo `TagKit` sobre `ByteKit`. Cada formato tiene un *codec* puro (bytes ↔ modelo, probado en memoria) y un *IO* de archivo que lee solo la cabecera y escribe con `HeaderRegionRewriter` (in-place cuando el padding alcanza). Frames y bloques desconocidos se preservan byte a byte.

**Tech Stack:** Swift 6, Foundation, ImageIO, Swift Testing.

**Spec:** `docs/superpowers/plans/2026-10-20-aether-v1-00-overview.md` (§3, §9.4–9.6)

## Global Constraints

- macOS 27, Swift 6, paquete `nonisolated` por defecto, cero dependencias de terceros.
- Lectura de tags = solo cabeceras; nunca cargar el audio completo.
- Escritura FLAC: in-place si cabe en la región actual (con PADDING); si no, reescritura con 8 KiB de padding nuevo.
- MP3 nuevo → ID3v2.3; tag v2.4 existente → se conserva v2.4.
- Preservar frames/bloques desconocidos (GEOB, PRIV, SEEKTABLE, CUESHEET, APPLICATION…).
- Tags para rekordbox: LABEL **y** ORGANIZATION para el sello; INITIALKEY para la tonalidad.
- Nombres: `/` y `:` → `-`; nunca sobrescribir; sufijo ` (2)`.

Rutas relativas a `~/Documents/Projects/Aether`. Comando de pruebas: `swift test --package-path Packages/AetherKit`.

---

### Task 1: Bloques FLAC, STREAMINFO y E/S de la cabecera FLAC

**Files:**
- Modify: `Packages/AetherKit/Package.swift`
- Create: `Packages/AetherKit/Sources/TagKit/Flac/FlacBlock.swift`
- Create: `Packages/AetherKit/Sources/TagKit/Flac/StreamInfo.swift`
- Create: `Packages/AetherKit/Sources/TagKit/Flac/FlacMetadataIO.swift`
- Create: `Packages/AetherKit/Sources/TagKit/Support/FileHandle+Exact.swift`
- Test: `Packages/AetherKit/Tests/TagKitTests/Fixtures.swift`
- Test: `Packages/AetherKit/Tests/TagKitTests/FlacMetadataIOTests.swift`

**Interfaces:**
- Consumes: `ByteReader`, `ByteWriter`, `ByteError`, `HeaderRegionRewriter` (plan 01).
- Produces:
  - `public enum FlacBlockType { static let streamInfo: UInt8 = 0, padding = 1, application = 2, seekTable = 3, vorbisComment = 4, cueSheet = 5, picture = 6 }`
  - `public struct FlacBlock: Equatable, Sendable { var type: UInt8; var payload: [UInt8]; static func padding(_ count: Int) -> FlacBlock }`
  - `public struct StreamInfo: Equatable, Sendable, Codable` con `minBlockSize, maxBlockSize: UInt16`, `minFrameSize, maxFrameSize: UInt32`, `sampleRate: UInt32`, `channels: UInt8`, `bitsPerSample: UInt8`, `totalSamples: UInt64`, `md5: [UInt8]`, `init(payload:) throws`, `payload: [UInt8]`, `hasMD5`, `md5Hex`, `duration`, `block: FlacBlock`
  - `public enum FlacError: Error, Equatable { case notFlac, missingStreamInfo, blockTooLarge }`
  - `public struct FlacHeader: Equatable, Sendable { var blocks: [FlacBlock]; var audioOffset: Int; func streamInfo() throws -> StreamInfo; func blocks(ofType:) -> [FlacBlock] }`
  - `public enum FlacMetadataIO { static func parse(_ bytes: [UInt8]) throws -> FlacHeader; static func read(_ url: URL) throws -> FlacHeader; static func serialize(_ blocks: [FlacBlock]) throws -> [UInt8]; static func layout(_ blocks: [FlacBlock], regionLength: Int?, padding: Int) -> [FlacBlock]; static func write(_ blocks: [FlacBlock], to url: URL, padding: Int = 8192) throws }`
  - `extension FileHandle { func readExactly(_ count: Int) throws -> [UInt8] }`

- [ ] **Step 1: Añadir el target al paquete**

En `Packages/AetherKit/Package.swift`, producto y targets:

```swift
.library(name: "AetherKit", targets: ["ByteKit", "TagKit"]),
```

```swift
.target(name: "TagKit", dependencies: ["ByteKit"], swiftSettings: settings),
.testTarget(name: "TagKitTests", dependencies: ["TagKit"], swiftSettings: settings),
```

- [ ] **Step 2: Fixtures de prueba**

`Packages/AetherKit/Tests/TagKitTests/Fixtures.swift`:

```swift
import Foundation
@testable import TagKit

enum Fixtures {
    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tagkit-\(UUID().uuidString).\(ext)")
    }

    static let streamInfo = StreamInfo(
        minBlockSize: 4096, maxBlockSize: 4096, minFrameSize: 14, maxFrameSize: 18_000,
        sampleRate: 96_000, channels: 2, bitsPerSample: 24, totalSamples: 10_418_594,
        md5: Array(0..<16))

    /// Fake FLAC: real metadata header followed by `audio` bytes standing in for frames.
    static func flacFile(blocks: [FlacBlock], audio: [UInt8] = Array(repeating: 0xAA, count: 4096)) throws -> URL {
        let url = tempURL("flac")
        try Data(try FlacMetadataIO.serialize(blocks) + audio).write(to: url)
        return url
    }

    static func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }
}
```

- [ ] **Step 3: Pruebas que fallan**

`Packages/AetherKit/Tests/TagKitTests/FlacMetadataIOTests.swift`:

```swift
import Foundation
import Testing
@testable import TagKit

@Suite struct FlacMetadataIOTests {
    @Test func streamInfoRoundTrip() throws {
        let si = Fixtures.streamInfo
        #expect(si.payload.count == 34)
        let parsed = try StreamInfo(payload: si.payload)
        #expect(parsed == si)
        #expect(parsed.duration == 10_418_594.0 / 96_000.0)
        #expect(parsed.md5Hex == "000102030405060708090a0b0c0d0e0f")
        #expect(parsed.hasMD5)
    }

    @Test func parsesTidalStreamInfoBytes() throws {
        // STREAMINFO captured from a Tidal init segment (2026-10-20): 44.1 kHz, 2 ch, 24 bit, 10_418_594 samples.
        let payload: [UInt8] = [0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                0x0A, 0xC4, 0x43, 0x70, 0x00, 0x9E, 0xF9, 0xA2,
                                0xEE, 0x68, 0x08, 0x61, 0x36, 0x37, 0x5C, 0xEB, 0xD3, 0xF6, 0x5E, 0x8E, 0xAD, 0x40, 0x7A, 0x1F]
        let si = try StreamInfo(payload: payload)
        #expect(si.sampleRate == 44_100)
        #expect(si.channels == 2)
        #expect(si.bitsPerSample == 24)
        #expect(si.totalSamples == 10_418_594)
        #expect(si.md5Hex == "ee68086136375cebd3f65e8ead407a1f")
    }

    @Test func readsHeaderAndAudioOffset() throws {
        let blocks = [Fixtures.streamInfo.block, FlacBlock(type: FlacBlockType.seekTable, payload: [1, 2, 3]), .padding(100)]
        let url = try Fixtures.flacFile(blocks: blocks)
        let header = try FlacMetadataIO.read(url)
        #expect(header.blocks == blocks)
        #expect(header.audioOffset == 4 + (4 + 34) + (4 + 3) + (4 + 100))
        #expect(try header.streamInfo() == Fixtures.streamInfo)
    }

    @Test func rejectsNonFlac() throws {
        let url = Fixtures.tempURL("flac")
        try Data("RIFF0000WAVE".utf8).write(to: url)
        #expect(throws: FlacError.notFlac) { try FlacMetadataIO.read(url) }
    }

    @Test func skipsLeadingID3() throws {
        let flac = try FlacMetadataIO.serialize([Fixtures.streamInfo.block]) + [0xFF, 0xF8]
        let id3: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0, 0, 0, 5] + [0, 0, 0, 0, 0]
        let header = try FlacMetadataIO.parse(id3 + flac)
        #expect(header.audioOffset == id3.count + 4 + 4 + 34)
    }

    @Test func layoutReusesRegionWithPadding() {
        let blocks = [Fixtures.streamInfo.block]
        let exact = FlacMetadataIO.layout(blocks, regionLength: 4 + 38, padding: 8192)
        #expect(exact == blocks)
        let padded = FlacMetadataIO.layout(blocks, regionLength: 4 + 38 + 50, padding: 8192)
        #expect(padded.last == .padding(46))
        let tooSmall = FlacMetadataIO.layout(blocks + [FlacBlock(type: 4, payload: Array(repeating: 1, count: 100))], regionLength: 60, padding: 8192)
        #expect(tooSmall.last == .padding(8192))
        let gapOfThree = FlacMetadataIO.layout(blocks, regionLength: 4 + 38 + 3, padding: 8192)
        #expect(gapOfThree.last == .padding(8192))
    }

    @Test func writeInPlaceWhenPaddingSuffices() throws {
        let audio = Array(repeating: UInt8(0xAB), count: 10_000)
        let url = try Fixtures.flacFile(blocks: [Fixtures.streamInfo.block, .padding(1000)], audio: audio)
        let sizeBefore = try Fixtures.bytes(url).count
        try FlacMetadataIO.write([Fixtures.streamInfo.block, FlacBlock(type: 4, payload: Array(repeating: 7, count: 300))], to: url)
        let after = try Fixtures.bytes(url)
        #expect(after.count == sizeBefore)
        #expect(Array(after.suffix(audio.count)) == audio)
        let header = try FlacMetadataIO.read(url)
        #expect(header.blocks.count == 3)
        #expect(header.blocks[2] == .padding(1000 - 300 - 4))
    }

    @Test func writeGrowsFileWhenNeeded() throws {
        let audio = Array(repeating: UInt8(0xCD), count: 5000)
        let url = try Fixtures.flacFile(blocks: [Fixtures.streamInfo.block], audio: audio)
        let big = FlacBlock(type: FlacBlockType.picture, payload: Array(repeating: 9, count: 20_000))
        try FlacMetadataIO.write([Fixtures.streamInfo.block, big], to: url)
        let header = try FlacMetadataIO.read(url)
        #expect(header.blocks == [Fixtures.streamInfo.block, big, .padding(8192)])
        #expect(Array(try Fixtures.bytes(url).suffix(audio.count)) == audio)
    }

    @Test func writeRequiresStreamInfoFirst() throws {
        let url = try Fixtures.flacFile(blocks: [Fixtures.streamInfo.block])
        #expect(throws: FlacError.missingStreamInfo) {
            try FlacMetadataIO.write([.padding(10)], to: url)
        }
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter FlacMetadataIOTests`
Expected: FAIL de compilación — `cannot find 'StreamInfo' in scope`.

- [ ] **Step 4: Implementar**

`Packages/AetherKit/Sources/TagKit/Support/FileHandle+Exact.swift`:

```swift
public import Foundation
import ByteKit

extension FileHandle {
    /// Reads exactly `count` bytes or throws `ByteError.outOfBounds`.
    public func readExactly(_ count: Int) throws -> [UInt8] {
        if count == 0 { return [] }
        guard let data = try read(upToCount: count), data.count == count else {
            throw ByteError.outOfBounds(offset: Int((try? offset()) ?? 0), needed: count)
        }
        return [UInt8](data)
    }
}
```

`Packages/AetherKit/Sources/TagKit/Flac/FlacBlock.swift`:

```swift
public enum FlacBlockType {
    public static let streamInfo: UInt8 = 0
    public static let padding: UInt8 = 1
    public static let application: UInt8 = 2
    public static let seekTable: UInt8 = 3
    public static let vorbisComment: UInt8 = 4
    public static let cueSheet: UInt8 = 5
    public static let picture: UInt8 = 6
}

public struct FlacBlock: Equatable, Sendable {
    public var type: UInt8
    public var payload: [UInt8]

    public init(type: UInt8, payload: [UInt8]) {
        self.type = type
        self.payload = payload
    }

    public static func padding(_ count: Int) -> FlacBlock {
        FlacBlock(type: FlacBlockType.padding, payload: [UInt8](repeating: 0, count: count))
    }
}

public enum FlacError: Error, Equatable, Sendable {
    case notFlac
    case missingStreamInfo
    case blockTooLarge
}
```

`Packages/AetherKit/Sources/TagKit/Flac/StreamInfo.swift`:

```swift
import ByteKit
import Foundation

public struct StreamInfo: Equatable, Sendable, Codable {
    public var minBlockSize: UInt16
    public var maxBlockSize: UInt16
    public var minFrameSize: UInt32
    public var maxFrameSize: UInt32
    public var sampleRate: UInt32
    public var channels: UInt8
    public var bitsPerSample: UInt8
    public var totalSamples: UInt64
    public var md5: [UInt8]

    public init(minBlockSize: UInt16, maxBlockSize: UInt16, minFrameSize: UInt32, maxFrameSize: UInt32,
                sampleRate: UInt32, channels: UInt8, bitsPerSample: UInt8, totalSamples: UInt64, md5: [UInt8]) {
        self.minBlockSize = minBlockSize
        self.maxBlockSize = maxBlockSize
        self.minFrameSize = minFrameSize
        self.maxFrameSize = maxFrameSize
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.totalSamples = totalSamples
        self.md5 = md5
    }

    public init(payload: [UInt8]) throws {
        guard payload.count == 34 else { throw ByteError.invalid("STREAMINFO length \(payload.count)") }
        var r = ByteReader(payload)
        minBlockSize = try r.u16BE()
        maxBlockSize = try r.u16BE()
        minFrameSize = try r.u24BE()
        maxFrameSize = try r.u24BE()
        let packed = try r.u64BE()
        sampleRate = UInt32(packed >> 44)
        channels = UInt8((packed >> 41) & 0x7) + 1
        bitsPerSample = UInt8((packed >> 36) & 0x1F) + 1
        totalSamples = packed & 0xF_FFFF_FFFF
        md5 = try r.bytes(16)
    }

    public var payload: [UInt8] {
        var w = ByteWriter(reservingCapacity: 34)
        w.u16BE(minBlockSize)
        w.u16BE(maxBlockSize)
        w.u24BE(minFrameSize)
        w.u24BE(maxFrameSize)
        let packed = UInt64(sampleRate) << 44
            | UInt64(channels - 1) << 41
            | UInt64(bitsPerSample - 1) << 36
            | (totalSamples & 0xF_FFFF_FFFF)
        w.u64BE(packed)
        w.append(md5.count == 16 ? md5 : [UInt8](repeating: 0, count: 16))
        return w.bytes
    }

    public var block: FlacBlock { FlacBlock(type: FlacBlockType.streamInfo, payload: payload) }
    public var hasMD5: Bool { md5.contains { $0 != 0 } }
    public var md5Hex: String { md5.map { String(format: "%02x", $0) }.joined() }
    public var duration: Double { sampleRate == 0 ? 0 : Double(totalSamples) / Double(sampleRate) }
}
```

`Packages/AetherKit/Sources/TagKit/Flac/FlacMetadataIO.swift`:

```swift
public import Foundation
import ByteKit

public struct FlacHeader: Equatable, Sendable {
    public var blocks: [FlacBlock]
    /// Byte offset of the first audio frame (includes any non-standard leading ID3 tag).
    public var audioOffset: Int

    public init(blocks: [FlacBlock], audioOffset: Int) {
        self.blocks = blocks
        self.audioOffset = audioOffset
    }

    public func streamInfo() throws -> StreamInfo {
        guard let first = blocks.first, first.type == FlacBlockType.streamInfo else { throw FlacError.missingStreamInfo }
        return try StreamInfo(payload: first.payload)
    }

    public func blocks(ofType type: UInt8) -> [FlacBlock] { blocks.filter { $0.type == type } }
}

public enum FlacMetadataIO {
    private static let magic: [UInt8] = Array("fLaC".utf8)
    private static let maxPayload = (1 << 24) - 1

    public static func parse(_ bytes: [UInt8]) throws -> FlacHeader {
        var r = ByteReader(bytes)
        let start = try leadingID3Length(Array(bytes.prefix(10)))
        try r.seek(to: start)
        guard bytes.count >= start + 4, try r.bytes(4) == magic else { throw FlacError.notFlac }
        var blocks: [FlacBlock] = []
        var isLast = false
        while !isLast {
            let flags = try r.u8()
            isLast = flags & 0x80 != 0
            let length = Int(try r.u24BE())
            blocks.append(FlacBlock(type: flags & 0x7F, payload: try r.bytes(length)))
        }
        guard blocks.first?.type == FlacBlockType.streamInfo else { throw FlacError.missingStreamInfo }
        return FlacHeader(blocks: blocks, audioOffset: r.offset)
    }

    public static func read(_ url: URL) throws -> FlacHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = (try handle.read(upToCount: 10)).map { [UInt8]($0) } ?? []
        let start = try leadingID3Length(head)
        try handle.seek(toOffset: UInt64(start))
        guard (try? handle.readExactly(4)) == magic else { throw FlacError.notFlac }
        var blocks: [FlacBlock] = []
        var offset = start + 4
        var isLast = false
        while !isLast {
            let h = try handle.readExactly(4)
            isLast = h[0] & 0x80 != 0
            let length = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            blocks.append(FlacBlock(type: h[0] & 0x7F, payload: try handle.readExactly(length)))
            offset += 4 + length
        }
        guard blocks.first?.type == FlacBlockType.streamInfo else { throw FlacError.missingStreamInfo }
        return FlacHeader(blocks: blocks, audioOffset: offset)
    }

    public static func serialize(_ blocks: [FlacBlock]) throws -> [UInt8] {
        var w = ByteWriter(reservingCapacity: 4 + blocks.reduce(0) { $0 + 4 + $1.payload.count })
        w.append(magic)
        for (index, block) in blocks.enumerated() {
            guard block.payload.count <= maxPayload else { throw FlacError.blockTooLarge }
            let last: UInt8 = index == blocks.count - 1 ? 0x80 : 0
            w.u8(last | (block.type & 0x7F))
            w.u24BE(UInt32(block.payload.count))
            w.append(block.payload)
        }
        return w.bytes
    }

    /// Drops existing PADDING and appends one sized to reuse `regionLength` exactly when possible,
    /// otherwise appends `padding` bytes of fresh padding (the file will be rewritten).
    public static func layout(_ blocks: [FlacBlock], regionLength: Int?, padding: Int) -> [FlacBlock] {
        var out = blocks.filter { $0.type != FlacBlockType.padding }
        let used = 4 + out.reduce(0) { $0 + 4 + $1.payload.count }
        if let region = regionLength {
            if used == region { return out }
            if used + 4 <= region {
                out.append(.padding(region - used - 4))
                return out
            }
        }
        out.append(.padding(padding))
        return out
    }

    public static func write(_ blocks: [FlacBlock], to url: URL, padding: Int = 8192) throws {
        guard blocks.first?.type == FlacBlockType.streamInfo else { throw FlacError.missingStreamInfo }
        let current = try read(url)
        let laidOut = layout(blocks, regionLength: current.audioOffset, padding: padding)
        try HeaderRegionRewriter.replace(fileAt: url, oldLength: current.audioOffset, with: try serialize(laidOut))
    }

    /// Some taggers prepend ID3v2 to FLAC (non-standard). Returns its total length, or 0.
    private static func leadingID3Length(_ head: [UInt8]) throws -> Int {
        guard head.count >= 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 else { return 0 }
        var r = ByteReader(Array(head[6..<10]))
        return 10 + Int(try r.syncsafe32())
    }
}
```

- [ ] **Step 5: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter FlacMetadataIOTests`
Expected: 9 pruebas PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(tagkit): parse and write FLAC metadata blocks with in-place padding reuse"
```

---

### Task 2: VORBIS_COMMENT y PICTURE

**Files:**
- Create: `Packages/AetherKit/Sources/TagKit/Flac/VorbisComment.swift`
- Create: `Packages/AetherKit/Sources/TagKit/Flac/FlacPicture.swift`
- Create: `Packages/AetherKit/Sources/TagKit/Support/ImageInfo.swift`
- Test: `Packages/AetherKit/Tests/TagKitTests/VorbisPictureTests.swift`

**Interfaces:**
- Produces:
  - `public struct VorbisComment: Equatable, Sendable` con `struct Field { key, value }`, `vendor: String`, `fields: [Field]`, `init(vendor: String = "Aether", fields: [Field] = [])`, `init(payload:) throws`, `payload`, `values(_:) -> [String]`, `first(_:) -> String?`, `set(_ key: String, _ values: [String])`, `set(_ key: String, _ value: String?)`
  - `public struct FlacPicture: Equatable, Sendable` con `pictureType: UInt32`, `mimeType`, `description`, `width`, `height`, `depth`, `colors: UInt32`, `data: [UInt8]`, `init(payload:) throws`, `payload`, `static func frontCover(data: Data, mimeType: String) -> FlacPicture`
  - `enum ImageInfo { static func pixelSize(of data: Data) -> (width: UInt32, height: UInt32)? }` (internal)

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/TagKitTests/VorbisPictureTests.swift`:

```swift
import Foundation
import Testing
@testable import TagKit

@Suite struct VorbisPictureTests {
    @Test func vorbisRoundTripIsCaseInsensitive() throws {
        var v = VorbisComment(vendor: "reference libFLAC 1.4.3")
        v.set("title", "Dreams")
        v.set("ARTIST", ["Prospa", "Rohan Pinnock-Hamilton"])
        v.set("Serato_Markers", "keep-me")
        let parsed = try VorbisComment(payload: v.payload)
        #expect(parsed.vendor == "reference libFLAC 1.4.3")
        #expect(parsed.first("TITLE") == "Dreams")
        #expect(parsed.values("artist") == ["Prospa", "Rohan Pinnock-Hamilton"])
        #expect(parsed.first("SERATO_MARKERS") == "keep-me")
    }

    @Test func setReplacesInPlaceAndRemovesOnNilOrEmpty() {
        var v = VorbisComment(fields: [.init(key: "A", value: "1"), .init(key: "TITLE", value: "old"), .init(key: "B", value: "2")])
        v.set("TITLE", "new")
        #expect(v.fields.map(\.key) == ["A", "TITLE", "B"])
        #expect(v.first("TITLE") == "new")
        v.set("TITLE", nil)
        #expect(v.first("TITLE") == nil)
        v.set("B", "")
        #expect(v.fields.map(\.key) == ["A"])
    }

    @Test func utf8ValuesSurvive() throws {
        var v = VorbisComment()
        v.set("ARTIST", "Rosalía")
        v.set("COMMENT", "Ünïcødé ✓")
        let parsed = try VorbisComment(payload: v.payload)
        #expect(parsed.first("ARTIST") == "Rosalía")
        #expect(parsed.first("COMMENT") == "Ünïcødé ✓")
    }

    @Test func pictureRoundTrip() throws {
        let pic = FlacPicture(pictureType: 3, mimeType: "image/jpeg", description: "cover",
                              width: 1280, height: 1280, depth: 24, colors: 0, data: [0xFF, 0xD8, 0xFF, 0xD9])
        #expect(try FlacPicture(payload: pic.payload) == pic)
    }

    @Test func frontCoverReadsPixelSize() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAEklEQVR4nGP4z8DwnwEIGHAwAFbmBfvxZqpZAAAAAElFTkSuQmCC")!
        let pic = FlacPicture.frontCover(data: png, mimeType: "image/png")
        #expect(pic.pictureType == 3)
        #expect(pic.width == 2)
        #expect(pic.height == 3)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter VorbisPictureTests`
Expected: FAIL de compilación — `cannot find 'VorbisComment' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/TagKit/Flac/VorbisComment.swift`:

```swift
import ByteKit
import Foundation

public struct VorbisComment: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key.uppercased()
            self.value = value
        }
    }

    public var vendor: String
    public private(set) var fields: [Field]

    public init(vendor: String = "Aether", fields: [Field] = []) {
        self.vendor = vendor
        self.fields = fields
    }

    public init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        let vendorLength = Int(try r.u32LE())
        vendor = String(decoding: try r.bytes(vendorLength), as: UTF8.self)
        let count = Int(try r.u32LE())
        var parsed: [Field] = []
        parsed.reserveCapacity(min(count, 256))
        for _ in 0..<count {
            let length = Int(try r.u32LE())
            let entry = String(decoding: try r.bytes(length), as: UTF8.self)
            guard let eq = entry.firstIndex(of: "=") else { continue }
            parsed.append(Field(key: String(entry[..<eq]), value: String(entry[entry.index(after: eq)...])))
        }
        fields = parsed
    }

    public var payload: [UInt8] {
        var w = ByteWriter()
        let vendorBytes = Array(vendor.utf8)
        w.u32LE(UInt32(vendorBytes.count))
        w.append(vendorBytes)
        w.u32LE(UInt32(fields.count))
        for field in fields {
            let entry = Array("\(field.key)=\(field.value)".utf8)
            w.u32LE(UInt32(entry.count))
            w.append(entry)
        }
        return w.bytes
    }

    public func values(_ key: String) -> [String] {
        let k = key.uppercased()
        return fields.filter { $0.key == k }.map(\.value)
    }

    public func first(_ key: String) -> String? { values(key).first }

    /// Replaces every value of `key`, keeping the position of its first occurrence. Empty values are dropped.
    public mutating func set(_ key: String, _ values: [String]) {
        let k = key.uppercased()
        let position = fields.firstIndex { $0.key == k }
        fields.removeAll { $0.key == k }
        let new = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { Field(key: k, value: $0) }
        fields.insert(contentsOf: new, at: min(position ?? fields.count, fields.count))
    }

    public mutating func set(_ key: String, _ value: String?) {
        set(key, value.map { [$0] } ?? [])
    }
}
```

`Packages/AetherKit/Sources/TagKit/Support/ImageInfo.swift`:

```swift
import Foundation
import ImageIO

enum ImageInfo {
    static func pixelSize(of data: Data) -> (width: UInt32, height: UInt32)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (UInt32(w), UInt32(h))
    }
}
```

`Packages/AetherKit/Sources/TagKit/Flac/FlacPicture.swift`:

```swift
public import Foundation
import ByteKit

public struct FlacPicture: Equatable, Sendable {
    public var pictureType: UInt32
    public var mimeType: String
    public var description: String
    public var width: UInt32
    public var height: UInt32
    public var depth: UInt32
    public var colors: UInt32
    public var data: [UInt8]

    public init(pictureType: UInt32 = 3, mimeType: String, description: String = "",
                width: UInt32 = 0, height: UInt32 = 0, depth: UInt32 = 24, colors: UInt32 = 0, data: [UInt8]) {
        self.pictureType = pictureType
        self.mimeType = mimeType
        self.description = description
        self.width = width
        self.height = height
        self.depth = depth
        self.colors = colors
        self.data = data
    }

    public init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        pictureType = try r.u32BE()
        mimeType = try r.ascii(Int(try r.u32BE()))
        description = String(decoding: try r.bytes(Int(try r.u32BE())), as: UTF8.self)
        width = try r.u32BE()
        height = try r.u32BE()
        depth = try r.u32BE()
        colors = try r.u32BE()
        data = try r.bytes(Int(try r.u32BE()))
    }

    public var payload: [UInt8] {
        var w = ByteWriter(reservingCapacity: 32 + data.count)
        w.u32BE(pictureType)
        let mime = Array(mimeType.utf8)
        w.u32BE(UInt32(mime.count)); w.append(mime)
        let desc = Array(description.utf8)
        w.u32BE(UInt32(desc.count)); w.append(desc)
        w.u32BE(width); w.u32BE(height); w.u32BE(depth); w.u32BE(colors)
        w.u32BE(UInt32(data.count)); w.append(data)
        return w.bytes
    }

    public static func frontCover(data: Data, mimeType: String) -> FlacPicture {
        let size = ImageInfo.pixelSize(of: data)
        return FlacPicture(pictureType: 3, mimeType: mimeType, width: size?.width ?? 0,
                           height: size?.height ?? 0, data: [UInt8](data))
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter VorbisPictureTests`
Expected: 5 PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(tagkit): add Vorbis comment and FLAC picture codecs"
```

---

### Task 3: `TrackTags` y lectura/escritura de tags FLAC

**Files:**
- Create: `Packages/AetherKit/Sources/TagKit/TrackTags.swift`
- Create: `Packages/AetherKit/Sources/TagKit/Flac/FlacTags.swift`
- Test: `Packages/AetherKit/Tests/TagKitTests/FlacTagsTests.swift`

**Interfaces:**
- Consumes: Task 1–2.
- Produces:
  - `public struct TrackTags: Equatable, Sendable, Codable` con `title, artist, album, albumArtist, genre, comment, label, key, isrc, composer, remixer, year: String?`, `bpm: Double?`, `trackNumber, discNumber: Int?`, `artwork: Artwork?`; `struct Artwork: Equatable, Sendable, Codable { data: Data; mimeType: String }`; `init(...)` con todos los parámetros opcionales; `withoutArtwork`; `isEffectivelyEmpty`; `static func formatBPM(_:) -> String`; `static func leadingInt(_:) -> Int?`
  - `extension TrackTags { init(vorbis: VorbisComment, frontCover: FlacPicture?); func apply(to: inout VorbisComment) }`
  - `public enum FlacTags { static func read(_ url: URL) throws -> (tags: TrackTags, streamInfo: StreamInfo, header: FlacHeader); static func blocks(applying: TrackTags, to: FlacHeader, extraFields: [String: String]) throws -> [FlacBlock]; static func write(_ tags: TrackTags, to url: URL, extraFields: [String: String] = [:]) throws }`
  - `extension String { var nilIfBlank: String? }` (internal)

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/TagKitTests/FlacTagsTests.swift`:

```swift
import Foundation
import Testing
@testable import TagKit

@Suite struct FlacTagsTests {
    static let sample = TrackTags(
        title: "Dreams (Extended Mix)", artist: "Prospa, Rohan Pinnock-Hamilton", album: "Free Your Mind",
        albumArtist: "Prospa", genre: "UK House", comment: nil, label: "CircoLoco Records", key: "8A",
        isrc: "QM6MZ2647627", composer: nil, remixer: nil, year: "2026-06-12", bpm: 128,
        trackNumber: 11, discNumber: 1,
        artwork: .init(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), mimeType: "image/jpeg"))

    @Test func bpmFormatting() {
        #expect(TrackTags.formatBPM(128) == "128")
        #expect(TrackTags.formatBPM(124.5) == "124.50")
        #expect(TrackTags.leadingInt("3/12") == 3)
        #expect(TrackTags.leadingInt("x") == nil)
    }

    @Test func vorbisMappingWritesRekordboxKeys() {
        var v = VorbisComment()
        Self.sample.apply(to: &v)
        #expect(v.first("LABEL") == "CircoLoco Records")
        #expect(v.first("ORGANIZATION") == "CircoLoco Records")
        #expect(v.first("INITIALKEY") == "8A")
        #expect(v.first("BPM") == "128")
        #expect(v.first("DATE") == "2026-06-12")
        #expect(v.first("TRACKNUMBER") == "11")
        #expect(v.first("COMMENT") == nil)
    }

    @Test func fileRoundTripPreservesUnknownBlocksAndAudio() throws {
        let seek = FlacBlock(type: FlacBlockType.seekTable, payload: Array(repeating: 3, count: 18))
        var existing = VorbisComment(vendor: "libFLAC")
        existing.set("SERATO_MARKERS_V2", "opaque")
        existing.set("TITLE", "Old")
        let audio = Array(repeating: UInt8(0x5A), count: 2048)
        let url = try Fixtures.flacFile(
            blocks: [Fixtures.streamInfo.block, seek, FlacBlock(type: FlacBlockType.vorbisComment, payload: existing.payload)],
            audio: audio)

        try FlacTags.write(Self.sample, to: url, extraFields: ["AETHER_VERIFIED": "md5:00"])
        let (tags, si, header) = try FlacTags.read(url)

        #expect(tags == Self.sample)
        #expect(si == Fixtures.streamInfo)
        #expect(header.blocks.contains(seek))
        let vorbis = try VorbisComment(payload: header.blocks(ofType: FlacBlockType.vorbisComment)[0].payload)
        #expect(vorbis.vendor == "libFLAC")
        #expect(vorbis.first("SERATO_MARKERS_V2") == "opaque")
        #expect(vorbis.first("AETHER_VERIFIED") == "md5:00")
        #expect(Array(try Fixtures.bytes(url).suffix(audio.count)) == audio)
    }

    @Test func removingArtworkDropsOnlyFrontCover() throws {
        let back = FlacPicture(pictureType: 4, mimeType: "image/jpeg", data: [1, 2, 3])
        let front = FlacPicture(pictureType: 3, mimeType: "image/jpeg", data: [4, 5, 6])
        let url = try Fixtures.flacFile(blocks: [
            Fixtures.streamInfo.block,
            FlacBlock(type: FlacBlockType.picture, payload: back.payload),
            FlacBlock(type: FlacBlockType.picture, payload: front.payload),
        ])
        var tags = try FlacTags.read(url).tags
        #expect(tags.artwork?.data == Data([4, 5, 6]))
        tags.artwork = nil
        try FlacTags.write(tags, to: url)
        let header = try FlacTags.read(url).header
        let pictures = try header.blocks(ofType: FlacBlockType.picture).map { try FlacPicture(payload: $0.payload) }
        #expect(pictures == [back])
    }

    @Test func readsLegacyKeyNames() {
        let v = VorbisComment(fields: [.init(key: "ORGANIZATION", value: "Defected"), .init(key: "KEY", value: "Am"),
                                       .init(key: "YEAR", value: "2019"), .init(key: "BPM", value: "124,5")])
        let tags = TrackTags(vorbis: v, frontCover: nil)
        #expect(tags.label == "Defected")
        #expect(tags.key == "Am")
        #expect(tags.year == "2019")
        #expect(tags.bpm == 124.5)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter FlacTagsTests`
Expected: FAIL de compilación — `cannot find 'TrackTags' in scope`.

- [ ] **Step 2: Implementar `TrackTags`**

`Packages/AetherKit/Sources/TagKit/TrackTags.swift`:

```swift
public import Foundation

/// Format-agnostic tag model used by Harvester (writing) and Cosmos (reading/editing).
public struct TrackTags: Equatable, Sendable, Codable {
    public struct Artwork: Equatable, Sendable, Codable {
        public var data: Data
        public var mimeType: String

        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var comment: String?
    public var label: String?
    public var key: String?
    public var isrc: String?
    public var composer: String?
    public var remixer: String?
    /// Year or full ISO date ("2026" or "2026-06-12").
    public var year: String?
    public var bpm: Double?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var artwork: Artwork?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, comment: String? = nil, label: String? = nil, key: String? = nil,
                isrc: String? = nil, composer: String? = nil, remixer: String? = nil, year: String? = nil,
                bpm: Double? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, artwork: Artwork? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.comment = comment
        self.label = label
        self.key = key
        self.isrc = isrc
        self.composer = composer
        self.remixer = remixer
        self.year = year
        self.bpm = bpm
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artwork = artwork
    }

    public var withoutArtwork: TrackTags {
        var copy = self
        copy.artwork = nil
        return copy
    }

    /// "Sin tags" in Cosmos: no usable title or artist.
    public var isEffectivelyEmpty: Bool { title?.nilIfBlank == nil || artist?.nilIfBlank == nil }

    public static func formatBPM(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    public static func leadingInt(_ text: String) -> Int? {
        Int(text.prefix { $0.isNumber })
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

- [ ] **Step 3: Implementar mapeo Vorbis y `FlacTags`**

`Packages/AetherKit/Sources/TagKit/Flac/FlacTags.swift`:

```swift
public import Foundation

extension TrackTags {
    public init(vorbis v: VorbisComment, frontCover: FlacPicture?) {
        self.init(
            title: v.first("TITLE")?.nilIfBlank,
            artist: v.values("ARTIST").joined(separator: ", ").nilIfBlank,
            album: v.first("ALBUM")?.nilIfBlank,
            albumArtist: (v.first("ALBUMARTIST") ?? v.first("ALBUM ARTIST"))?.nilIfBlank,
            genre: v.first("GENRE")?.nilIfBlank,
            comment: (v.first("COMMENT") ?? v.first("DESCRIPTION"))?.nilIfBlank,
            label: (v.first("LABEL") ?? v.first("ORGANIZATION") ?? v.first("PUBLISHER"))?.nilIfBlank,
            key: (v.first("INITIALKEY") ?? v.first("KEY"))?.nilIfBlank,
            isrc: v.first("ISRC")?.nilIfBlank,
            composer: v.first("COMPOSER")?.nilIfBlank,
            remixer: (v.first("REMIXER") ?? v.first("MIXARTIST"))?.nilIfBlank,
            year: (v.first("DATE") ?? v.first("YEAR"))?.nilIfBlank,
            bpm: v.first("BPM").flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) },
            trackNumber: v.first("TRACKNUMBER").flatMap(TrackTags.leadingInt),
            discNumber: v.first("DISCNUMBER").flatMap(TrackTags.leadingInt),
            artwork: frontCover.map { Artwork(data: Data($0.data), mimeType: $0.mimeType) })
    }

    /// Writes managed keys only; unknown keys (Serato, MIK, ReplayGain…) are untouched.
    public func apply(to v: inout VorbisComment) {
        v.set("TITLE", title)
        v.set("ARTIST", artist)
        v.set("ALBUM", album)
        v.set("ALBUMARTIST", albumArtist)
        v.set("GENRE", genre)
        v.set("COMMENT", comment)
        v.set("LABEL", label)
        v.set("ORGANIZATION", label)
        v.set("INITIALKEY", key)
        v.set("ISRC", isrc)
        v.set("COMPOSER", composer)
        v.set("REMIXER", remixer)
        v.set("DATE", year)
        v.set("YEAR", nil)
        v.set("BPM", bpm.map(TrackTags.formatBPM))
        v.set("TRACKNUMBER", trackNumber.map(String.init))
        v.set("DISCNUMBER", discNumber.map(String.init))
    }
}

public enum FlacTags {
    public static func read(_ url: URL) throws -> (tags: TrackTags, streamInfo: StreamInfo, header: FlacHeader) {
        let header = try FlacMetadataIO.read(url)
        let vorbis = try header.blocks(ofType: FlacBlockType.vorbisComment).first.map { try VorbisComment(payload: $0.payload) }
            ?? VorbisComment()
        let pictures = try header.blocks(ofType: FlacBlockType.picture).map { try FlacPicture(payload: $0.payload) }
        let front = pictures.first { $0.pictureType == 3 } ?? pictures.first
        return (TrackTags(vorbis: vorbis, frontCover: front), try header.streamInfo(), header)
    }

    /// Block order: STREAMINFO, other non-tag blocks, VORBIS_COMMENT, non-front pictures, front cover. No padding.
    public static func blocks(applying tags: TrackTags, to header: FlacHeader,
                              extraFields: [String: String] = [:]) throws -> [FlacBlock] {
        var vorbis = try header.blocks(ofType: FlacBlockType.vorbisComment).first.map { try VorbisComment(payload: $0.payload) }
            ?? VorbisComment()
        tags.apply(to: &vorbis)
        for (key, value) in extraFields.sorted(by: { $0.key < $1.key }) { vorbis.set(key, value) }

        let streamInfo = header.blocks[0]
        let others = header.blocks.dropFirst().filter {
            ![FlacBlockType.vorbisComment, FlacBlockType.padding, FlacBlockType.picture].contains($0.type)
        }
        let keptPictures = try header.blocks(ofType: FlacBlockType.picture).filter {
            try FlacPicture(payload: $0.payload).pictureType != 3
        }
        var result = [streamInfo] + others + [FlacBlock(type: FlacBlockType.vorbisComment, payload: vorbis.payload)] + keptPictures
        if let art = tags.artwork {
            result.append(FlacBlock(type: FlacBlockType.picture,
                                    payload: FlacPicture.frontCover(data: art.data, mimeType: art.mimeType).payload))
        }
        return result
    }

    public static func write(_ tags: TrackTags, to url: URL, extraFields: [String: String] = [:]) throws {
        let header = try FlacMetadataIO.read(url)
        try FlacMetadataIO.write(try blocks(applying: tags, to: header, extraFields: extraFields), to: url)
    }
}
```

- [ ] **Step 4: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter FlacTagsTests`
Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(tagkit): add unified TrackTags with FLAC Vorbis mapping for rekordbox"
```

---

### Task 4: Codec ID3v2.3/2.4

**Files:**
- Create: `Packages/AetherKit/Sources/TagKit/ID3/ID3Tag.swift`
- Create: `Packages/AetherKit/Sources/TagKit/ID3/ID3Text.swift`
- Test: `Packages/AetherKit/Tests/TagKitTests/ID3TagTests.swift`

**Interfaces:**
- Produces:
  - `public enum ID3Error: Error, Equatable { case unsupportedVersion(UInt8); case malformed }`
  - `public struct ID3Frame: Equatable, Sendable { var id: String; var flags: UInt16; var payload: [UInt8]; func content(major: UInt8) -> [UInt8] }`
  - `public struct ID3Tag: Equatable, Sendable` con `majorVersion: UInt8`, `frames: [ID3Frame]`, `init(majorVersion: UInt8 = 3, frames: [ID3Frame] = [])`, `static func declaredSize(header: [UInt8]) -> Int?`, `static func parse(_ bytes: [UInt8]) throws -> ID3Tag`, `func serialize(minimumSize: Int = 0, padding: Int = 2048) -> [UInt8]`, `mutating func remove(_ id: String)`, `mutating func setText(_ id: String, _ value: String?)`, `func text(_ id: String) -> String?`
  - `enum ID3Text { static func decode(_ content: [UInt8]) -> [String]; static func encode(_ s: String) -> [UInt8]; static func splitTerminated(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> (head: [UInt8], rest: ArraySlice<UInt8>); static func decodeString(_ bytes: [UInt8], encoding: UInt8) -> String? }` (internal)
  - `func removeUnsynchronisation(_ bytes: [UInt8]) -> [UInt8]` (internal)

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/TagKitTests/ID3TagTests.swift`:

```swift
import Testing
@testable import TagKit

@Suite struct ID3TagTests {
    @Test func textCodecLatin1AndUTF16() {
        #expect(ID3Text.encode("Prospa") == [0] + Array("Prospa".utf8))
        let encoded = ID3Text.encode("Rosalía ✓")
        #expect(encoded.prefix(3) == [1, 0xFF, 0xFE])
        #expect(ID3Text.decode(encoded) == ["Rosalía ✓"])
        #expect(ID3Text.decode([3] + Array("a".utf8) + [0] + Array("b".utf8)) == ["a", "b"])
        #expect(ID3Text.decode([2, 0x00, 0x41]) == ["A"])
    }

    @Test func v23RoundTripKeepsUnknownFramesAndPads() throws {
        var tag = ID3Tag(majorVersion: 3)
        tag.setText("TIT2", "Feel")
        tag.frames.append(ID3Frame(id: "GEOB", flags: 0, payload: [9, 9, 9]))
        let bytes = tag.serialize(minimumSize: 0, padding: 100)
        #expect(ID3Tag.declaredSize(header: Array(bytes.prefix(10))) == bytes.count)
        let parsed = try ID3Tag.parse(bytes)
        #expect(parsed.majorVersion == 3)
        #expect(parsed.text("TIT2") == "Feel")
        #expect(parsed.frames.contains(ID3Frame(id: "GEOB", flags: 0, payload: [9, 9, 9])))
    }

    @Test func serializeFillsMinimumSizeExactly() throws {
        var tag = ID3Tag(majorVersion: 4)
        tag.setText("TPE1", "Kettama")
        let bytes = tag.serialize(minimumSize: 500)
        #expect(bytes.count == 500)
        #expect(try ID3Tag.parse(bytes).text("TPE1") == "Kettama")
    }

    @Test func v24UsesSyncsafeFrameSizes() throws {
        var tag = ID3Tag(majorVersion: 4)
        tag.setText("TIT2", String(repeating: "x", count: 200))
        let bytes = tag.serialize(minimumSize: 0, padding: 0)
        // Frame size 201 as syncsafe = 0x00 0x00 0x01 0x49
        #expect(Array(bytes[14..<18]) == [0x00, 0x00, 0x01, 0x49])
        #expect(try ID3Tag.parse(bytes).text("TIT2")?.count == 200)
    }

    @Test func setTextKeepsPositionAndRemovesOnNil() {
        var tag = ID3Tag(frames: [ID3Frame(id: "TPE1", flags: 0, payload: ID3Text.encode("A")),
                                  ID3Frame(id: "TIT2", flags: 0, payload: ID3Text.encode("B"))])
        tag.setText("TPE1", "C")
        #expect(tag.frames.map(\.id) == ["TPE1", "TIT2"])
        tag.setText("TPE1", nil)
        #expect(tag.frames.map(\.id) == ["TIT2"])
    }

    @Test func rejectsID3v22() {
        let bytes: [UInt8] = Array("ID3".utf8) + [2, 0, 0, 0, 0, 0, 0]
        #expect(throws: ID3Error.unsupportedVersion(2)) { try ID3Tag.parse(bytes) }
    }

    @Test func undoesTagLevelUnsynchronisation() throws {
        // v2.3 tag with unsync flag; frame payload [0, FF, 00, E0] must decode to [0, FF, E0].
        let framePayload: [UInt8] = [0x00, 0xFF, 0x00, 0xE0]
        let frame: [UInt8] = Array("TXXX".utf8) + [0, 0, 0, 3] + [0, 0] + framePayload
        let bytes: [UInt8] = Array("ID3".utf8) + [3, 0, 0x80, 0, 0, 0, UInt8(frame.count)] + frame
        let parsed = try ID3Tag.parse(bytes)
        #expect(parsed.frames.first?.payload == [0x00, 0xFF, 0xE0])
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter ID3TagTests`
Expected: FAIL de compilación — `cannot find 'ID3Text' in scope`.

- [ ] **Step 2: Implementar `ID3Text`**

`Packages/AetherKit/Sources/TagKit/ID3/ID3Text.swift`:

```swift
import Foundation

/// ID3v2 text encodings: 0 ISO-8859-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8.
enum ID3Text {
    static func decode(_ content: [UInt8]) -> [String] {
        guard let encoding = content.first else { return [] }
        var rest = content.dropFirst()
        var values: [String] = []
        while !rest.isEmpty {
            let (head, tail) = splitTerminated(rest, encoding: encoding)
            if let s = decodeString(head, encoding: encoding), !s.isEmpty { values.append(s) }
            rest = tail
        }
        return values
    }

    /// Encodes for ID3v2.3 compatibility: Latin-1 when possible, otherwise UTF-16 LE with BOM.
    static func encode(_ s: String) -> [UInt8] {
        if s.unicodeScalars.allSatisfy({ $0.value < 0x100 }) {
            return [0] + s.unicodeScalars.map { UInt8($0.value) }
        }
        return [1, 0xFF, 0xFE] + s.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
    }

    static func terminator(for encoding: UInt8) -> [UInt8] { encoding == 1 || encoding == 2 ? [0, 0] : [0] }

    /// Splits at the first terminator; `rest` is empty when none is found.
    static func splitTerminated(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> (head: [UInt8], rest: ArraySlice<UInt8>) {
        var i = bytes.startIndex
        if encoding == 1 || encoding == 2 {
            while i + 1 < bytes.endIndex {
                if bytes[i] == 0, bytes[i + 1] == 0 { return (Array(bytes[bytes.startIndex..<i]), bytes[(i + 2)...]) }
                i += 2
            }
        } else if let z = bytes.firstIndex(of: 0) {
            return (Array(bytes[bytes.startIndex..<z]), bytes[(z + 1)...])
        }
        return (Array(bytes), [])
    }

    static func decodeString(_ bytes: [UInt8], encoding: UInt8) -> String? {
        switch encoding {
        case 0: return String(bytes: bytes, encoding: .isoLatin1)
        case 1:
            if bytes.starts(with: [0xFE, 0xFF]) { return String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian) }
            if bytes.starts(with: [0xFF, 0xFE]) { return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian) }
            return String(bytes: bytes, encoding: .utf16LittleEndian)
        case 2: return String(bytes: bytes, encoding: .utf16BigEndian)
        case 3: return String(bytes: bytes, encoding: .utf8)
        default: return nil
        }
    }
}

/// Reverses ID3 unsynchronisation: every `FF 00` becomes `FF`.
func removeUnsynchronisation(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        out.append(bytes[i])
        if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0x00 { i += 2 } else { i += 1 }
    }
    return out
}
```

- [ ] **Step 3: Implementar `ID3Tag`**

`Packages/AetherKit/Sources/TagKit/ID3/ID3Tag.swift`:

```swift
import ByteKit

public enum ID3Error: Error, Equatable, Sendable {
    case unsupportedVersion(UInt8)
    case malformed
}

public struct ID3Frame: Equatable, Sendable {
    public var id: String
    public var flags: UInt16
    public var payload: [UInt8]

    public init(id: String, flags: UInt16, payload: [UInt8]) {
        self.id = id
        self.flags = flags
        self.payload = payload
    }

    /// Payload with v2.4 per-frame unsynchronisation and data-length indicator removed.
    public func content(major: UInt8) -> [UInt8] {
        guard major == 4 else { return payload }
        var bytes = payload
        if flags & 0x0001 != 0, bytes.count >= 4 { bytes.removeFirst(4) }
        if flags & 0x0002 != 0 { bytes = removeUnsynchronisation(bytes) }
        return bytes
    }
}

public struct ID3Tag: Equatable, Sendable {
    public var majorVersion: UInt8
    public var frames: [ID3Frame]

    public init(majorVersion: UInt8 = 3, frames: [ID3Frame] = []) {
        self.majorVersion = majorVersion
        self.frames = frames
    }

    /// Total on-disk size (header + body + optional v2.4 footer) declared by a 10-byte header.
    public static func declaredSize(header: [UInt8]) -> Int? {
        guard header.count >= 10, header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil }
        let size = header[6..<10].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        let footer = header[3] == 4 && header[5] & 0x10 != 0 ? 10 : 0
        return 10 + size + footer
    }

    public static func parse(_ bytes: [UInt8]) throws -> ID3Tag {
        guard declaredSize(header: Array(bytes.prefix(10))) != nil else { throw ID3Error.malformed }
        let major = bytes[3]
        guard major == 3 || major == 4 else { throw ID3Error.unsupportedVersion(major) }
        let flags = bytes[5]
        let bodySize = bytes[6..<10].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        var body = Array(bytes[10..<min(10 + bodySize, bytes.count)])
        if major == 3, flags & 0x80 != 0 { body = removeUnsynchronisation(body) }

        var r = ByteReader(body)
        if flags & 0x40 != 0 {
            if major == 3 { try r.skip(Int(try r.u32BE())) } else { try r.skip(Int(try r.syncsafe32()) - 4) }
        }
        var frames: [ID3Frame] = []
        while r.remaining >= 10, try r.peek() != 0 {
            let id = try r.ascii(4)
            guard id.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else { break }
            let size = try Int(major == 4 ? r.syncsafe32() : r.u32BE())
            let frameFlags = try r.u16BE()
            guard size <= r.remaining else { break }
            frames.append(ID3Frame(id: id, flags: frameFlags, payload: try r.bytes(size)))
        }
        return ID3Tag(majorVersion: major, frames: frames)
    }

    /// When the body fits in `minimumSize` the result is exactly that long (in-place rewrite);
    /// otherwise `padding` zero bytes are appended for future edits.
    public func serialize(minimumSize: Int = 0, padding: Int = 2048) -> [UInt8] {
        var body = ByteWriter()
        for frame in frames {
            body.ascii(frame.id)
            if majorVersion == 4 { body.syncsafe32(UInt32(frame.payload.count)) } else { body.u32BE(UInt32(frame.payload.count)) }
            body.u16BE(frame.flags)
            body.append(frame.payload)
        }
        var bodyBytes = body.bytes
        let available = minimumSize - 10
        let fill = available >= bodyBytes.count ? available - bodyBytes.count : padding
        bodyBytes.append(contentsOf: repeatElement(0, count: fill))

        var w = ByteWriter(reservingCapacity: 10 + bodyBytes.count)
        w.ascii("ID3")
        w.u8(majorVersion)
        w.u8(0)
        w.u8(0)
        w.syncsafe32(UInt32(bodyBytes.count))
        w.append(bodyBytes)
        return w.bytes
    }

    public mutating func remove(_ id: String) { frames.removeAll { $0.id == id } }

    public mutating func setText(_ id: String, _ value: String?) {
        let position = frames.firstIndex { $0.id == id }
        remove(id)
        guard let value = value?.nilIfBlank else { return }
        frames.insert(ID3Frame(id: id, flags: 0, payload: ID3Text.encode(value)),
                      at: min(position ?? frames.count, frames.count))
    }

    public func text(_ id: String) -> String? {
        frames.first { $0.id == id }
            .map { ID3Text.decode($0.content(major: majorVersion)).joined(separator: ", ") }?
            .nilIfBlank
    }
}
```

- [ ] **Step 4: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter ID3TagTests`
Expected: 7 PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(tagkit): add ID3v2.3/2.4 codec preserving unknown frames"
```

---

### Task 5: Mapeo ID3 ↔ `TrackTags` y E/S de MP3

**Files:**
- Create: `Packages/AetherKit/Sources/TagKit/ID3/ID3Mapping.swift`
- Create: `Packages/AetherKit/Sources/TagKit/ID3/ID3FileIO.swift`
- Test: `Packages/AetherKit/Tests/TagKitTests/ID3FileIOTests.swift`

**Interfaces:**
- Consumes: Task 3–4.
- Produces:
  - `extension TrackTags { init(id3: ID3Tag); func apply(to: inout ID3Tag) }`
  - `public enum ID3FileIO { static func readTag(_ url: URL) throws -> (tag: ID3Tag?, totalSize: Int); static func read(_ url: URL) throws -> TrackTags; static func write(_ tags: TrackTags, to url: URL) throws }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/TagKitTests/ID3FileIOTests.swift`:

```swift
import Foundation
import Testing
@testable import TagKit

@Suite struct ID3FileIOTests {
    private let audio: [UInt8] = [0xFF, 0xFB, 0x90, 0x64] + Array(repeating: 0x11, count: 4000)

    private func mp3(with tag: ID3Tag?) throws -> URL {
        let url = Fixtures.tempURL("mp3")
        try Data((tag?.serialize(minimumSize: 0, padding: 512) ?? []) + audio).write(to: url)
        return url
    }

    @Test func writesNewV23TagOnUntaggedFile() throws {
        let url = try mp3(with: nil)
        try ID3FileIO.write(FlacTagsTests.sample, to: url)
        let (tag, _) = try ID3FileIO.readTag(url)
        #expect(tag?.majorVersion == 3)
        #expect(tag?.text("TYER") == "2026")
        #expect(tag?.text("TPUB") == "CircoLoco Records")
        #expect(tag?.text("TKEY") == "8A")
        let tags = try ID3FileIO.read(url)
        #expect(tags.title == "Dreams (Extended Mix)")
        #expect(tags.artwork == FlacTagsTests.sample.artwork)
        #expect(tags.year == "2026")
        #expect(Array(try Fixtures.bytes(url).suffix(audio.count)) == audio)
    }

    @Test func editsInPlaceWithinPaddingAndKeepsGEOB() throws {
        var existing = ID3Tag(majorVersion: 4)
        existing.setText("TIT2", "Old")
        existing.frames.append(ID3Frame(id: "GEOB", flags: 0, payload: Array(repeating: 7, count: 64)))
        let url = try mp3(with: existing)
        let sizeBefore = try Fixtures.bytes(url).count

        try ID3FileIO.write(TrackTags(title: "Comes and Goes", artist: "Kettama", year: "2019-05-01"), to: url)

        #expect(try Fixtures.bytes(url).count == sizeBefore)
        let (tag, _) = try ID3FileIO.readTag(url)
        #expect(tag?.majorVersion == 4)
        #expect(tag?.text("TDRC") == "2019-05-01")
        #expect(tag?.frames.contains { $0.id == "GEOB" } == true)
        #expect(try ID3FileIO.read(url).title == "Comes and Goes")
    }

    @Test func commentAndNumbers() throws {
        let url = try mp3(with: nil)
        try ID3FileIO.write(TrackTags(title: "T", comment: "warm-up", trackNumber: 3, discNumber: 2), to: url)
        let tags = try ID3FileIO.read(url)
        #expect(tags.comment == "warm-up")
        #expect(tags.trackNumber == 3)
        #expect(tags.discNumber == 2)
    }

    @Test func genreNumericPrefixIsStripped() {
        var tag = ID3Tag()
        tag.setText("TCON", "(18)Techno")
        #expect(TrackTags(id3: tag).genre == "Techno")
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter ID3FileIOTests`
Expected: FAIL de compilación — `cannot find 'ID3FileIO' in scope`.

- [ ] **Step 2: Implementar mapeo**

`Packages/AetherKit/Sources/TagKit/ID3/ID3Mapping.swift`:

```swift
import Foundation

extension TrackTags {
    public init(id3 tag: ID3Tag) {
        self.init(
            title: tag.text("TIT2"),
            artist: tag.text("TPE1"),
            album: tag.text("TALB"),
            albumArtist: tag.text("TPE2"),
            genre: tag.text("TCON").map(Self.stripNumericGenre),
            comment: Self.comment(in: tag),
            label: tag.text("TPUB"),
            key: tag.text("TKEY"),
            isrc: tag.text("TSRC"),
            composer: tag.text("TCOM"),
            remixer: tag.text("TPE4"),
            year: tag.text("TDRC") ?? tag.text("TYER"),
            bpm: tag.text("TBPM").flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) },
            trackNumber: tag.text("TRCK").flatMap(TrackTags.leadingInt),
            discNumber: tag.text("TPOS").flatMap(TrackTags.leadingInt),
            artwork: Self.frontCover(in: tag))
    }

    public func apply(to tag: inout ID3Tag) {
        tag.setText("TIT2", title)
        tag.setText("TPE1", artist)
        tag.setText("TALB", album)
        tag.setText("TPE2", albumArtist)
        tag.setText("TCON", genre)
        tag.setText("TPUB", label)
        tag.setText("TKEY", key)
        tag.setText("TSRC", isrc)
        tag.setText("TCOM", composer)
        tag.setText("TPE4", remixer)
        tag.setText("TBPM", bpm.map(TrackTags.formatBPM))
        tag.setText("TRCK", trackNumber.map(String.init))
        tag.setText("TPOS", discNumber.map(String.init))

        let isV4 = tag.majorVersion == 4
        let yearValue = isV4 ? year : year.map { String($0.prefix(4)) }
        let yearPosition = tag.frames.firstIndex { $0.id == "TDRC" || $0.id == "TYER" }
        tag.remove("TDRC")
        tag.remove("TYER")
        if let yearValue = yearValue?.nilIfBlank {
            tag.frames.insert(ID3Frame(id: isV4 ? "TDRC" : "TYER", flags: 0, payload: ID3Text.encode(yearValue)),
                              at: min(yearPosition ?? tag.frames.count, tag.frames.count))
        }

        tag.frames.removeAll { $0.id == "COMM" && Self.commentDescriptionIsEmpty($0, major: tag.majorVersion) }
        if let comment = comment?.nilIfBlank {
            let text = ID3Text.encode(comment)
            let encoding = text[0]
            let payload = [encoding] + Array("eng".utf8) + ID3Text.terminator(for: encoding)
                + (encoding == 1 ? [0xFF, 0xFE] : []) + text.dropFirst(encoding == 1 ? 3 : 1)
            tag.frames.append(ID3Frame(id: "COMM", flags: 0, payload: payload))
        }

        tag.frames.removeAll { $0.id == "APIC" && Self.pictureType($0, major: tag.majorVersion) == 3 }
        if let art = artwork {
            let payload: [UInt8] = [0] + Array(art.mimeType.utf8) + [0] + [3] + [0] + [UInt8](art.data)
            tag.frames.append(ID3Frame(id: "APIC", flags: 0, payload: payload))
        }
    }

    private static func stripNumericGenre(_ genre: String) -> String {
        guard genre.hasPrefix("("), let close = genre.firstIndex(of: ")") else { return genre }
        let rest = genre[genre.index(after: close)...]
        return rest.isEmpty ? genre : String(rest)
    }

    private static func commentParts(_ frame: ID3Frame, major: UInt8) -> (description: String, text: String)? {
        let c = frame.content(major: major)
        guard c.count >= 4 else { return nil }
        let encoding = c[0]
        let (desc, rest) = ID3Text.splitTerminated(c[4...], encoding: encoding)
        let text = ID3Text.decodeString(Array(rest), encoding: encoding)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return (ID3Text.decodeString(desc, encoding: encoding) ?? "", text ?? "")
    }

    private static func commentDescriptionIsEmpty(_ frame: ID3Frame, major: UInt8) -> Bool {
        commentParts(frame, major: major)?.description.isEmpty ?? true
    }

    private static func comment(in tag: ID3Tag) -> String? {
        let comments = tag.frames.filter { $0.id == "COMM" }.compactMap { commentParts($0, major: tag.majorVersion) }
        return (comments.first { $0.description.isEmpty } ?? comments.first)?.text.nilIfBlank
    }

    private static func pictureParts(_ frame: ID3Frame, major: UInt8) -> (mime: String, type: UInt8, data: [UInt8])? {
        let c = frame.content(major: major)
        guard let encoding = c.first, let mimeEnd = c.dropFirst().firstIndex(of: 0), mimeEnd + 1 < c.count else { return nil }
        let mime = String(decoding: c[1..<mimeEnd], as: UTF8.self)
        let type = c[mimeEnd + 1]
        let (_, data) = ID3Text.splitTerminated(c[(mimeEnd + 2)...], encoding: encoding)
        return (mime.isEmpty ? "image/jpeg" : mime, type, Array(data))
    }

    private static func pictureType(_ frame: ID3Frame, major: UInt8) -> UInt8? { pictureParts(frame, major: major)?.type }

    private static func frontCover(in tag: ID3Tag) -> Artwork? {
        let pictures = tag.frames.filter { $0.id == "APIC" }.compactMap { pictureParts($0, major: tag.majorVersion) }
        return (pictures.first { $0.type == 3 } ?? pictures.first).map { Artwork(data: Data($0.data), mimeType: $0.mime) }
    }
}
```

- [ ] **Step 3: Implementar E/S de MP3**

`Packages/AetherKit/Sources/TagKit/ID3/ID3FileIO.swift`:

```swift
public import Foundation
import ByteKit

/// ID3v2 at the start of a file (MP3). ID3v1 at the end is left untouched.
public enum ID3FileIO {
    public static func readTag(_ url: URL) throws -> (tag: ID3Tag?, totalSize: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = (try handle.read(upToCount: 10)).map { [UInt8]($0) } ?? []
        guard let total = ID3Tag.declaredSize(header: head) else { return (nil, 0) }
        let body = try handle.read(upToCount: total - 10).map { [UInt8]($0) } ?? []
        return (try ID3Tag.parse(head + body), total)
    }

    public static func read(_ url: URL) throws -> TrackTags {
        try readTag(url).tag.map(TrackTags.init(id3:)) ?? TrackTags()
    }

    public static func write(_ tags: TrackTags, to url: URL) throws {
        let (existing, total) = try readTag(url)
        var tag = existing ?? ID3Tag(majorVersion: 3)
        tags.apply(to: &tag)
        try HeaderRegionRewriter.replace(fileAt: url, oldLength: total, with: tag.serialize(minimumSize: total))
    }
}
```

- [ ] **Step 4: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter ID3FileIOTests`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(tagkit): map ID3 frames to TrackTags and edit MP3 tags in place"
```

---

### Task 6: Chunk ID3 en WAV y AIFF

**Files:**
- Create: `Packages/AetherKit/Sources/TagKit/Chunks/ChunkID3IO.swift`
- Test: `Packages/AetherKit/Tests/TagKitTests/ChunkID3IOTests.swift`

**Interfaces:**
- Consumes: `ID3Tag`, `TrackTags.init(id3:)`, `apply(to: inout ID3Tag)`.
- Produces: `public enum ChunkID3IO { static func read(_ url: URL) throws -> TrackTags; static func write(_ tags: TrackTags, to url: URL) throws }`, `public enum ChunkError: Error, Equatable { case notChunked }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/TagKitTests/ChunkID3IOTests.swift`:

```swift
import Foundation
import Testing
@testable import TagKit

@Suite struct ChunkID3IOTests {
    private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] { le32(v).reversed() }

    private func wav(extraChunks: [UInt8] = []) throws -> URL {
        let fmt = Array("fmt ".utf8) + le32(16) + [1, 0, 2, 0] + le32(44_100) + le32(176_400) + [4, 0, 16, 0]
        let data = Array("data".utf8) + le32(8) + [1, 2, 3, 4, 5, 6, 7, 8]
        let body = Array("WAVE".utf8) + fmt + data + extraChunks
        let url = Fixtures.tempURL("wav")
        try Data(Array("RIFF".utf8) + le32(body.count) + body).write(to: url)
        return url
    }

    private func aiff() throws -> URL {
        let comm = Array("COMM".utf8) + be32(18) + [0, 2, 0, 0, 0, 2, 0, 16, 0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]
        let ssnd = Array("SSND".utf8) + be32(16) + [0, 0, 0, 0, 0, 0, 0, 0, 9, 9, 9, 9, 9, 9, 9, 9]
        let body = Array("AIFF".utf8) + comm + ssnd
        let url = Fixtures.tempURL("aiff")
        try Data(Array("FORM".utf8) + be32(body.count) + body).write(to: url)
        return url
    }

    private func containerSize(_ bytes: [UInt8], littleEndian: Bool) -> Int {
        let s = Array(bytes[4..<8])
        return littleEndian ? s.reversed().reduce(0) { $0 << 8 | Int($1) } : s.reduce(0) { $0 << 8 | Int($1) }
    }

    @Test func wavRoundTripAndSizeField() throws {
        let url = try wav()
        try ChunkID3IO.write(TrackTags(title: "b2b sept", artist: "Jean"), to: url)
        let bytes = try Fixtures.bytes(url)
        #expect(containerSize(bytes, littleEndian: true) == bytes.count - 8)
        #expect(try ChunkID3IO.read(url).title == "b2b sept")
        try ChunkID3IO.write(TrackTags(title: "renamed", artist: "Jean"), to: url)
        let again = try Fixtures.bytes(url)
        #expect(containerSize(again, littleEndian: true) == again.count - 8)
        #expect(try ChunkID3IO.read(url).title == "renamed")
        let occurrences = again.indices.dropLast(3).filter { Array(again[$0..<($0 + 4)]) == Array("id3 ".utf8) }
        #expect(occurrences.count == 1)
        let dataRange = again.firstRange(of: Array("data".utf8))!
        #expect(Array(again[(dataRange.upperBound + 4)..<(dataRange.upperBound + 12)]) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func wavWithID3InTheMiddleIsRewritten() throws {
        var middle = ID3Tag()
        middle.setText("TIT2", "old")
        let tagBytes = middle.serialize(minimumSize: 0, padding: 0)
        let chunk = Array("id3 ".utf8) + le32(tagBytes.count) + tagBytes + (tagBytes.count % 2 == 1 ? [0] : [])
        let trailer = Array("LIST".utf8) + le32(4) + Array("INFO".utf8)
        let url = try wav(extraChunks: chunk + trailer)
        try ChunkID3IO.write(TrackTags(title: "new"), to: url)
        let bytes = try Fixtures.bytes(url)
        #expect(containerSize(bytes, littleEndian: true) == bytes.count - 8)
        #expect(try ChunkID3IO.read(url).title == "new")
        #expect(bytes.firstRange(of: Array("LIST".utf8)) != nil)
    }

    @Test func aiffRoundTrip() throws {
        let url = try aiff()
        try ChunkID3IO.write(TrackTags(title: "Feel", artist: "Franky Rizardo", bpm: 124), to: url)
        let bytes = try Fixtures.bytes(url)
        #expect(containerSize(bytes, littleEndian: false) == bytes.count - 8)
        let tags = try ChunkID3IO.read(url)
        #expect(tags.artist == "Franky Rizardo")
        #expect(tags.bpm == 124)
    }

    @Test func rejectsOtherFiles() throws {
        let url = Fixtures.tempURL("wav")
        try Data("fLaC".utf8).write(to: url)
        #expect(throws: ChunkError.notChunked) { try ChunkID3IO.read(url) }
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter ChunkID3IOTests`
Expected: FAIL de compilación — `cannot find 'ChunkID3IO' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/TagKit/Chunks/ChunkID3IO.swift`:

```swift
public import Foundation
import ByteKit

public enum ChunkError: Error, Equatable, Sendable { case notChunked }

/// ID3v2 stored as a chunk: `id3 ` in RIFF/WAVE (little-endian sizes), `ID3 ` in FORM/AIFF (big-endian).
/// Only chunk headers are read; audio is never loaded.
public enum ChunkID3IO {
    private enum Kind { case riff, aiff }
    private struct Chunk { let id: String; let offset: Int; let size: Int; var end: Int { offset + 8 + size + (size & 1) } }

    public static func read(_ url: URL) throws -> TrackTags {
        let (_, chunks, _) = try layout(url)
        guard let chunk = chunks.first(where: { isID3($0.id) }) else { return TrackTags() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(chunk.offset + 8))
        return TrackTags(id3: try ID3Tag.parse(try handle.readExactly(chunk.size)))
    }

    public static func write(_ tags: TrackTags, to url: URL) throws {
        let (kind, chunks, fileSize) = try layout(url)
        let existing = chunks.first { isID3($0.id) }
        var tag = ID3Tag(majorVersion: 3)
        if let existing {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(existing.offset + 8))
            tag = try ID3Tag.parse(try handle.readExactly(existing.size))
            try handle.close()
        }
        tags.apply(to: &tag)
        let tagBytes = tag.serialize(minimumSize: 0, padding: 1024)
        var chunk = ByteWriter()
        chunk.ascii(kind == .riff ? "id3 " : "ID3 ")
        if kind == .riff { chunk.u32LE(UInt32(tagBytes.count)) } else { chunk.u32BE(UInt32(tagBytes.count)) }
        chunk.append(tagBytes)
        if tagBytes.count % 2 == 1 { chunk.u8(0) }

        if let existing, existing.end < fileSize {
            try rewriteWithout(existing, appending: chunk.bytes, kind: kind, url: url, fileSize: fileSize)
        } else {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let cut = existing?.offset ?? fileSize + (fileSize & 1)
            try handle.truncate(atOffset: UInt64(cut))
            try handle.seek(toOffset: UInt64(cut))
            try handle.write(contentsOf: chunk.bytes)
            try patchContainerSize(handle, kind: kind, newFileSize: cut + chunk.bytes.count)
            try handle.synchronize()
        }
    }

    private static func isID3(_ id: String) -> Bool { id.lowercased() == "id3 " }

    private static func layout(_ url: URL) throws -> (Kind, [Chunk], Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard fileSize >= 12 else { throw ChunkError.notChunked }
        let head = try handle.readExactly(12)
        let magic = String(decoding: head[0..<4], as: UTF8.self)
        let form = String(decoding: head[8..<12], as: UTF8.self)
        let kind: Kind
        switch (magic, form) {
        case ("RIFF", "WAVE"): kind = .riff
        case ("FORM", "AIFF"), ("FORM", "AIFC"): kind = .aiff
        default: throw ChunkError.notChunked
        }
        var chunks: [Chunk] = []
        var offset = 12
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: UInt64(offset))
            let h = try handle.readExactly(8)
            var r = ByteReader(Array(h[4..<8]))
            let size = try Int(kind == .riff ? r.u32LE() : r.u32BE())
            let chunk = Chunk(id: String(decoding: h[0..<4], as: UTF8.self), offset: offset, size: size)
            chunks.append(chunk)
            offset = chunk.end
        }
        return (kind, chunks, fileSize)
    }

    private static func patchContainerSize(_ handle: FileHandle, kind: Kind, newFileSize: Int) throws {
        var w = ByteWriter()
        if kind == .riff { w.u32LE(UInt32(newFileSize - 8)) } else { w.u32BE(UInt32(newFileSize - 8)) }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: w.bytes)
    }

    private static func rewriteWithout(_ skipped: Chunk, appending newChunk: [UInt8], kind: Kind, url: URL, fileSize: Int) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).aether-tmp")
        guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let input = try FileHandle(forReadingFrom: url)
            let output = try FileHandle(forUpdating: temp)
            func copy(_ range: Range<Int>) throws {
                try input.seek(toOffset: UInt64(range.lowerBound))
                var remaining = range.count
                while remaining > 0, let chunk = try input.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    remaining -= chunk.count
                }
            }
            try copy(0..<skipped.offset)
            try copy(skipped.end..<fileSize)
            let end = Int(try output.seekToEnd())
            if end % 2 == 1 { try output.write(contentsOf: [0]) }
            try output.write(contentsOf: newChunk)
            try patchContainerSize(output, kind: kind, newFileSize: Int(try output.seekToEnd()))
            try output.synchronize()
            try output.close()
            try input.close()
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter ChunkID3IOTests`
Expected: 4 PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(tagkit): read and write ID3 chunks in WAV and AIFF files"
```

---

### Task 7: `FileNaming`

**Files:**
- Create: `Packages/AetherKit/Sources/TagKit/FileNaming.swift`
- Test: `Packages/AetherKit/Tests/TagKitTests/FileNamingTests.swift`

**Interfaces:**
- Produces: `public enum FileNaming { static func sanitize(_ s: String) -> String; static func titleWithVersion(_ title: String, version: String?) -> String; static func baseName(artist: String?, title: String?, fallback: String) -> String; static func uniqueURL(in folder: URL, baseName: String, extension ext: String, fileManager: FileManager = .default) -> URL }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/TagKitTests/FileNamingTests.swift`:

```swift
import Foundation
import Testing
@testable import TagKit

@Suite struct FileNamingTests {
    @Test func sanitizeRemovesPathSeparatorsAndTrims() {
        #expect(FileNaming.sanitize("AC/DC: Live  ") == "AC-DC- Live")
        #expect(FileNaming.sanitize("  Can't Decide (Extended) ") == "Can't Decide (Extended)")
        #expect(FileNaming.sanitize("trailing dots...") == "trailing dots")
        #expect(FileNaming.sanitize("tab\tand\nnewline") == "tab and newline")
    }

    @Test func sanitizeLimitsUTF8Length() {
        let long = String(repeating: "ñ", count: 300)
        #expect(FileNaming.sanitize(long).utf8.count <= 200)
    }

    @Test func titleWithVersion() {
        #expect(FileNaming.titleWithVersion("Dreams", version: "Extended Mix") == "Dreams (Extended Mix)")
        #expect(FileNaming.titleWithVersion("Dreams (Extended Mix)", version: "Extended Mix") == "Dreams (Extended Mix)")
        #expect(FileNaming.titleWithVersion("Dreams", version: nil) == "Dreams")
        #expect(FileNaming.titleWithVersion("Dreams", version: "  ") == "Dreams")
    }

    @Test func baseNameMatchesMasterConvention() {
        #expect(FileNaming.baseName(artist: "Prospa", title: "Dreams", fallback: "x") == "Prospa - Dreams")
        #expect(FileNaming.baseName(artist: nil, title: "Dreams", fallback: "x") == "Dreams")
        #expect(FileNaming.baseName(artist: nil, title: nil, fallback: "track-1") == "track-1")
    }

    @Test func uniqueURLAddsCounter() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = FileNaming.uniqueURL(in: folder, baseName: "Prospa - Dreams", extension: "flac")
        #expect(first.lastPathComponent == "Prospa - Dreams.flac")
        try Data().write(to: first)
        let second = FileNaming.uniqueURL(in: folder, baseName: "Prospa - Dreams", extension: "flac")
        #expect(second.lastPathComponent == "Prospa - Dreams (2).flac")
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter FileNamingTests`
Expected: FAIL de compilación — `cannot find 'FileNaming' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/TagKit/FileNaming.swift`:

```swift
public import Foundation

public enum FileNaming {
    private static let maxUTF8 = 200

    public static func sanitize(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        while out.hasSuffix(".") { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespaces)
        while out.utf8.count > maxUTF8 { out.removeLast() }
        return out
    }

    public static func titleWithVersion(_ title: String, version: String?) -> String {
        guard let version = version?.trimmingCharacters(in: .whitespaces), !version.isEmpty,
              title.range(of: version, options: .caseInsensitive) == nil
        else { return title }
        return "\(title) (\(version))"
    }

    public static func baseName(artist: String?, title: String?, fallback: String) -> String {
        let a = artist.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }
        let t = title.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }
        switch (a, t) {
        case let (a?, t?): return "\(a) - \(t)"
        case let (nil, t?): return t
        case let (a?, nil): return a
        case (nil, nil):
            let f = sanitize(fallback)
            return f.isEmpty ? "Sin título" : f
        }
    }

    public static func uniqueURL(in folder: URL, baseName: String, extension ext: String,
                                 fileManager: FileManager = .default) -> URL {
        var candidate = folder.appending(path: "\(baseName).\(ext)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(baseName) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}
```

- [ ] **Step 3: Verificar todo el módulo**

Run: `swift test --package-path Packages/AetherKit`
Expected: todas las suites (ByteKit + TagKit) PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(tagkit): add Master-compatible file naming helpers"
```
