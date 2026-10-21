# Aether v1 · Plan 05 — Cosmos (índice del Master, editor de tags, organización)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Indexar `~/Master` (≈640 archivos, 10 carpetas de género) con escaneo incremental y vigilancia de cambios, editar tags Vorbis/ID3 (uno o en lote), mover y renombrar con deshacer, detectar duplicados y lossy, re-verificar FLAC, y avisar en Harvester de lo que ya está en el Master.

**Architecture:** Módulo `Cosmos` (puro, probado con `swift test`): `AudioProbe`, `TagIO` (despacho por formato sobre TagKit), `ItemReader`, `LibraryScanner` (enumeración síncrona + lectura concurrente acotada + reutilización por `(tamaño, mtime)`), `IndexStore` (plist binario), `FolderWatcher` (FSEvents → `AsyncStream`), `MatchKey`/`DuplicateDetector`/`MasterLookup`, `Organizer` + `MoveJournal`. En la app: `CosmosStore` (`@MainActor @Observable`) con lista visible precalculada, `Table` nativa, `.inspector` con `TagDraft`, comandos de menú y `UndoManager` de la ventana.

**Tech Stack:** Swift 6, AudioToolbox (`AudioFile`), CoreServices (FSEvents), ImageIO, SwiftUI (`Table`, `.inspector`, `.quickLookPreview`, drag & drop), Swift Testing.

**Spec:** `docs/superpowers/plans/2026-10-20-aether-v1-00-overview.md` (§1 Cosmos, §4 presupuestos, §8 comandos, §9.3, §9.5, §9.6)

## Global Constraints

- macOS 27, Swift 6, cero dependencias de terceros.
- Escaneo en frío < 3 s, en caliente < 300 ms. Lectura concurrente máx. 4 archivos. Sin artwork en el índice ni en memoria por fila.
- Formatos indexados: `flac, mp3, wav, aiff, aif, m4a`. Editables: `flac` (Vorbis), `mp3` (ID3), `aiff/aif/wav` (chunk ID3, condicionado al spike S3). `m4a`: solo lectura.
- Ignorar archivos ocultos (incluye `.aether-part`). Nunca sobrescribir al mover/renombrar: sufijo ` (2)`.
- Toda acción destructiva o de movimiento es deshacible con ⌘Z (HIG 5.5) y queda registrada en el diario `cosmos-moves.jsonl`.
- Aviso permanente y discreto: mover archivos ya importados en rekordbox rompe sus rutas.
- Copy en español; lecturas técnicas en SF Mono.

Rutas relativas a `~/Documents/Projects/Aether`.

---

### Task 1: Target `Cosmos` — `AudioProbe`, `TagIO`, `LibraryItem`

**Files:**
- Modify: `Packages/AetherKit/Package.swift`
- Modify: `Packages/AetherKit/Tests/TestSupport/AudioFixture.swift` (añadir `makePCMFile`)
- Create: `Packages/AetherKit/Sources/Cosmos/AudioProbe.swift`
- Create: `Packages/AetherKit/Sources/Cosmos/TagIO.swift`
- Create: `Packages/AetherKit/Sources/Cosmos/LibraryItem.swift`
- Test: `Packages/AetherKit/Tests/CosmosTests/ProbeAndTagIOTests.swift`

**Interfaces:**
- Consumes: `FlacMetadataIO`, `FlacTags`, `ID3FileIO`, `ChunkID3IO`, `TrackTags`, `VorbisComment`, `IntegrityVerifier.verifiedFieldKey`.
- Produces:
  - `public struct AudioFormatInfo: Codable, Sendable, Equatable` con `enum Codec: String { flac, wav, aiff, mp3, aac, alac, other }`, `codec`, `sampleRate: Double`, `bitDepth: Int?`, `channels: Int`, `duration: Double`, `bitRate: Int?` (kbps), `isLossless`, `label` ("FLAC 24/44.1", "MP3 320")
  - `public enum AudioProbe { static func probe(_ url: URL) throws -> AudioFormatInfo; static func codec(formatID: UInt32, fileExtension: String) -> AudioFormatInfo.Codec }`
  - `public enum TagIO { static let supportedExtensions: Set<String>; static func isWritable(_ url: URL) -> Bool; static func read(_ url: URL) throws -> TrackTags; static func write(_ tags: TrackTags, to url: URL) throws; static func verifiedStamp(_ url: URL) -> String? }`
  - `public struct LibraryItem: Codable, Sendable, Identifiable, Equatable` con `relativePath`, `fileSize: Int64`, `modified: Date`, `format`, `tags` (sin artwork), `hasArtwork`, `verifiedStamp: String?`; computed `id`, `folder`, `fileName`, `displayArtist`, `displayTitle`, `bpmValue`, `keyValue`, `genreValue`, `isVerified`; `func url(in root: URL) -> URL`
  - `public enum ItemReader { static func read(url: URL, relativePath: String, fileSize: Int64, modified: Date) throws -> LibraryItem }`
  - (tests) `AudioFixture.makePCMFile(type: AudioFileTypeID, ext: String, seconds: Double = 1, bits: Int = 16) throws -> URL`

- [ ] **Step 1: Target y fixture PCM**

`Package.swift`:

```swift
.library(name: "AetherKit", targets: ["ByteKit", "TagKit", "FlacKit", "HiFiClient", "Harvester", "Cosmos"]),
```

```swift
.target(name: "Cosmos", dependencies: ["TagKit", "FlacKit"], swiftSettings: settings),
.testTarget(name: "CosmosTests", dependencies: ["Cosmos", "TestSupport"], swiftSettings: settings),
```

Añadir a `AudioFixture` (TestSupport):

```swift
    /// Writes big/little-endian PCM in a WAV or AIFF container with AudioToolbox.
    public static func makePCMFile(type: AudioFileTypeID, ext: String, seconds: Double = 1, bits: Int = 16) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pcm-\(UUID().uuidString).\(ext)")
        let rate = 44_100.0
        let bytes = bits / 8
        let bigEndian = type == kAudioFileAIFFType
        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (bigEndian ? kAudioFormatFlagIsBigEndian : 0),
            mBytesPerPacket: UInt32(bytes * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytes * 2),
            mChannelsPerFrame: 2, mBitsPerChannel: UInt32(bits), mReserved: 0)
        var ref: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(url as CFURL, type, &format, nil, AudioFileFlags.eraseFile.rawValue, &ref))
        guard let file = ref else { throw Failure(status: -1) }
        defer { ExtAudioFileDispose(file) }
        let frames = Int(seconds * rate)
        var pcm = [UInt8](repeating: 0, count: frames * bytes * 2)
        var client = format
        client.mFormatFlags &= ~kAudioFormatFlagIsBigEndian
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
        try pcm.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            try check(ExtAudioFileWrite(file, UInt32(frames), &list))
        }
        return url
    }
```

- [ ] **Step 2: Pruebas que fallan**

`Packages/AetherKit/Tests/CosmosTests/ProbeAndTagIOTests.swift`:

```swift
import AudioToolbox
import Foundation
import Testing
@testable import Cosmos
import TagKit
import TestSupport

@Suite struct ProbeAndTagIOTests {
    @Test func probesFlacFromStreamInfo() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2, sampleRate: 96_000, bits: 24)
        let info = try AudioProbe.probe(url)
        #expect(info.codec == .flac)
        #expect(info.sampleRate == 96_000)
        #expect(info.bitDepth == 24)
        #expect(abs(info.duration - 2) < 0.01)
        #expect(info.isLossless)
        #expect(info.label == "FLAC 24/96")
    }

    @Test(arguments: [(kAudioFileWAVEType, "wav", AudioFormatInfo.Codec.wav), (kAudioFileAIFFType, "aiff", .aiff)])
    func probesPCMContainers(type: AudioFileTypeID, ext: String, codec: AudioFormatInfo.Codec) throws {
        let url = try AudioFixture.makePCMFile(type: type, ext: ext, seconds: 1)
        let info = try AudioProbe.probe(url)
        #expect(info.codec == codec)
        #expect(info.bitDepth == 16)
        #expect(info.label == "\(codec.rawValue.uppercased()) 16/44.1")
    }

    @Test func codecMapping() {
        #expect(AudioProbe.codec(formatID: kAudioFormatMPEGLayer3, fileExtension: "mp3") == .mp3)
        #expect(AudioProbe.codec(formatID: kAudioFormatMPEG4AAC, fileExtension: "m4a") == .aac)
        #expect(AudioProbe.codec(formatID: kAudioFormatAppleLossless, fileExtension: "m4a") == .alac)
        #expect(AudioFormatInfo(codec: .mp3, sampleRate: 44_100, bitDepth: nil, channels: 2, duration: 1, bitRate: 320).label == "MP3 320")
    }

    @Test func tagIORoundTripsFlacAndReadsVerifiedStamp() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1)
        try FlacTags.write(TrackTags(title: "Feel", artist: "Franky Rizardo"), to: url,
                           extraFields: ["AETHER_VERIFIED": "md5:abcd;2026-10-20T00:00:00Z"])
        #expect(try TagIO.read(url).title == "Feel")
        #expect(TagIO.verifiedStamp(url) == "md5:abcd;2026-10-20T00:00:00Z")
        try TagIO.write(TrackTags(title: "Feel (Extended)", artist: "Franky Rizardo"), to: url)
        #expect(try TagIO.read(url).title == "Feel (Extended)")
        #expect(TagIO.isWritable(url))
        #expect(!TagIO.isWritable(URL(filePath: "/x.m4a")))
    }

    @Test func itemReaderBuildsSummaryWithoutArtwork() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1)
        try FlacTags.write(TrackTags(title: "Baby", artist: "Prospa", bpm: 130,
                                     artwork: .init(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), mimeType: "image/jpeg")), to: url)
        let item = try ItemReader.read(url: url, relativePath: "UK House/Prospa - Baby.flac", fileSize: 10, modified: .distantPast)
        #expect(item.folder == "UK House")
        #expect(item.fileName == "Prospa - Baby.flac")
        #expect(item.hasArtwork)
        #expect(item.tags.artwork == nil)
        #expect(item.bpmValue == 130)
        #expect(item.displayArtist == "Prospa")
    }

    @Test func displayFallsBackToFileName() {
        let item = LibraryItem(relativePath: "b2bsept.wav", fileSize: 1, modified: .distantPast,
                               format: AudioFormatInfo(codec: .wav, sampleRate: 44_100, bitDepth: 16, channels: 2, duration: 1, bitRate: nil),
                               tags: TrackTags(), hasArtwork: false, verifiedStamp: nil)
        #expect(item.folder == "")
        #expect(item.displayTitle == "b2bsept")
        let named = LibraryItem(relativePath: "UK House/Kettama - Comes and Goes.flac", fileSize: 1, modified: .distantPast,
                                format: item.format, tags: TrackTags(), hasArtwork: false, verifiedStamp: nil)
        #expect(named.displayArtist == "Kettama")
        #expect(named.displayTitle == "Comes and Goes")
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter ProbeAndTagIOTests`
Expected: FAIL de compilación — `cannot find 'AudioProbe' in scope`.

- [ ] **Step 3: `AudioProbe`**

`Packages/AetherKit/Sources/Cosmos/AudioProbe.swift`:

```swift
import AudioToolbox
public import Foundation
import TagKit

public struct AudioFormatInfo: Codable, Sendable, Equatable {
    public enum Codec: String, Codable, Sendable { case flac, wav, aiff, mp3, aac, alac, other }

    public var codec: Codec
    public var sampleRate: Double
    public var bitDepth: Int?
    public var channels: Int
    public var duration: Double
    public var bitRate: Int?

    public init(codec: Codec, sampleRate: Double, bitDepth: Int?, channels: Int, duration: Double, bitRate: Int?) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.duration = duration
        self.bitRate = bitRate
    }

    public var isLossless: Bool { [.flac, .wav, .aiff, .alac].contains(codec) }

    public var label: String {
        let name = codec.rawValue.uppercased()
        if isLossless, let bitDepth {
            let khz = sampleRate / 1000
            let rate = khz.rounded() == khz ? String(Int(khz)) : String(format: "%.1f", khz)
            return "\(name) \(bitDepth)/\(rate)"
        }
        return bitRate.map { "\(name) \($0)" } ?? name
    }
}

public enum AudioProbe {
    public static func probe(_ url: URL) throws -> AudioFormatInfo {
        if url.pathExtension.lowercased() == "flac" {
            let si = try FlacMetadataIO.read(url).streamInfo()
            return AudioFormatInfo(codec: .flac, sampleRate: Double(si.sampleRate), bitDepth: Int(si.bitsPerSample),
                                   channels: Int(si.channels), duration: si.duration, bitRate: nil)
        }
        var fileID: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard status == noErr, let file = fileID else { throw CocoaError(.fileReadCorruptFile) }
        defer { AudioFileClose(file) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd)
        var duration: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)
        var bitRate: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitRate)
        var sourceDepth: Int32 = 0
        size = UInt32(MemoryLayout<Int32>.size)
        AudioFileGetProperty(file, kAudioFilePropertySourceBitDepth, &size, &sourceDepth)

        let codec = codec(formatID: asbd.mFormatID, fileExtension: url.pathExtension.lowercased())
        let depth: Int? = asbd.mFormatID == kAudioFormatLinearPCM ? Int(asbd.mBitsPerChannel)
            : (sourceDepth > 0 ? Int(sourceDepth) : nil)
        return AudioFormatInfo(codec: codec, sampleRate: asbd.mSampleRate, bitDepth: depth,
                               channels: Int(asbd.mChannelsPerFrame), duration: duration,
                               bitRate: bitRate > 0 ? Int((Double(bitRate) / 1000).rounded()) : nil)
    }

    public static func codec(formatID: UInt32, fileExtension: String) -> AudioFormatInfo.Codec {
        switch formatID {
        case kAudioFormatLinearPCM: ["aif", "aiff", "aifc"].contains(fileExtension) ? .aiff : .wav
        case kAudioFormatMPEGLayer3: .mp3
        case kAudioFormatMPEG4AAC: .aac
        case kAudioFormatAppleLossless: .alac
        case kAudioFormatFLAC: .flac
        default: .other
        }
    }
}
```

- [ ] **Step 4: `TagIO` y `LibraryItem`**

`Packages/AetherKit/Sources/Cosmos/TagIO.swift`:

```swift
import AudioToolbox
public import Foundation
public import TagKit

public enum TagIO {
    public static let supportedExtensions: Set<String> = ["flac", "mp3", "wav", "aiff", "aif", "m4a"]
    /// Flip to false if spike S3 shows rekordbox ignores ID3 chunks in WAV.
    nonisolated(unsafe) public static var wavTagsEnabled = true

    public static func isWritable(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "flac", "mp3", "aiff", "aif": true
        case "wav": wavTagsEnabled
        default: false
        }
    }

    public static func read(_ url: URL) throws -> TrackTags {
        switch url.pathExtension.lowercased() {
        case "flac": try FlacTags.read(url).tags
        case "mp3": try ID3FileIO.read(url)
        case "wav", "aiff", "aif": try ChunkID3IO.read(url)
        default: readInfoDictionary(url)
        }
    }

    public static func write(_ tags: TrackTags, to url: URL) throws {
        guard isWritable(url) else { throw CocoaError(.fileWriteNoPermission) }
        switch url.pathExtension.lowercased() {
        case "flac": try FlacTags.write(tags, to: url)
        case "mp3": try ID3FileIO.write(tags, to: url)
        default: try ChunkID3IO.write(tags, to: url)
        }
    }

    public static func verifiedStamp(_ url: URL) -> String? {
        guard url.pathExtension.lowercased() == "flac",
              let header = try? FlacMetadataIO.read(url),
              let block = header.blocks(ofType: FlacBlockType.vorbisComment).first,
              let vorbis = try? VorbisComment(payload: block.payload)
        else { return nil }
        return vorbis.first("AETHER_VERIFIED")
    }

    /// Read-only fallback (m4a): AudioToolbox info dictionary.
    private static func readInfoDictionary(_ url: URL) -> TrackTags {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let file = fileID else { return TrackTags() }
        defer { AudioFileClose(file) }
        var dict: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
              let info = dict?.takeRetainedValue() as? [String: Any] else { return TrackTags() }
        return TrackTags(title: info[kAFInfoDictionary_Title] as? String, artist: info[kAFInfoDictionary_Artist] as? String,
                         album: info[kAFInfoDictionary_Album] as? String, genre: info[kAFInfoDictionary_Genre] as? String,
                         year: info[kAFInfoDictionary_Year] as? String,
                         bpm: (info[kAFInfoDictionary_Tempo] as? String).flatMap(Double.init))
    }
}
```

`Packages/AetherKit/Sources/Cosmos/LibraryItem.swift`:

```swift
public import Foundation
public import TagKit

public struct LibraryItem: Codable, Sendable, Identifiable, Equatable {
    public var relativePath: String
    public var fileSize: Int64
    public var modified: Date
    public var format: AudioFormatInfo
    public var tags: TrackTags
    public var hasArtwork: Bool
    public var verifiedStamp: String?

    public init(relativePath: String, fileSize: Int64, modified: Date, format: AudioFormatInfo, tags: TrackTags,
                hasArtwork: Bool, verifiedStamp: String?) {
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modified = modified
        self.format = format
        self.tags = tags
        self.hasArtwork = hasArtwork
        self.verifiedStamp = verifiedStamp
    }

    public var id: String { relativePath }
    public var fileName: String { (relativePath as NSString).lastPathComponent }
    /// First path component (genre folder), "" for files at the Master root.
    public var folder: String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count > 1 ? String(parts[0]) : ""
    }

    private var nameParts: (artist: String?, title: String) {
        let stem = (fileName as NSString).deletingPathExtension
        guard let range = stem.range(of: " - ") else { return (nil, stem) }
        return (String(stem[..<range.lowerBound]), String(stem[range.upperBound...]))
    }

    public var displayArtist: String { tags.artist ?? nameParts.artist ?? "" }
    public var displayTitle: String { tags.title ?? nameParts.title }
    public var bpmValue: Double { tags.bpm ?? 0 }
    public var keyValue: String { tags.key ?? "" }
    public var genreValue: String { tags.genre ?? "" }
    public var durationValue: Double { format.duration }
    public var isVerified: Bool { verifiedStamp != nil }

    public func url(in root: URL) -> URL { root.appending(path: relativePath) }
}

public enum ItemReader {
    public static func read(url: URL, relativePath: String, fileSize: Int64, modified: Date) throws -> LibraryItem {
        let format = try AudioProbe.probe(url)
        let full = (try? TagIO.read(url)) ?? TrackTags()
        return LibraryItem(relativePath: relativePath, fileSize: fileSize, modified: modified, format: format,
                           tags: full.withoutArtwork, hasArtwork: full.artwork != nil,
                           verifiedStamp: TagIO.verifiedStamp(url))
    }
}
```

- [ ] **Step 5: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter ProbeAndTagIOTests`
Expected: 7 PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(cosmos): probe audio formats and dispatch tag IO by file type"
```

---

### Task 2: `LibraryScanner` incremental e `IndexStore`

**Files:**
- Create: `Packages/AetherKit/Sources/Cosmos/LibraryScanner.swift`
- Create: `Packages/AetherKit/Sources/Cosmos/IndexStore.swift`
- Test: `Packages/AetherKit/Tests/CosmosTests/LibraryScannerTests.swift`

**Interfaces:**
- Produces:
  - `public struct ScanResult: Sendable { items: [LibraryItem]; folders: [String]; reused: Int; read: Int; failures: [String: String] }`
  - `public enum LibraryScanner { static func scan(root: URL, previous: [String: LibraryItem], maxConcurrent: Int = 4) async -> ScanResult }`
  - `public enum IndexStore { static func load(from: URL, root: URL) -> [String: LibraryItem]; static func save(_ items: [LibraryItem], root: URL, to: URL) throws }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/CosmosTests/LibraryScannerTests.swift`:

```swift
import Foundation
import Testing
@testable import Cosmos
import TagKit
import TestSupport

@Suite struct LibraryScannerTests {
    private func makeMaster() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "Master-\(UUID().uuidString)")
        let fm = FileManager.default
        for folder in ["UK House", "Tech House", "Por clasificar", "Vacía"] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        let (a, _) = try AudioFixture.makeFLAC(seconds: 0.5)
        try fm.copyItem(at: a, to: root.appending(path: "UK House/Prospa - Dreams.flac"))
        try fm.copyItem(at: a, to: root.appending(path: "Tech House/PAWSA - The Groovy Cat.flac"))
        try fm.copyItem(at: AudioFixture.makePCMFile(type: kAudioFileWAVEType, ext: "wav"), to: root.appending(path: "b2bsept.wav"))
        try Data().write(to: root.appending(path: "UK House/.Prospa - Dreams.flac.aether-part"))
        try Data("x".utf8).write(to: root.appending(path: "UK House/notes.txt"))
        return root
    }

    @Test func coldScanFindsAudioAndFolders() async throws {
        let root = try makeMaster()
        let result = await LibraryScanner.scan(root: root, previous: [:])
        #expect(Set(result.items.map(\.relativePath)) == ["UK House/Prospa - Dreams.flac", "Tech House/PAWSA - The Groovy Cat.flac", "b2bsept.wav"])
        #expect(result.folders == ["Por clasificar", "Tech House", "UK House", "Vacía"])
        #expect(result.read == 3)
        #expect(result.reused == 0)
    }

    @Test func warmScanReusesUnchangedAndRereadsModified() async throws {
        let root = try makeMaster()
        let first = await LibraryScanner.scan(root: root, previous: [:])
        let previous = Dictionary(uniqueKeysWithValues: first.items.map { ($0.id, $0) })
        let changed = root.appending(path: "UK House/Prospa - Dreams.flac")
        try FlacTags.write(TrackTags(title: "Dreams", artist: "Prospa", bpm: 126), to: changed)
        let second = await LibraryScanner.scan(root: root, previous: previous)
        #expect(second.reused == 2)
        #expect(second.read == 1)
        #expect(second.items.first { $0.id == "UK House/Prospa - Dreams.flac" }?.bpmValue == 126)
    }

    @Test func indexRoundTripsAndIgnoresOtherRoots() async throws {
        let root = try makeMaster()
        let result = await LibraryScanner.scan(root: root, previous: [:])
        let file = FileManager.default.temporaryDirectory.appending(path: "index-\(UUID().uuidString).plist")
        try IndexStore.save(result.items, root: root, to: file)
        #expect(IndexStore.load(from: file, root: root).count == 3)
        #expect(IndexStore.load(from: file, root: URL(filePath: "/elsewhere")).isEmpty)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter LibraryScannerTests`
Expected: FAIL de compilación — `cannot find 'LibraryScanner' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/Cosmos/LibraryScanner.swift`:

```swift
public import Foundation
import OSLog

public struct ScanResult: Sendable {
    public var items: [LibraryItem]
    public var folders: [String]
    public var reused: Int
    public var read: Int
    public var failures: [String: String]
}

public enum LibraryScanner {
    private static let signposter = OSSignposter(subsystem: "com.jazar.Aether", category: "cosmos")

    private struct Entry: Sendable {
        let url: URL
        let relativePath: String
        let size: Int64
        let modified: Date
    }

    /// Stat-only pass decides what to re-read; only new/changed files are parsed, with bounded concurrency.
    @concurrent
    public static func scan(root: URL, previous: [String: LibraryItem], maxConcurrent: Int = 4) async -> ScanResult {
        let interval = signposter.beginInterval("scan", id: signposter.makeSignpostID())
        defer { signposter.endInterval("scan", interval) }

        let (entries, folders) = list(root: root)
        var items: [LibraryItem] = []
        var pending: [Entry] = []
        for entry in entries {
            if let old = previous[entry.relativePath], old.fileSize == entry.size, old.modified == entry.modified {
                items.append(old)
            } else {
                pending.append(entry)
            }
        }
        let reused = items.count
        var failures: [String: String] = [:]

        await withTaskGroup(of: (String, Result<LibraryItem, any Error>).self) { group in
            var iterator = pending.makeIterator()
            func addNext() {
                guard let entry = iterator.next() else { return }
                group.addTask {
                    (entry.relativePath, Result {
                        try ItemReader.read(url: entry.url, relativePath: entry.relativePath, fileSize: entry.size, modified: entry.modified)
                    })
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            for await (path, result) in group {
                switch result {
                case .success(let item): items.append(item)
                case .failure(let error): failures[path] = String(describing: error)
                }
                addNext()
            }
        }
        items.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return ScanResult(items: items, folders: folders, reused: reused, read: pending.count - failures.count, failures: failures)
    }

    /// Synchronous on purpose: NSDirectoryEnumerator iteration is unavailable in async contexts.
    private static func list(root: URL) -> ([Entry], [String]) {
        let rootPath = root.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return ([], []) }
        var entries: [Entry] = []
        var folders: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            if values.isDirectory == true {
                if !relative.contains("/") { folders.append(relative) }
                continue
            }
            guard values.isRegularFile == true, TagIO.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            entries.append(Entry(url: url, relativePath: relative, size: Int64(values.fileSize ?? 0),
                                 modified: values.contentModificationDate ?? .distantPast))
        }
        folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return (entries, folders)
    }
}
```

`Packages/AetherKit/Sources/Cosmos/IndexStore.swift`:

```swift
public import Foundation

public enum IndexStore {
    private struct Snapshot: Codable {
        var schema = 1
        var root: String
        var items: [LibraryItem]
    }

    public static func load(from file: URL, root: URL) -> [String: LibraryItem] {
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data),
              snapshot.schema == 1, snapshot.root == root.standardizedFileURL.path
        else { return [:] }
        return Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    public static func save(_ items: [LibraryItem], root: URL, to file: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Snapshot(root: root.standardizedFileURL.path, items: items)).write(to: file, options: .atomic)
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter LibraryScannerTests`
Expected: 3 PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(cosmos): scan Master incrementally and persist a binary index"
```

---

### Task 3: `FolderWatcher` (FSEvents)

**Files:**
- Create: `Packages/AetherKit/Sources/Cosmos/FolderWatcher.swift`
- Test: `Packages/AetherKit/Tests/CosmosTests/FolderWatcherTests.swift`

**Interfaces:**
- Produces: `public final class FolderWatcher: @unchecked Sendable { init?(url: URL, latency: TimeInterval = 1.0); let changes: AsyncStream<Void>; func stop() }` — señales coalescidas (buffer 1): un evento = "algo cambió, re-escanea".

- [ ] **Step 1: Prueba que falla**

`Packages/AetherKit/Tests/CosmosTests/FolderWatcherTests.swift`:

```swift
import Foundation
import Testing
@testable import Cosmos

@Suite struct FolderWatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func signalsWhenAFileAppears() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "UK House"), withIntermediateDirectories: true)
        let watcher = try #require(FolderWatcher(url: dir, latency: 0.1))
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try Data([1]).write(to: dir.appending(path: "UK House/new.flac"))
        var iterator = watcher.changes.makeAsyncIterator()
        let signal: Void? = await iterator.next()
        #expect(signal != nil)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter FolderWatcherTests`
Expected: FAIL de compilación — `cannot find 'FolderWatcher' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/Cosmos/FolderWatcher.swift`:

```swift
import CoreServices
public import Foundation

/// Recursive directory watcher. Directory-level FSEvents are enough: any event triggers an incremental
/// rescan, which is cheap thanks to the (size, mtime) reuse in LibraryScanner.
public final class FolderWatcher: @unchecked Sendable {
    private final class Box {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    public let changes: AsyncStream<Void>
    private var stream: FSEventStreamRef?
    private let continuation: AsyncStream<Void>.Continuation

    public init?(url: URL, latency: TimeInterval = 1.0) {
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let box = Unmanaged.passRetained(Box(continuation))
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().continuation.yield()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else {
            box.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.jazar.Aether.fsevents", qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        continuation.finish()
    }

    deinit { stop() }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter FolderWatcherTests`
Expected: 1 PASS (< 2 s).

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(cosmos): watch the Master folder tree with FSEvents"
```

---

### Task 4: Duplicados, "ya en Master" y filtros de revisión

**Files:**
- Create: `Packages/AetherKit/Sources/Cosmos/Matching.swift`
- Test: `Packages/AetherKit/Tests/CosmosTests/MatchingTests.swift`

**Interfaces:**
- Produces:
  - `public enum MatchKey { static func normalize(_ s: String) -> String; static func primaryArtist(_ s: String) -> String; static func strict(artist: String, title: String) -> String; static func loose(artist: String, title: String) -> String }`
  - `public struct DuplicateGroup: Identifiable, Sendable, Equatable { id: String; itemIDs: [String] }`
  - `public enum DuplicateDetector { static func groups(in items: [LibraryItem]) -> [DuplicateGroup] }`
  - `public struct MasterLookup: Sendable { enum Match: Equatable { exact(LibraryItem), similar(LibraryItem) }; init(items: [LibraryItem]); func match(isrc: String?, artist: String, title: String) -> Match?; static let empty }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/CosmosTests/MatchingTests.swift`:

```swift
import Foundation
import Testing
@testable import Cosmos
import TagKit

@Suite struct MatchingTests {
    private func item(_ path: String, artist: String? = nil, title: String? = nil, isrc: String? = nil, codec: AudioFormatInfo.Codec = .flac) -> LibraryItem {
        LibraryItem(relativePath: path, fileSize: 1, modified: .distantPast,
                    format: AudioFormatInfo(codec: codec, sampleRate: 44_100, bitDepth: 16, channels: 2, duration: 1, bitRate: nil),
                    tags: TrackTags(title: title, artist: artist, isrc: isrc), hasArtwork: false, verifiedStamp: nil)
    }

    @Test func normalizationFoldsCaseDiacriticsPunctuation() {
        #expect(MatchKey.normalize("Joe Rolét — No Hesitating!") == "joe rolet no hesitating")
        #expect(MatchKey.normalize("Rhythm & Blues") == "rhythm and blues")
        #expect(MatchKey.primaryArtist("Prospa, Rohan Pinnock-Hamilton") == "prospa")
        #expect(MatchKey.primaryArtist("Kettama feat. Someone") == "kettama")
        #expect(MatchKey.primaryArtist("Max Dean & Luke Dean") == "max dean")
    }

    @Test func strictAndLooseKeys() {
        #expect(MatchKey.strict(artist: "Prospa", title: "Dreams (Extended Mix)") == "prospa|dreams extended mix")
        #expect(MatchKey.strict(artist: "Prospa", title: "Dreams (Original Mix)") == "prospa|dreams")
        #expect(MatchKey.loose(artist: "Prospa", title: "Dreams (Extended Mix)") == "prospa|dreams")
    }

    @Test func duplicateGroupsUseTagsOrFileNames() {
        let items = [
            item("UK House/Prospa - Dreams.flac", artist: "Prospa", title: "Dreams"),
            item("Por clasificar/Prospa - Dreams.mp3", codec: .mp3),
            item("UK House/Prospa - Baby.flac", artist: "Prospa", title: "Baby"),
        ]
        let groups = DuplicateDetector.groups(in: items)
        #expect(groups == [DuplicateGroup(id: "prospa|dreams", itemIDs: ["Por clasificar/Prospa - Dreams.mp3", "UK House/Prospa - Dreams.flac"])])
    }

    @Test func lookupPrefersISRCThenStrictThenLoose() {
        let lookup = MasterLookup(items: [
            item("UK House/a.flac", artist: "Prospa", title: "Dreams", isrc: "QM6MZ2647627"),
            item("UK House/b.flac", artist: "Kettama", title: "Pretty Green Eyes (Sunset Ibiza Mix)"),
        ])
        #expect(lookup.match(isrc: "QM6MZ2647627", artist: "X", title: "Y") == .exact(lookup.items[0]))
        #expect(lookup.match(isrc: nil, artist: "Prospa, Rohan Pinnock-Hamilton", title: "Dreams") == .exact(lookup.items[0]))
        #expect(lookup.match(isrc: nil, artist: "Kettama", title: "Pretty Green Eyes (Extended Mix)") == .similar(lookup.items[1]))
        #expect(lookup.match(isrc: nil, artist: "Kettama", title: "Comes and Goes") == nil)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter MatchingTests`
Expected: FAIL de compilación — `cannot find 'MatchKey' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/Cosmos/Matching.swift`:

```swift
import Foundation

public enum MatchKey {
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    public static func primaryArtist(_ s: String) -> String {
        let cut = s.replacing(/(?i)\s*(,|&|\bfeat\.?|\bft\.?|\bx\b|\bvs\.?).*$/, with: "")
        return normalize(cut)
    }

    /// "(Original Mix)" is noise; any other version text is meaningful.
    public static func strict(artist: String, title: String) -> String {
        let t = title.replacing(/(?i)\s*[\(\[]original mix[\)\]]/, with: "")
        return "\(primaryArtist(artist))|\(normalize(t))"
    }

    /// Ignores every parenthetical/bracketed version: "Dreams (Extended Mix)" ~ "Dreams".
    public static func loose(artist: String, title: String) -> String {
        let t = title.replacing(/\s*[\(\[][^\)\]]*[\)\]]/, with: "")
        return "\(primaryArtist(artist))|\(normalize(t))"
    }
}

public struct DuplicateGroup: Identifiable, Sendable, Equatable {
    public var id: String
    public var itemIDs: [String]

    public init(id: String, itemIDs: [String]) {
        self.id = id
        self.itemIDs = itemIDs
    }
}

public enum DuplicateDetector {
    public static func groups(in items: [LibraryItem]) -> [DuplicateGroup] {
        let keyed = items.compactMap { item -> (String, String)? in
            guard !item.displayArtist.isEmpty else { return nil }
            return (MatchKey.strict(artist: item.displayArtist, title: item.displayTitle), item.id)
        }
        return Dictionary(grouping: keyed, by: \.0)
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(id: $0.key, itemIDs: $0.value.map(\.1).sorted()) }
            .sorted { $0.id < $1.id }
    }
}

public struct MasterLookup: Sendable {
    public enum Match: Equatable, Sendable {
        case exact(LibraryItem)
        case similar(LibraryItem)
    }

    public static let empty = MasterLookup(items: [])

    public let items: [LibraryItem]
    private let byISRC: [String: Int]
    private let byStrict: [String: Int]
    private let byLoose: [String: Int]

    public init(items: [LibraryItem]) {
        self.items = items
        var isrc: [String: Int] = [:], strict: [String: Int] = [:], loose: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            if let code = item.tags.isrc?.uppercased() { isrc[code] = isrc[code] ?? index }
            guard !item.displayArtist.isEmpty else { continue }
            strict[MatchKey.strict(artist: item.displayArtist, title: item.displayTitle)] = index
            loose[MatchKey.loose(artist: item.displayArtist, title: item.displayTitle)] = index
        }
        byISRC = isrc
        byStrict = strict
        byLoose = loose
    }

    public func match(isrc: String?, artist: String, title: String) -> Match? {
        if let code = isrc?.uppercased(), let i = byISRC[code] { return .exact(items[i]) }
        if let i = byStrict[MatchKey.strict(artist: artist, title: title)] { return .exact(items[i]) }
        if let i = byLoose[MatchKey.loose(artist: artist, title: title)] { return .similar(items[i]) }
        return nil
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter MatchingTests`
Expected: 4 PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(cosmos): detect duplicates and look up tracks already in Master"
```

---

### Task 5: `Organizer` (mover, renombrar, deshacer) y `MoveJournal`

**Files:**
- Create: `Packages/AetherKit/Sources/Cosmos/Organizer.swift`
- Test: `Packages/AetherKit/Tests/CosmosTests/OrganizerTests.swift`

**Interfaces:**
- Consumes: `FileNaming`.
- Produces:
  - `public struct FileMove: Codable, Sendable, Equatable { from: URL; to: URL; var inverse: FileMove }`
  - `public enum Organizer { static func move(_ urls: [URL], to folder: URL) throws -> [FileMove]; static func apply(_ moves: [FileMove]) throws -> [FileMove]; static func plannedRenames(_ files: [(url: URL, tags: TrackTags)]) -> [FileMove] }`
  - `public actor MoveJournal { init(fileURL: URL); func record(_ moves: [FileMove], reason: String) }` (JSON Lines)

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/CosmosTests/OrganizerTests.swift`:

```swift
import Foundation
import Testing
@testable import Cosmos
import TagKit

@Suite struct OrganizerTests {
    private func tree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "org-\(UUID().uuidString)")
        for folder in ["Por clasificar", "UK House"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data([1]).write(to: root.appending(path: "Por clasificar/Prospa - Dreams.flac"))
        try Data([2]).write(to: root.appending(path: "UK House/Prospa - Dreams.flac"))
        return root
    }

    @Test func moveAvoidsCollisionsAndUndoRestores() throws {
        let root = try tree()
        let source = root.appending(path: "Por clasificar/Prospa - Dreams.flac")
        let moves = try Organizer.move([source], to: root.appending(path: "UK House"))
        #expect(moves.first?.to.lastPathComponent == "Prospa - Dreams (2).flac")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        _ = try Organizer.apply(moves.map(\.inverse).reversed())
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: source) == Data([1]))
    }

    @Test func plannedRenamesSkipUnchangedAndUntagged() throws {
        let root = try tree()
        let tagged = root.appending(path: "UK House/Prospa - Dreams.flac")
        let other = root.appending(path: "Por clasificar/Prospa - Dreams.flac")
        let plan = Organizer.plannedRenames([
            (tagged, TrackTags(title: "Dreams", artist: "Prospa")),
            (other, TrackTags(title: "Dreams (Extended Mix)", artist: "Prospa")),
            (other, TrackTags()),
        ])
        #expect(plan == [FileMove(from: other, to: root.appending(path: "Por clasificar/Prospa - Dreams (Extended Mix).flac"))])
    }

    @Test func journalAppendsJSONLines() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "journal-\(UUID().uuidString).jsonl")
        let journal = MoveJournal(fileURL: file)
        await journal.record([FileMove(from: URL(filePath: "/a"), to: URL(filePath: "/b"))], reason: "move")
        await journal.record([FileMove(from: URL(filePath: "/b"), to: URL(filePath: "/a"))], reason: "undo")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].contains("\"undo\""))
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter OrganizerTests`
Expected: FAIL de compilación — `cannot find 'Organizer' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/Cosmos/Organizer.swift`:

```swift
public import Foundation
public import TagKit

public struct FileMove: Codable, Sendable, Equatable {
    public var from: URL
    public var to: URL

    public init(from: URL, to: URL) {
        self.from = from
        self.to = to
    }

    public var inverse: FileMove { FileMove(from: to, to: from) }
}

public enum Organizer {
    /// Same-volume renames: instantaneous, no copy. Never overwrites.
    public static func move(_ urls: [URL], to folder: URL) throws -> [FileMove] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var done: [FileMove] = []
        do {
            for url in urls where url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                let base = url.deletingPathExtension().lastPathComponent
                let target = FileNaming.uniqueURL(in: folder, baseName: base, extension: url.pathExtension)
                try FileManager.default.moveItem(at: url, to: target)
                done.append(FileMove(from: url, to: target))
            }
        } catch {
            _ = try? apply(done.map(\.inverse).reversed())   // all-or-nothing
            throw error
        }
        return done
    }

    @discardableResult
    public static func apply(_ moves: some Sequence<FileMove>) throws -> [FileMove] {
        var applied: [FileMove] = []
        for move in moves {
            try FileManager.default.moveItem(at: move.from, to: move.to)
            applied.append(move)
        }
        return applied
    }

    /// Preview for "Rename from tags": `{artist} - {title}.{ext}`; skips untagged and already-correct files.
    public static func plannedRenames(_ files: [(url: URL, tags: TrackTags)]) -> [FileMove] {
        var claimed = Set<String>()
        var plan: [FileMove] = []
        for (url, tags) in files {
            guard let artist = tags.artist, let title = tags.title else { continue }
            let base = FileNaming.baseName(artist: artist, title: title, fallback: "")
            let folder = url.deletingLastPathComponent()
            if url.deletingPathExtension().lastPathComponent == base { continue }
            var candidate = folder.appending(path: "\(base).\(url.pathExtension)")
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) || claimed.contains(candidate.path) {
                candidate = folder.appending(path: "\(base) (\(counter)).\(url.pathExtension)")
                counter += 1
            }
            claimed.insert(candidate.path)
            plan.append(FileMove(from: url, to: candidate))
        }
        return plan
    }
}

/// Append-only audit log of every move/rename: the source of truth for relocating tracks in rekordbox.
public actor MoveJournal {
    private struct Line: Encodable { let date: Date; let reason: String; let from: String; let to: String }
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func record(_ moves: [FileMove], reason: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let now = Date()
        let text = moves.compactMap { move -> String? in
            let line = Line(date: now, reason: reason, from: move.from.path, to: move.to.path)
            return (try? encoder.encode(line)).flatMap { String(data: $0, encoding: .utf8) }
        }.map { $0 + "\n" }.joined()
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL)
        }
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter OrganizerTests`
Expected: 3 PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(cosmos): move and rename files collision-safely with an audit journal"
```

---

### Task 6: `CosmosStore`, sidebar de carpetas y tabla del navegador

**Files:**
- Create: `Aether/Cosmos/CosmosStore.swift`
- Create: `Aether/Cosmos/CosmosBrowserView.swift`
- Modify: `Aether/Harvester/AppPaths.swift` (índice y diario)
- Modify: `Aether/App/AppModel.swift`
- Modify: `Aether/App/AetherApp.swift` (inyectar `model.cosmos`)
- Modify: `Aether/Shell/SidebarView.swift`
- Modify: `Aether/Shell/RootView.swift`
- Test: `AetherTests/CosmosStoreTests.swift`

**Interfaces:**
- Consumes: `LibraryScanner`, `IndexStore`, `FolderWatcher`, `DuplicateDetector`, `MasterLookup`, `Organizer`, `MoveJournal`, `Preferences`, `Route`.
- Produces:
  - `AppPaths.index`, `AppPaths.moveJournal`
  - `struct FolderSummary: Identifiable, Equatable { name: String; count: Int; id: String }`
  - `@MainActor @Observable final class CosmosStore` con `items`, `folders: [FolderSummary]`, `visible: [LibraryItem]`, `scope: Route`, `searchText`, `sortOrder: [KeyPathComparator<LibraryItem>]`, `selection: Set<String>`, `duplicateGroups`, `lookup: MasterLookup`, `isScanning`, `inboxCount`, `untaggedCount`, `duplicateCount`, `lossyCount`, `root: URL`, `onLookupChanged: ((MasterLookup) -> Void)?`, `onRelocated: (([FileMove]) -> Void)?`; métodos `start() async`, `rescan() async`, `url(for: LibraryItem) -> URL`, `selectedItems: [LibraryItem]`, `static func filter(_:scope:inbox:search:duplicates:) -> [LibraryItem]`

- [ ] **Step 1: Prueba del filtrado (función pura) que falla**

`AetherTests/CosmosStoreTests.swift`:

```swift
import Cosmos
import Foundation
import TagKit
import Testing
@testable import Aether

@MainActor
@Suite struct CosmosStoreTests {
    private func item(_ path: String, artist: String? = nil, title: String? = nil, codec: AudioFormatInfo.Codec = .flac) -> LibraryItem {
        LibraryItem(relativePath: path, fileSize: 1, modified: .distantPast,
                    format: AudioFormatInfo(codec: codec, sampleRate: 44_100, bitDepth: 16, channels: 2, duration: 1, bitRate: 320),
                    tags: TrackTags(title: title, artist: artist), hasArtwork: false, verifiedStamp: nil)
    }

    @Test func filtersByScopeAndSearch() {
        let items = [
            item("UK House/Prospa - Dreams.flac", artist: "Prospa", title: "Dreams"),
            item("Por clasificar/x.mp3", codec: .mp3),
            item("Tech House/PAWSA - The Groovy Cat.flac", artist: "PAWSA", title: "The Groovy Cat"),
        ]
        #expect(CosmosStore.filter(items, scope: .cosmosAll, inbox: "Por clasificar", search: "", duplicates: []).count == 3)
        #expect(CosmosStore.filter(items, scope: .cosmosFolder("UK House"), inbox: "Por clasificar", search: "", duplicates: []).map(\.id) == ["UK House/Prospa - Dreams.flac"])
        #expect(CosmosStore.filter(items, scope: .cosmosInbox, inbox: "Por clasificar", search: "", duplicates: []).map(\.id) == ["Por clasificar/x.mp3"])
        #expect(CosmosStore.filter(items, scope: .cosmosReview(.untagged), inbox: "Por clasificar", search: "", duplicates: []).map(\.id) == ["Por clasificar/x.mp3"])
        #expect(CosmosStore.filter(items, scope: .cosmosReview(.lossy), inbox: "Por clasificar", search: "", duplicates: []).map(\.id) == ["Por clasificar/x.mp3"])
        #expect(CosmosStore.filter(items, scope: .cosmosReview(.duplicates), inbox: "Por clasificar", search: "", duplicates: ["UK House/Prospa - Dreams.flac"]).count == 1)
        #expect(CosmosStore.filter(items, scope: .cosmosAll, inbox: "Por clasificar", search: "groovy", duplicates: []).map(\.id) == ["Tech House/PAWSA - The Groovy Cat.flac"])
    }
}
```

Run: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' test -only-testing:AetherTests/CosmosStoreTests -quiet`
Expected: FAIL — `cannot find 'CosmosStore' in scope`.

- [ ] **Step 2: Rutas de soporte**

Añadir a `AppPaths`:

```swift
    static var index: URL { support.appending(path: "cosmos-index.plist") }
    static var moveJournal: URL { support.appending(path: "cosmos-moves.jsonl") }
```

- [ ] **Step 3: `CosmosStore`**

`Aether/Cosmos/CosmosStore.swift`:

```swift
import Cosmos
import Foundation
import Observation

struct FolderSummary: Identifiable, Equatable {
    let name: String
    let count: Int
    var id: String { name }
}

@MainActor
@Observable
final class CosmosStore {
    private(set) var items: [LibraryItem] = [] { didSet { recompute() } }
    private(set) var folders: [FolderSummary] = []
    private(set) var visible: [LibraryItem] = []
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var lookup: MasterLookup = .empty
    private(set) var isScanning = false
    var scope: Route = .cosmosAll { didSet { if scope != oldValue { refreshVisible() } } }
    var searchText = "" { didSet { refreshVisible() } }
    var sortOrder = [KeyPathComparator(\LibraryItem.displayArtist)] { didSet { refreshVisible() } }
    var selection: Set<String> = []

    @ObservationIgnored var onLookupChanged: ((MasterLookup) -> Void)?
    @ObservationIgnored var onRelocated: (([FileMove]) -> Void)?
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored let journal = MoveJournal(fileURL: AppPaths.moveJournal)
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var duplicateIDs: Set<String> = []
    @ObservationIgnored private var scanQueued = false

    init(preferences: Preferences) { self.preferences = preferences }

    var root: URL { preferences.masterFolder }
    var inboxCount: Int { items.count { $0.folder == preferences.inboxFolderName } }
    var untaggedCount: Int { items.count { $0.tags.isEffectivelyEmpty } }
    var duplicateCount: Int { duplicateIDs.count }
    var lossyCount: Int { items.count { !$0.format.isLossless } }
    var selectedItems: [LibraryItem] { visible.filter { selection.contains($0.id) } }

    func url(for item: LibraryItem) -> URL { item.url(in: root) }

    // MARK: Lifecycle

    func start() async {
        let cached = IndexStore.load(from: AppPaths.index, root: root)
        if !cached.isEmpty { items = cached.values.sorted { $0.relativePath < $1.relativePath } }
        await rescan()
        watcher = FolderWatcher(url: root, latency: 1.0)
        guard let changes = watcher?.changes else { return }
        for await _ in changes { await rescan() }
    }

    func rescan() async {
        guard !isScanning else { scanQueued = true; return }
        isScanning = true
        repeat {
            scanQueued = false
            let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            let root = root
            let result = await LibraryScanner.scan(root: root, previous: previous)
            items = result.items
            folders = result.folders.map { name in FolderSummary(name: name, count: result.items.count { $0.folder == name }) }
            let snapshot = result.items
            Task.detached(priority: .utility) { try? IndexStore.save(snapshot, root: root, to: AppPaths.index) }
        } while scanQueued
        isScanning = false
    }

    // MARK: Derived state

    private func recompute() {
        duplicateGroups = DuplicateDetector.groups(in: items)
        duplicateIDs = Set(duplicateGroups.flatMap(\.itemIDs))
        lookup = MasterLookup(items: items)
        onLookupChanged?(lookup)
        refreshVisible()
    }

    private func refreshVisible() {
        visible = Self.filter(items, scope: scope, inbox: preferences.inboxFolderName, search: searchText, duplicates: duplicateIDs)
            .sorted(using: sortOrder)
        selection.formIntersection(visible.map(\.id))
    }

    static func filter(_ items: [LibraryItem], scope: Route, inbox: String, search: String, duplicates: Set<String>) -> [LibraryItem] {
        let scoped: [LibraryItem] = switch scope {
        case .cosmosFolder(let name): items.filter { $0.folder == name }
        case .cosmosInbox: items.filter { $0.folder == inbox }
        case .cosmosReview(.untagged): items.filter { $0.tags.isEffectivelyEmpty }
        case .cosmosReview(.duplicates): items.filter { duplicates.contains($0.id) }
        case .cosmosReview(.lossy): items.filter { !$0.format.isLossless }
        default: items
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.displayArtist.localizedStandardContains(query) || $0.displayTitle.localizedStandardContains(query)
                || ($0.tags.label ?? "").localizedStandardContains(query) || $0.fileName.localizedStandardContains(query)
        }
    }
}
```

- [ ] **Step 4: Tabla del navegador**

`Aether/Cosmos/CosmosBrowserView.swift`:

```swift
import Cosmos
import SwiftUI
import TagKit

struct CosmosBrowserView: View {
    @Environment(CosmosStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Table(of: LibraryItem.self, selection: $store.selection, sortOrder: $store.sortOrder) {
            TableColumn("Artista", value: \.displayArtist) { Text($0.displayArtist).lineLimit(1) }
                .width(min: 120, ideal: 180)
            TableColumn("Título", value: \.displayTitle) { Text($0.displayTitle).lineLimit(1) }
                .width(min: 160, ideal: 280)
            TableColumn("Género", value: \.genreValue) { Text($0.genreValue).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 70, ideal: 100)
            TableColumn("BPM", value: \.bpmValue) { Readout($0.bpmValue > 0 ? TrackTags.formatBPM($0.bpmValue) : "—") }
                .width(48)
            TableColumn("Key", value: \.keyValue) { Readout($0.keyValue.isEmpty ? "—" : $0.keyValue) }
                .width(44)
            TableColumn("Formato", value: \.format.sampleRate) { item in
                Readout(item.format.label, tone: item.format.isLossless ? .secondary : .fault)
            }
            .width(min: 80, ideal: 96)
            TableColumn("Duración", value: \.durationValue) {
                Readout(Duration.seconds($0.format.duration).formatted(.time(pattern: .minuteSecond)))
            }
            .width(60)
            TableColumn("Tamaño", value: \.fileSize) { Readout($0.fileSize.formatted(.byteCount(style: .file))) }
                .width(70)
            TableColumn("✓") { item in
                if item.isVerified {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Tokens.signal)
                        .help(item.verifiedStamp ?? "").accessibilityLabel("Verificado")
                }
            }
            .width(24)
        } rows: {
            ForEach(store.visible) { item in
                TableRow(item).draggable(store.url(for: item))
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Buscar en Master")
        .navigationTitle(title)
        .navigationSubtitle("\(store.visible.count) pistas")
        .overlay {
            if store.visible.isEmpty && !store.isScanning {
                ContentUnavailableView("Nada aquí", systemImage: "folder", description: Text("No hay pistas en esta vista."))
            }
        }
    }

    private var title: String {
        switch store.scope {
        case .cosmosFolder(let name): name
        case .cosmosInbox: "Por clasificar"
        case .cosmosReview(let filter): filter.title
        default: "Master"
        }
    }
}
```

- [ ] **Step 5: Cablear en `AppModel`, sidebar y router**

`Aether/App/AppModel.swift` completo:

```swift
import Observation

@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    let harvester: HarvesterStore
    let cosmos: CosmosStore
    var route: Route = .harvesterSearch
    var isInspectorPresented = false

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        harvester = HarvesterStore(preferences: preferences)
        cosmos = CosmosStore(preferences: preferences)
        // Owned by the model, not a view: downloads and the folder watcher keep running with the window closed.
        Task { [harvester] in await harvester.start() }
        Task { [cosmos] in await cosmos.start() }
    }
}
```

`AetherApp`: `.environment(model.cosmos)` junto a los otros `environment`.

`RootView`: mantener `model.cosmos.scope` sincronizado con la ruta y enrutar:

```swift
        .onChange(of: model.route, initial: true) { _, route in
            switch route {
            case .cosmosAll, .cosmosFolder, .cosmosInbox, .cosmosReview: model.cosmos.scope = route
            default: break
            }
        }
```

y en `DetailRouter`:

```swift
        case .cosmosAll, .cosmosFolder, .cosmosInbox, .cosmosReview:
            CosmosBrowserView()
```

`SidebarView` — sección Cosmos completa (reemplaza la de una sola fila):

```swift
            Section("Cosmos") {
                Label("Master", systemImage: "folder").tag(Route.cosmosAll)
                Label("Por clasificar", systemImage: "tray").tag(Route.cosmosInbox)
                    .badge(cosmos.inboxCount)
                ForEach(cosmos.folders.filter { $0.name != preferences.inboxFolderName }) { folder in
                    Label(folder.name, systemImage: "folder")
                        .tag(Route.cosmosFolder(folder.name))
                }
            }
            Section("Revisar") {
                ForEach(ReviewFilter.allCases, id: \.self) { filter in
                    Label(filter.title, systemImage: filter.symbol)
                        .tag(Route.cosmosReview(filter))
                        .badge(count(for: filter))
                }
            }
```

con `@Environment(CosmosStore.self) private var cosmos`, `@Environment(Preferences.self) private var preferences` y:

```swift
    private func count(for filter: ReviewFilter) -> Int {
        switch filter {
        case .untagged: cosmos.untaggedCount
        case .duplicates: cosmos.duplicateCount
        case .lossy: cosmos.lossyCount
        }
    }
```

- [ ] **Step 6: Verificar**

Run: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' test -only-testing:AetherTests -quiet`
Expected: PASS. Abrir la app: la sidebar muestra las carpetas reales de `~/Master` (Afro House, Deep House, Disco, INDIE, LATIN HOUSE, MELODIC, Tech House, UK House, Urbano) y "Por clasificar" con badge; ⌘3 muestra ~640 pistas ordenables; crear un archivo en Finder dentro de `~/Master/Disco` lo hace aparecer en ≈1 s.

- [ ] **Step 7: Commit**

```bash
git add Aether AetherTests
git commit -m "feat(cosmos-ui): index Master with live folder sidebar and sortable track table"
```

---

### Task 7: Inspector de tags (individual y en lote) con deshacer

**Files:**
- Create: `Aether/Cosmos/TagDraft.swift`
- Create: `Aether/Cosmos/TagInspectorView.swift`
- Create: `Aether/Cosmos/ArtworkWell.swift`
- Create: `Aether/Cosmos/ArtworkProcessor.swift`
- Modify: `Aether/Cosmos/CosmosStore.swift` (`loadFullTags`, `saveTags`)
- Modify: `Aether/Shell/RootView.swift` (`.inspector`)
- Test: `AetherTests/TagDraftTests.swift`

**Interfaces:**
- Consumes: `TagIO`, `TrackTags`, `CosmosStore`.
- Produces:
  - `enum TagField: String, CaseIterable, Identifiable { title, artist, remixer, album, albumArtist, label, year, isrc, genre, bpm, key, comment; var label: String; func get(_ t: TrackTags) -> String; func set(_ t: inout TrackTags, _ v: String) }`
  - `@MainActor @Observable final class TagDraft` con `text: [TagField: String]`, `mixed: Set<TagField>`, `dirty: Set<TagField>`, `artwork: ArtworkChange`, `init(tags: [TrackTags])`, `func binding(_:) -> Binding<String>`, `func applied(to: TrackTags) -> TrackTags`, `var hasChanges: Bool`
  - `enum ArtworkChange: Equatable { unchanged, set(TrackTags.Artwork), removed }`
  - `enum ArtworkProcessor { static func prepare(_ data: Data) -> TrackTags.Artwork?; static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? }`
  - `CosmosStore.loadFullTags(_ items: [LibraryItem]) async -> [TrackTags]`, `CosmosStore.saveTags(_ draft: TagDraft, for items: [LibraryItem], undoManager: UndoManager?) async`

- [ ] **Step 1: Prueba que falla**

`AetherTests/TagDraftTests.swift`:

```swift
import Foundation
import TagKit
import Testing
@testable import Aether

@MainActor
@Suite struct TagDraftTests {
    @Test func mixedValuesAreDetectedAndOnlyDirtyFieldsApply() {
        let a = TrackTags(title: "Dreams", artist: "Prospa", genre: "UK House", bpm: 128)
        let b = TrackTags(title: "Baby", artist: "Prospa", genre: "House", bpm: 128)
        let draft = TagDraft(tags: [a, b])
        #expect(draft.mixed == [.title, .genre])
        #expect(draft.text[.artist] == "Prospa")
        #expect(draft.text[.bpm] == "128")
        #expect(!draft.hasChanges)

        draft.binding(.genre).wrappedValue = "UK House"
        #expect(draft.dirty == [.genre])
        let newB = draft.applied(to: b)
        #expect(newB.genre == "UK House")
        #expect(newB.title == "Baby")
    }

    @Test func numericFieldsParseAndClear() {
        let draft = TagDraft(tags: [TrackTags(bpm: 124.5)])
        #expect(draft.text[.bpm] == "124.50")
        draft.binding(.bpm).wrappedValue = "126"
        #expect(draft.applied(to: TrackTags()).bpm == 126)
        draft.binding(.bpm).wrappedValue = ""
        #expect(draft.applied(to: TrackTags(bpm: 1)).bpm == nil)
    }

    @Test func artworkChangeApplies() {
        let draft = TagDraft(tags: [TrackTags(artwork: .init(data: Data([1]), mimeType: "image/jpeg"))])
        draft.artwork = .removed
        #expect(draft.hasChanges)
        #expect(draft.applied(to: TrackTags(artwork: .init(data: Data([1]), mimeType: "image/jpeg"))).artwork == nil)
    }
}
```

Run: `xcodebuild … test -only-testing:AetherTests/TagDraftTests -quiet`
Expected: FAIL — `cannot find 'TagDraft' in scope`.

- [ ] **Step 2: `TagDraft`**

`Aether/Cosmos/TagDraft.swift`:

```swift
import Observation
import SwiftUI
import TagKit

enum TagField: String, CaseIterable, Identifiable {
    case title, artist, remixer, album, albumArtist, label, year, isrc, genre, bpm, key, comment

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .title: "Título"
        case .artist: "Artista"
        case .remixer: "Remixer"
        case .album: "Álbum"
        case .albumArtist: "Artista del álbum"
        case .label: "Sello"
        case .year: "Año"
        case .isrc: "ISRC"
        case .genre: "Género"
        case .bpm: "BPM"
        case .key: "Tonalidad"
        case .comment: "Comentario"
        }
    }

    var isNumeric: Bool { self == .bpm }

    func get(_ t: TrackTags) -> String {
        switch self {
        case .title: t.title ?? ""
        case .artist: t.artist ?? ""
        case .remixer: t.remixer ?? ""
        case .album: t.album ?? ""
        case .albumArtist: t.albumArtist ?? ""
        case .label: t.label ?? ""
        case .year: t.year ?? ""
        case .isrc: t.isrc ?? ""
        case .genre: t.genre ?? ""
        case .bpm: t.bpm.map(TrackTags.formatBPM) ?? ""
        case .key: t.key ?? ""
        case .comment: t.comment ?? ""
        }
    }

    func set(_ t: inout TrackTags, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let s: String? = v.isEmpty ? nil : v
        switch self {
        case .title: t.title = s
        case .artist: t.artist = s
        case .remixer: t.remixer = s
        case .album: t.album = s
        case .albumArtist: t.albumArtist = s
        case .label: t.label = s
        case .year: t.year = s
        case .isrc: t.isrc = s?.uppercased()
        case .genre: t.genre = s
        case .bpm: t.bpm = s.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        case .key: t.key = s
        case .comment: t.comment = s
        }
    }
}

enum ArtworkChange: Equatable {
    case unchanged
    case set(TrackTags.Artwork)
    case removed
}

@MainActor
@Observable
final class TagDraft {
    private(set) var text: [TagField: String] = [:]
    private(set) var mixed: Set<TagField> = []
    private(set) var dirty: Set<TagField> = []
    var artwork: ArtworkChange = .unchanged
    let currentArtwork: TrackTags.Artwork?
    let artworkIsMixed: Bool

    init(tags: [TrackTags]) {
        for field in TagField.allCases {
            let values = Set(tags.map(field.get))
            if values.count > 1 { mixed.insert(field) } else { text[field] = values.first ?? "" }
        }
        let artworks = tags.map(\.artwork)
        artworkIsMixed = Set(artworks.map { $0?.data }).count > 1
        currentArtwork = artworkIsMixed ? nil : artworks.first ?? nil
    }

    var hasChanges: Bool { !dirty.isEmpty || artwork != .unchanged }

    func binding(_ field: TagField) -> Binding<String> {
        Binding(get: { self.text[field] ?? "" }, set: { newValue in
            self.text[field] = newValue
            self.dirty.insert(field)
            self.mixed.remove(field)
        })
    }

    func applied(to tags: TrackTags) -> TrackTags {
        var result = tags
        for field in dirty { field.set(&result, text[field] ?? "") }
        switch artwork {
        case .unchanged: break
        case .set(let art): result.artwork = art
        case .removed: result.artwork = nil
        }
        return result
    }
}
```

- [ ] **Step 3: Artwork (preparación y miniatura con ImageIO)**

`Aether/Cosmos/ArtworkProcessor.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import TagKit
import UniformTypeIdentifiers

enum ArtworkProcessor {
    /// Keeps JPEG/PNG ≤ 2 MB and ≤ 1500 px as-is; otherwise re-encodes to a 1400 px JPEG (q 0.9).
    static func prepare(_ data: Data) -> TrackTags.Artwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let isJPEG = type == UTType.jpeg.identifier
        let isPNG = type == UTType.png.identifier
        if (isJPEG || isPNG), data.count <= 2_000_000, max(width, height) <= 1500 {
            return TrackTags.Artwork(data: data, mimeType: isJPEG ? "image/jpeg" : "image/png")
        }
        guard let image = thumbnail(data, maxPixel: 1400) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return TrackTags.Artwork(data: out as Data, mimeType: "image/jpeg")
    }

    /// Decodes straight to display size — never a full-resolution bitmap in memory.
    static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
```

`Aether/Cosmos/ArtworkWell.swift`:

```swift
import SwiftUI
import TagKit

struct ArtworkWell: View {
    @Bindable var draft: TagDraft
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var isTargeted = false
    @State private var isImporting = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Tokens.surface)
            if let image {
                Image(decorative: image, scale: displayScale).resizable().scaledToFill()
            } else {
                Image(systemName: draft.artworkIsMixed ? "square.stack" : "photo")
                    .font(.title).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 180, height: 180)
        .clipShape(.rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Tokens.hairline), lineWidth: isTargeted ? 2 : 1))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, let data = try? Data(contentsOf: url), let art = ArtworkProcessor.prepare(data) else { return false }
            draft.artwork = .set(art)
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button("Elegir imagen…") { isImporting = true }
            Button("Quitar portada", role: .destructive) { draft.artwork = .removed }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let data = try? Data(contentsOf: url), let art = ArtworkProcessor.prepare(data) {
                draft.artwork = .set(art)
            }
        }
        .task(id: artworkIdentity) {
            let data: Data? = switch draft.artwork {
            case .set(let art): art.data
            case .removed: nil
            case .unchanged: draft.currentArtwork?.data
            }
            image = await Task.detached(priority: .userInitiated) { data.flatMap { ArtworkProcessor.thumbnail($0, maxPixel: 360) } }.value
        }
        .accessibilityLabel("Portada")
    }

    private var artworkIdentity: Int {
        switch draft.artwork {
        case .unchanged: draft.currentArtwork?.data.hashValue ?? 0
        case .set(let art): art.data.hashValue
        case .removed: -1
        }
    }
}
```

- [ ] **Step 4: Cargar y guardar en el store (con deshacer)**

Añadir a `CosmosStore`:

```swift
    func loadFullTags(_ items: [LibraryItem]) async -> [TrackTags] {
        let urls = items.map(url(for:))
        return await Task.detached(priority: .userInitiated) { urls.map { (try? TagIO.read($0)) ?? TrackTags() } }.value
    }

    func saveTags(_ draft: TagDraft, for items: [LibraryItem], undoManager: UndoManager?) async {
        let urls = items.map(url(for:)).filter(TagIO.isWritable)
        let before = await Task.detached(priority: .userInitiated) { urls.map { (try? TagIO.read($0)) ?? TrackTags() } }.value
        let after = before.map(draft.applied(to:))
        await write(after, to: urls)
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in
                await store.write(before, to: urls)
                undoManager?.registerUndo(withTarget: store) { s in Task { @MainActor in await s.write(after, to: urls) } }
            }
        }
        undoManager?.setActionName(items.count == 1 ? "Editar tags" : "Editar tags de \(items.count) pistas")
    }

    private func write(_ tags: [TrackTags], to urls: [URL]) async {
        await Task.detached(priority: .userInitiated) {
            for (t, url) in zip(tags, urls) { try? TagIO.write(t, to: url) }
        }.value
        await rescan()
    }
```

- [ ] **Step 5: Vista del inspector**

`Aether/Cosmos/TagInspectorView.swift`:

```swift
import Cosmos
import SwiftUI

struct TagInspectorView: View {
    @Environment(CosmosStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @State private var draft: TagDraft?
    @State private var isSaving = false

    private var items: [LibraryItem] { store.selectedItems }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Sin selección", systemImage: "tag", description: Text("Selecciona una o varias pistas."))
            } else if let draft {
                form(draft)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        .task(id: store.selection) {
            draft = nil
            guard !items.isEmpty else { return }
            draft = TagDraft(tags: await store.loadFullTags(items))
        }
    }

    private func form(_ draft: TagDraft) -> some View {
        Form {
            Section {
                HStack { Spacer(); ArtworkWell(draft: draft); Spacer() }
                if items.contains(where: { !TagIO.isWritable(store.url(for: $0)) }) {
                    Label("Algunos archivos son de solo lectura (M4A).", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            section("Pista", [.title, .artist, .remixer], draft)
            section("Lanzamiento", [.album, .albumArtist, .label, .year, .isrc], draft)
            section("DJ", [.genre, .bpm, .key, .comment], draft)
            if items.count == 1, let item = items.first { technical(item) }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button("Revertir") { self.draft = nil; Task { self.draft = TagDraft(tags: await store.loadFullTags(items)) } }
                    .disabled(!draft.hasChanges || isSaving)
                Button("Guardar") {
                    isSaving = true
                    Task {
                        await store.saveTags(draft, for: items, undoManager: undoManager)
                        self.draft = TagDraft(tags: await store.loadFullTags(items))
                        isSaving = false
                    }
                }
                .keyboardShortcut("s")
                .disabled(!draft.hasChanges || isSaving)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, _ fields: [TagField], _ draft: TagDraft) -> some View {
        Section {
            ForEach(fields) { field in
                TextField(field.label, text: draft.binding(field), prompt: draft.mixed.contains(field) ? Text("Varios") : nil)
                    .font(field.isNumeric || field == .isrc || field == .key ? .readout : .body)
            }
        } header: { SectionLabel(title) }
    }

    private func technical(_ item: LibraryItem) -> some View {
        Section {
            LabeledContent("Formato") { Readout(item.format.label, tone: .primary) }
            LabeledContent("Canales") { Readout("\(item.format.channels)") }
            LabeledContent("Tamaño") { Readout(item.fileSize.formatted(.byteCount(style: .file))) }
            LabeledContent("Integridad") {
                Readout(item.verifiedStamp.map { "VERIFICADO · \($0.dropFirst(4).prefix(8))…" } ?? "Sin verificar",
                        tone: item.isVerified ? .signal : .tertiary)
            }
            LabeledContent("Ruta") { Readout(item.relativePath) }
        } header: { SectionLabel("Técnico") }
    }
}
```

En `RootView`, sobre el `NavigationSplitView`:

```swift
        .inspector(isPresented: $model.isInspectorPresented) {
            TagInspectorView()
        }
```

- [ ] **Step 6: Verificar**

Run: `xcodebuild … test -only-testing:AetherTests -quiet`
Expected: PASS. A mano: seleccionar 3 pistas en "Por clasificar", ⌃⌘I, poner Género "UK House" → Guardar → la columna Género se actualiza; ⌘Z revierte los 3 archivos; arrastrar un JPG de Finder a la portada y Guardar → `hasArtwork` en el índice.

- [ ] **Step 7: Commit**

```bash
git add Aether AetherTests
git commit -m "feat(cosmos-ui): add batch tag inspector with artwork and undo"
```

---

### Task 8: Acciones — mover, renombrar, Papelera, Quick Look, verificar, comandos; spike S3 de WAV

**Files:**
- Create: `Aether/Cosmos/CosmosActions.swift` (extensión de `CosmosStore`)
- Create: `Aether/Cosmos/RenamePreviewSheet.swift`
- Create: `Aether/Cosmos/MoveToMenu.swift`
- Modify: `Aether/Cosmos/CosmosBrowserView.swift` (menú contextual, Quick Look, hoja de renombrado, aviso rekordbox)
- Modify: `Aether/Shell/SidebarView.swift` (soltar sobre carpetas)
- Modify: `Aether/App/AetherCommands.swift` (menú Cosmos)
- Modify: `Aether/App/AppModel.swift` (estado de hojas)

**Interfaces:**
- Consumes: `Organizer`, `MoveJournal`, `IntegrityVerifier`, `FlacTags`, `TagIO`.
- Produces (en `CosmosStore`): `move(_ items: [LibraryItem], toFolder: String, undoManager: UndoManager?) async`, `moveURLs(_ urls: [URL], toFolder: String, undoManager: UndoManager?) async`, `plannedRenames(for: [LibraryItem]) async -> [FileMove]`, `applyRenames(_ moves: [FileMove], undoManager: UndoManager?) async`, `trash(_ items: [LibraryItem], undoManager: UndoManager?) async`, `verify(_ items: [LibraryItem]) async -> [String: IntegrityReport]`, `var quickLookURL: URL?`, `var renamePlan: [FileMove]?`, `var verifying: Set<String>`

- [ ] **Step 1: Acciones en el store**

`Aether/Cosmos/CosmosActions.swift`:

```swift
import AppKit
import Cosmos
import FlacKit
import Foundation
import TagKit

extension CosmosStore {
    func move(_ items: [LibraryItem], toFolder folder: String, undoManager: UndoManager?) async {
        await moveURLs(items.map(url(for:)), toFolder: folder, undoManager: undoManager)
    }

    func moveURLs(_ urls: [URL], toFolder folder: String, undoManager: UndoManager?) async {
        let target = root.appending(path: folder, directoryHint: .isDirectory)
        guard let moves = try? await Task.detached { try Organizer.move(urls, to: target) }.value, !moves.isEmpty else { return }
        await record(moves, reason: "move", actionName: "Mover a \(folder)", undoManager: undoManager)
    }

    func plannedRenames(for items: [LibraryItem]) async -> [FileMove] {
        let urls = items.map(url(for:))
        let tags = await loadFullTags(items)
        return Organizer.plannedRenames(Array(zip(urls, tags.map(\.withoutArtwork))))
    }

    func applyRenames(_ moves: [FileMove], undoManager: UndoManager?) async {
        guard let applied = try? await Task.detached { try Organizer.apply(moves) }.value else { return }
        await record(applied, reason: "rename", actionName: "Renombrar desde tags", undoManager: undoManager)
    }

    func trash(_ items: [LibraryItem], undoManager: UndoManager?) async {
        var moves: [FileMove] = []
        for url in items.map(url(for:)) {
            var resulting: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &resulting)) != nil, let trashed = resulting as URL? {
                moves.append(FileMove(from: url, to: trashed))
            }
        }
        guard !moves.isEmpty else { return }
        await record(moves, reason: "trash", actionName: "Mover a la Papelera", undoManager: undoManager)
    }

    /// Re-verifies FLACs against their STREAMINFO MD5; stamps AETHER_VERIFIED when the file proves bit-perfect.
    func verify(_ items: [LibraryItem]) async -> [String: IntegrityReport] {
        let flacs = items.filter { $0.format.codec == .flac }
        verifying.formUnion(flacs.map(\.id))
        defer { verifying.subtract(flacs.map(\.id)) }
        var reports: [String: IntegrityReport] = [:]
        for item in flacs {
            let url = url(for: item)
            let report = await Task.detached(priority: .userInitiated) { () -> IntegrityReport? in
                guard let report = try? IntegrityVerifier.verify(flacAt: url) else { return nil }
                if report.verdict == .verified, let tags = try? FlacTags.read(url).tags {
                    try? FlacTags.write(tags, to: url, extraFields: [
                        IntegrityVerifier.verifiedFieldKey: IntegrityVerifier.verifiedFieldValue(report, at: .now)])
                }
                return report
            }.value
            reports[item.id] = report
        }
        await rescan()
        return reports
    }

    private func record(_ moves: [FileMove], reason: String, actionName: String, undoManager: UndoManager?) async {
        await journal.record(moves, reason: reason)
        onRelocated?(moves)
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in
                let inverse = moves.map(\.inverse).reversed()
                guard let undone = try? Organizer.apply(inverse) else { return }
                await store.record(undone, reason: "undo-\(reason)", actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(actionName)
        await rescan()
    }
}
```

Añadir a `CosmosStore` (propiedades observables):

```swift
    var quickLookURL: URL?
    var renamePlan: [FileMove]?
    var verifying: Set<String> = []
```

- [ ] **Step 2: Menú "Mover a…" y hoja de renombrado**

`Aether/Cosmos/MoveToMenu.swift`:

```swift
import Cosmos
import SwiftUI

struct MoveToMenu: View {
    let items: [LibraryItem]
    @Environment(CosmosStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Menu("Mover a") {
            ForEach(store.folders) { folder in
                Button(folder.name) { Task { await store.move(items, toFolder: folder.name, undoManager: undoManager) } }
                    .disabled(items.allSatisfy { $0.folder == folder.name })
            }
        }
        .disabled(items.isEmpty)
    }
}
```

`Aether/Cosmos/RenamePreviewSheet.swift`:

```swift
import Cosmos
import SwiftUI

struct RenamePreviewSheet: View {
    let plan: [FileMove]
    @Environment(CosmosStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Renombrar desde tags").font(.headline)
            Text("Formato: Artista - Título. Los archivos sin título o artista no se tocan.")
                .font(.callout).foregroundStyle(.secondary)
            List(plan, id: \.from) { move in
                VStack(alignment: .leading, spacing: 2) {
                    Readout(move.from.lastPathComponent, tone: .tertiary)
                    Readout("→ \(move.to.lastPathComponent)", tone: .primary)
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Renombrar \(plan.count)") {
                    Task { await store.applyRenames(plan, undoManager: undoManager); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty)
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 560)
    }
}
```

- [ ] **Step 3: Menú contextual, Quick Look, aviso rekordbox y soltar en sidebar**

En `CosmosBrowserView`, añadir al `Table`:

```swift
        .contextMenu(forSelectionType: String.self) { ids in
            let items = store.visible.filter { ids.contains($0.id) }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(store.url(for:))) }
            MoveToMenu(items: items)
            Button("Renombrar desde tags…") { Task { store.renamePlan = await store.plannedRenames(for: items) } }
            Button("Verificar integridad") { Task { _ = await store.verify(items) } }
                .disabled(!items.contains { $0.format.codec == .flac })
            Divider()
            Button("Mover a la Papelera", role: .destructive) { Task { await store.trash(items, undoManager: undoManager) } }
        } primaryAction: { ids in
            // Double-click: reveal for now; plan 06 turns this into "play in Aether Core".
            NSWorkspace.shared.activateFileViewerSelecting(store.visible.filter { ids.contains($0.id) }.map(store.url(for:)))
        }
        .quickLookPreview($store.quickLookURL, in: store.visible.map(store.url(for:)))
        .sheet(item: Binding(get: { store.renamePlan.map(IdentifiedPlan.init) }, set: { store.renamePlan = $0?.moves })) {
            RenamePreviewSheet(plan: $0.moves)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.scope != .cosmosInbox {
                Label("Mover archivos ya importados en rekordbox rompe sus rutas. Clasifica antes de importar.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.Space.l).padding(.vertical, Tokens.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
```

con `@Environment(\.undoManager) private var undoManager` y:

```swift
private struct IdentifiedPlan: Identifiable {
    let moves: [FileMove]
    var id: Int { moves.map(\.from.path).hashValue }
}
```

En `SidebarView`, a cada fila de carpeta (y a "Por clasificar") añadir:

```swift
                        .dropDestination(for: URL.self) { urls, _ in
                            Task { await cosmos.moveURLs(urls, toFolder: folder.name, undoManager: undoManager) }
                            return true
                        }
```

(`@Environment(\.undoManager) private var undoManager` en `SidebarView`; para "Por clasificar" usar `preferences.inboxFolderName`.)

- [ ] **Step 4: Menú Cosmos**

En `AetherCommands`:

```swift
        CommandMenu("Cosmos") {
            Button("Mostrar en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(model.cosmos.selectedItems.map(model.cosmos.url(for:)))
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.cosmos.selection.isEmpty)
            Button("Quick Look") { model.cosmos.quickLookURL = model.cosmos.selectedItems.first.map(model.cosmos.url(for:)) }
                .keyboardShortcut("y")
                .disabled(model.cosmos.selection.isEmpty)
            Button("Renombrar desde tags…") {
                Task { model.cosmos.renamePlan = await model.cosmos.plannedRenames(for: model.cosmos.selectedItems) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.cosmos.selection.isEmpty)
            Button("Verificar integridad") { Task { _ = await model.cosmos.verify(model.cosmos.selectedItems) } }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(model.cosmos.selection.isEmpty)
            Divider()
            Button("Re-escanear Master") { Task { await model.cosmos.rescan() } }
        }
```

"Mover a…" (⇧⌘M) y "Mover a la Papelera" (⌘⌫) necesitan el `UndoManager` de la ventana, que solo existe en el entorno de la vista. Por eso viven en la toolbar de `CosmosBrowserView` (los atajos de la toolbar funcionan igual que los del menú). Añadir a `CosmosBrowserView`:

```swift
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                MoveToMenu(items: store.selectedItems)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .help("Mover a… (⇧⌘M)")
                Button {
                    Task { await store.trash(store.selectedItems, undoManager: undoManager) }
                } label: {
                    Label("Mover a la Papelera", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selection.isEmpty)
                .help("Mover a la Papelera (⌘⌫)")
            }
        }
```

- [ ] **Step 5: Spike S3 — ¿rekordbox lee el chunk ID3 en WAV?**

1. Copiar `~/Master/b2bsept.wav` a `~/Master/Por clasificar/s3.wav` con Finder (⌥-arrastrar; nunca editar el original).
2. En Aether › Por clasificar, seleccionar `s3.wav`, poner Título "S3 TEST" en el inspector y Guardar.
3. Importar el archivo en rekordbox. Si muestra "S3 TEST" → S3 PASS. Si no → en `Aether/App/AppModel.swift` `init`, poner `TagIO.wavTagsEnabled = false` y anotar en `docs/spikes.md`.
4. Borrar el archivo de prueba.

- [ ] **Step 6: Verificar**

A mano: seleccionar 2 pistas en "Por clasificar" → "Mover a › UK House" → aparecen en UK House; ⌘Z las devuelve; arrastrar una fila a "Disco" en la sidebar la mueve; ⇧⌘N muestra la previsualización; ⌘Y abre Quick Look; ⌥⌘V en un FLAC descargado por Harvester → sello verde; `~/Library/Application Support/Aether/cosmos-moves.jsonl` registra todo.

- [ ] **Step 7: Commit**

```bash
git add Aether docs/spikes.md
git commit -m "feat(cosmos-ui): move, rename, trash and verify with undo, Quick Look and menu commands"
```

---

### Task 9: Integración Harvester ↔ Cosmos

**Files:**
- Modify: `Aether/Harvester/HarvesterStore.swift` (`masterLookup`, decisión de duplicados, `relocate`)
- Modify: `Aether/Harvester/TrackTable.swift` (columna "Master")
- Modify: `Aether/Harvester/HarvesterSearchView.swift` (diálogo de confirmación)
- Modify: `Aether/App/AppModel.swift` (cablear callbacks)
- Test: `AetherTests/DuplicateGateTests.swift`

**Interfaces:**
- Consumes: `MasterLookup`, `FileMove`, `HistoryStore.relocate`.
- Produces (en `HarvesterStore`): `var masterLookup: MasterLookup`, `func masterMatch(for: TidalTrack) -> MasterLookup.Match?`, `var pendingDuplicates: [TidalTrack]?`, `var pendingFresh: [TidalTrack]`, `func requestEnqueue(_ tracks: [TidalTrack])`, `func resolvePendingDuplicates(includeDuplicates: Bool)`, `func relocate(_ moves: [FileMove]) async`

- [ ] **Step 1: Prueba que falla**

`AetherTests/DuplicateGateTests.swift`:

```swift
import Cosmos
import Foundation
import HiFiClient
import TagKit
import Testing
@testable import Aether

@MainActor
@Suite struct DuplicateGateTests {
    @Test func exactMatchesAreHeldForConfirmation() throws {
        let store = HarvesterStore(preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        store.masterLookup = MasterLookup(items: [LibraryItem(
            relativePath: "UK House/Prospa - Dreams.flac", fileSize: 1, modified: .distantPast,
            format: AudioFormatInfo(codec: .flac, sampleRate: 44_100, bitDepth: 16, channels: 2, duration: 1, bitRate: nil),
            tags: TrackTags(title: "Dreams", artist: "Prospa", isrc: "QM6MZ2647627"), hasArtwork: false, verifiedStamp: nil)])
        let dup = try JSONDecoder().decode(TidalTrack.self, from: Data(#"{"id":1,"title":"Dreams","duration":1,"isrc":"QM6MZ2647627","artist":{"id":1,"name":"Prospa"}}"#.utf8))
        let fresh = try JSONDecoder().decode(TidalTrack.self, from: Data(#"{"id":2,"title":"Baby","duration":1,"artist":{"id":1,"name":"Prospa"}}"#.utf8))

        store.requestEnqueue([dup, fresh])
        #expect(store.pendingDuplicates?.map(\.id) == [1])
        #expect(store.jobs.map(\.request.track.id) == [2])

        store.resolvePendingDuplicates(includeDuplicates: false)
        #expect(store.pendingDuplicates == nil)
        #expect(store.jobs.count == 1)
    }
}
```

Run: `xcodebuild … test -only-testing:AetherTests/DuplicateGateTests -quiet`
Expected: FAIL — `value of type 'HarvesterStore' has no member 'masterLookup'`.

- [ ] **Step 2: Implementar en `HarvesterStore`**

```swift
    var masterLookup: MasterLookup = .empty
    var pendingDuplicates: [TidalTrack]?

    func masterMatch(for track: TidalTrack) -> MasterLookup.Match? {
        masterLookup.match(isrc: track.isrc, artist: track.allArtistNames, title: track.displayTitle)
    }

    /// Fresh tracks start immediately; exact matches wait for an explicit decision (no silent re-downloads).
    func requestEnqueue(_ tracks: [TidalTrack]) {
        var fresh: [TidalTrack] = []
        var duplicates: [TidalTrack] = []
        for track in tracks {
            if case .exact = masterMatch(for: track) { duplicates.append(track) } else { fresh.append(track) }
        }
        if !fresh.isEmpty { enqueue(fresh) }
        pendingDuplicates = duplicates.isEmpty ? nil : duplicates
    }

    func resolvePendingDuplicates(includeDuplicates: Bool) {
        if includeDuplicates, let pending = pendingDuplicates { enqueue(pending) }
        pendingDuplicates = nil
    }

    func relocate(_ moves: [FileMove]) async {
        for move in moves { await historyStore.relocate(from: move.from, to: move.to) }
        history = await historyStore.all()
        if preferences.rekordboxXMLEnabled {
            let entries = history
            let url = preferences.rekordboxXMLURL
            await Task.detached(priority: .utility) { try? RekordboxXML.write(entries: entries, to: url) }.value
        }
    }
```

(`import Cosmos` al principio del archivo.) Sustituir las llamadas de UI `store.enqueue(...)` en `TrackTable`, `AlbumTracksView`, `HarvesterSearchView` y `enqueueSelection()` por `requestEnqueue(...)`.

- [ ] **Step 3: Columna "Master" y diálogo**

En `TrackTable`, primera columna:

```swift
            TableColumn("") { track in
                switch store.masterMatch(for: track) {
                case .exact(let item):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.signal)
                        .help("Ya en Master: \(item.relativePath)")
                        .accessibilityLabel("Ya en Master")
                case .similar(let item):
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                        .help("Parecida en Master: \(item.relativePath)")
                        .accessibilityLabel("Versión parecida en Master")
                case nil:
                    EmptyView()
                }
            }
            .width(20)
```

En `HarvesterSearchView`, sobre el `NavigationStack`:

```swift
        .confirmationDialog(
            "\(store.pendingDuplicates?.count ?? 0) ya están en Master",
            isPresented: Binding(get: { store.pendingDuplicates != nil }, set: { if !$0 { store.resolvePendingDuplicates(includeDuplicates: false) } }),
            titleVisibility: .visible
        ) {
            Button("Omitirlas") { store.resolvePendingDuplicates(includeDuplicates: false) }
                .keyboardShortcut(.defaultAction)
            Button("Descargar de todos modos") { store.resolvePendingDuplicates(includeDuplicates: true) }
        } message: {
            Text("Coinciden por ISRC o por artista y título.")
        }
```

- [ ] **Step 4: Cablear en `AppModel`**

Al final de `init`:

```swift
        cosmos.onLookupChanged = { [harvester] lookup in harvester.masterLookup = lookup }
        cosmos.onRelocated = { [harvester] moves in Task { await harvester.relocate(moves) } }
```

- [ ] **Step 5: Verificar**

Run: `xcodebuild … test -quiet`
Expected: todo PASS. A mano: buscar una pista que ya está en `~/Master/UK House` → check verde en la tabla; ⌘D → diálogo "1 ya están en Master" con "Omitirlas" por defecto. Mover en Cosmos una pista descargada por Harvester → `rekordbox.xml` apunta a la nueva ruta.

- [ ] **Step 6: Commit**

```bash
git add Aether AetherTests
git commit -m "feat: flag tracks already in Master and keep Harvester history in sync with Cosmos moves"
```
