# Aether v1 · Plan 03 — FlacKit (demux fMP4→FLAC y verificación de integridad)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convertir segmentos DASH fMP4 de Tidal en un FLAC nativo escrito en streaming, y verificarlo bit a bit: CRC de cada frame, conteo exacto de muestras y MD5 del PCM decodificado contra el MD5 que publica la fuente.

**Architecture:** Módulo `FlacKit` sobre `ByteKit` y `TagKit`. Piezas puras y probadas por separado: `CRC`, `FrameHeaderParser`, `FlacFrameScanner` (archivo mapeado + `memchr`), `PCMDigest` (AudioToolbox `ExtAudioFile` + CryptoKit), `MP4`/`FMP4Flac` (cajas ISO-BMFF), `FlacAssembler` (escritura incremental con reanudación) e `IntegrityVerifier` (orquesta). Las pruebas generan FLAC reales con el codificador de AudioToolbox y segmentos fMP4 sintéticos; no hay binarios con copyright en el repo.

**Tech Stack:** Swift 6, Foundation, AudioToolbox, CryptoKit, Darwin (`memchr`), Swift Testing.

**Spec:** `docs/superpowers/plans/2026-10-20-aether-v1-00-overview.md` (§2 hechos 5–7, §6 pipeline)

## Global Constraints

- macOS 27, Swift 6, cero dependencias de terceros.
- Nunca cargar un archivo de audio completo en memoria dinámica: escaneo con `Data(contentsOf:options:.alwaysMapped)`, decodificación en bloques de 65 536 frames.
- Verificación de un FLAC 24/44.1 de 4 min < 1.5 s (build release, Apple Silicon).
- Formato de MD5 FLAC: PCM entrelazado, entero con signo, little-endian, `ceil(bps/8)` bytes por muestra.
- **Prerrequisito:** spike S1 = PASS y S4 documentado (`docs/spikes.md`). Si S4 mostró que `afconvert`/AudioToolbox no codifica FLAC, generar los fixtures de la Task 3 con `flac` de Homebrew y guardarlos en `Packages/AetherKit/Tests/FlacKitTests/Resources/` (tono sintético, sin copyright).

Rutas relativas a `~/Documents/Projects/Aether`. Pruebas: `swift test --package-path Packages/AetherKit`.

---

### Task 1: CRC-8/CRC-16 y parser de cabecera de frame FLAC

**Files:**
- Modify: `Packages/AetherKit/Package.swift`
- Create: `Packages/AetherKit/Sources/FlacKit/CRC.swift`
- Create: `Packages/AetherKit/Sources/FlacKit/FrameHeaderParser.swift`
- Test: `Packages/AetherKit/Tests/FlacKitTests/CRCAndHeaderTests.swift`

**Interfaces:**
- Produces:
  - `public enum CRC { static func crc8(_: UnsafeRawBufferPointer) -> UInt8; static func crc16(_: UnsafeRawBufferPointer) -> UInt16; static func crc8(_: [UInt8]) -> UInt8; static func crc16(_: [UInt8]) -> UInt16 }` — CRC-8 poly 0x07, CRC-16 poly 0x8005, init 0, sin reflexión.
  - `public struct FrameHeader: Equatable, Sendable { let blockSize: Int; let headerLength: Int }`
  - `public enum FrameHeaderParser { static func parse(_ buf: UnsafeRawBufferPointer, at offset: Int, maxBlockSize: Int) -> FrameHeader? }`

- [ ] **Step 1: Añadir el target**

`Packages/AetherKit/Package.swift`:

```swift
.library(name: "AetherKit", targets: ["ByteKit", "TagKit", "FlacKit"]),
```

```swift
.target(name: "FlacKit", dependencies: ["ByteKit", "TagKit"], swiftSettings: settings),
.testTarget(name: "FlacKitTests", dependencies: ["FlacKit", "TagKit"], swiftSettings: settings),
```

- [ ] **Step 2: Pruebas que fallan**

`Packages/AetherKit/Tests/FlacKitTests/CRCAndHeaderTests.swift`:

```swift
import Testing
@testable import FlacKit

@Suite struct CRCAndHeaderTests {
    @Test func crcCheckValues() {
        let check = Array("123456789".utf8)
        #expect(CRC.crc8(check) == 0xF4)     // CRC-8 (poly 0x07)
        #expect(CRC.crc16(check) == 0xFEE8)  // CRC-16/BUYPASS (poly 0x8005)
    }

    /// Fixed-blocksize header: sync FFF8, blocksize code 12 (4096), sample-rate code 9 (44.1 kHz),
    /// stereo, 24-bit, frame number 0, then CRC-8.
    private func header(frameNumber: UInt8 = 0) -> [UInt8] {
        let body: [UInt8] = [0xFF, 0xF8, 0xC9, 0x1C, frameNumber]
        return body + [CRC.crc8(body)]
    }

    @Test func parsesValidHeader() {
        let bytes = header() + [0, 0, 0]
        let parsed = bytes.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 4096) }
        #expect(parsed == FrameHeader(blockSize: 4096, headerLength: 6))
    }

    @Test func rejectsBadCRCReservedBitsAndOversizedBlocks() {
        var bad = header()
        bad[5] ^= 0xFF
        #expect(bad.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 4096) } == nil)

        let reservedBody: [UInt8] = [0xFF, 0xF8, 0xC9, 0x1D, 0x00]
        let reserved = reservedBody + [CRC.crc8(reservedBody)]
        #expect(reserved.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 4096) } == nil)

        #expect(header().withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 1152) } == nil)
    }

    @Test func parsesExplicitBlockSizeAndMultiByteFrameNumber() {
        // blocksize code 7 (16-bit explicit, value-1), sample-rate code 12 (8-bit kHz), frame number 0xC2 0x80 (=128).
        let body: [UInt8] = [0xFF, 0xF8, 0x7C, 0x18, 0xC2, 0x80, 0x0F, 0xFF, 0x30]
        let bytes = body + [CRC.crc8(body)]
        let parsed = bytes.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 0) }
        #expect(parsed == FrameHeader(blockSize: 4096, headerLength: 10))
    }

    @Test func rejectsTruncatedInput() {
        let bytes: [UInt8] = [0xFF, 0xF8, 0xC9]
        #expect(bytes.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 0) } == nil)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter CRCAndHeaderTests`
Expected: FAIL de compilación — `cannot find 'CRC' in scope`.

- [ ] **Step 3: Implementar**

`Packages/AetherKit/Sources/FlacKit/CRC.swift`:

```swift
public enum CRC {
    private static let table8: [UInt8] = (0..<256).map { i in
        var c = UInt8(i)
        for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }
        return c
    }

    private static let table16: [UInt16] = (0..<256).map { i in
        var c = UInt16(i) << 8
        for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 }
        return c
    }

    public static func crc8(_ bytes: UnsafeRawBufferPointer) -> UInt8 {
        table8.withUnsafeBufferPointer { table in
            var crc: UInt8 = 0
            for byte in bytes { crc = table[Int(crc ^ byte)] }
            return crc
        }
    }

    public static func crc16(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        table16.withUnsafeBufferPointer { table in
            var crc: UInt16 = 0
            for byte in bytes { crc = (crc << 8) ^ table[Int(UInt8(crc >> 8) ^ byte)] }
            return crc
        }
    }

    public static func crc8(_ bytes: [UInt8]) -> UInt8 { bytes.withUnsafeBytes { crc8($0) } }
    public static func crc16(_ bytes: [UInt8]) -> UInt16 { bytes.withUnsafeBytes { crc16($0) } }
}
```

`Packages/AetherKit/Sources/FlacKit/FrameHeaderParser.swift`:

```swift
public struct FrameHeader: Equatable, Sendable {
    public let blockSize: Int
    public let headerLength: Int

    public init(blockSize: Int, headerLength: Int) {
        self.blockSize = blockSize
        self.headerLength = headerLength
    }
}

/// RFC 9639 §9.1 frame header. Returns nil unless sync, field ranges and CRC-8 are all valid.
public enum FrameHeaderParser {
    public static func parse(_ buf: UnsafeRawBufferPointer, at o: Int, maxBlockSize: Int) -> FrameHeader? {
        let n = buf.count
        guard o >= 0, o + 6 <= n, buf[o] == 0xFF, buf[o + 1] & 0xFE == 0xF8 else { return nil }
        let blockCode = buf[o + 2] >> 4
        let rateCode = buf[o + 2] & 0x0F
        let channelCode = buf[o + 3] >> 4
        let sizeCode = (buf[o + 3] >> 1) & 0x07
        guard blockCode != 0, rateCode != 0x0F, channelCode <= 10, sizeCode != 3, buf[o + 3] & 1 == 0 else { return nil }

        var p = o + 4
        let first = buf[p]
        let extra: Int
        switch first {
        case 0x00...0x7F: extra = 0
        case 0xC0...0xDF: extra = 1
        case 0xE0...0xEF: extra = 2
        case 0xF0...0xF7: extra = 3
        case 0xF8...0xFB: extra = 4
        case 0xFC...0xFD: extra = 5
        case 0xFE: extra = 6
        default: return nil
        }
        guard p + 1 + extra <= n else { return nil }
        if extra > 0 {
            for i in 1...extra where buf[p + i] & 0xC0 != 0x80 { return nil }
        }
        p += 1 + extra

        let blockSize: Int
        switch blockCode {
        case 1: blockSize = 192
        case 2...5: blockSize = 576 << Int(blockCode - 2)
        case 6:
            guard p + 1 <= n else { return nil }
            blockSize = Int(buf[p]) + 1
            p += 1
        case 7:
            guard p + 2 <= n else { return nil }
            blockSize = (Int(buf[p]) << 8 | Int(buf[p + 1])) + 1
            p += 2
        default: blockSize = 256 << Int(blockCode - 8)
        }

        switch rateCode {
        case 12: p += 1
        case 13, 14: p += 2
        default: break
        }
        guard p < n else { return nil }
        guard CRC.crc8(UnsafeRawBufferPointer(rebasing: buf[o..<p])) == buf[p] else { return nil }
        if maxBlockSize > 0, blockSize > maxBlockSize { return nil }
        return FrameHeader(blockSize: blockSize, headerLength: p + 1 - o)
    }
}
```

- [ ] **Step 4: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter CRCAndHeaderTests`
Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(flackit): add FLAC CRC-8/16 and frame header parser"
```

---

### Task 2: Fixtures de audio reales y `PCMDigest` (MD5 del PCM)

**Files:**
- Create: `Packages/AetherKit/Sources/FlacKit/PCMDigest.swift`
- Create: `Packages/AetherKit/Tests/FlacKitTests/AudioFixture.swift`
- Test: `Packages/AetherKit/Tests/FlacKitTests/PCMDigestTests.swift`

**Interfaces:**
- Produces:
  - `public struct PCMDigestResult: Equatable, Sendable { var md5: [UInt8]; var frames: UInt64 }`
  - `public enum PCMDigestError: Error, Equatable { case unsupportedBitDepth(Int); case audioToolbox(Int32) }`
  - `public enum PCMDigest { static func md5(ofFileAt url: URL, bitsPerSample: Int, channels: Int, totalFrames: UInt64? = nil, progress: ((Double) -> Void)? = nil) throws -> PCMDigestResult }`
  - (tests) `enum AudioFixture { static func makeFLAC(seconds: Double = 2, sampleRate: Double = 44_100, bits: Int = 16, channels: Int = 2) throws -> (url: URL, pcm: [UInt8]) }`

- [ ] **Step 1: Fixture generador (codificador FLAC de AudioToolbox)**

`Packages/AetherKit/Tests/FlacKitTests/AudioFixture.swift`:

```swift
import AudioToolbox
import Foundation

enum AudioFixture {
    struct Failure: Error { let status: OSStatus }

    private static func check(_ s: OSStatus) throws { if s != noErr { throw Failure(status: s) } }

    /// Encodes a deterministic two-tone signal to FLAC and returns the exact PCM fed to the encoder
    /// (interleaved, signed, little-endian, `bits/8` bytes per sample) — the FLAC MD5 reference layout.
    static func makeFLAC(seconds: Double = 2, sampleRate: Double = 44_100, bits: Int = 16, channels: Int = 2) throws -> (url: URL, pcm: [UInt8]) {
        let frames = Int(seconds * sampleRate)
        let bytesPerSample = bits / 8
        let amplitude = Double((1 << (bits - 1)) - 1) * 0.6
        var pcm = [UInt8]()
        pcm.reserveCapacity(frames * channels * bytesPerSample)
        for i in 0..<frames {
            for c in 0..<channels {
                let t = Double(i) / sampleRate
                let v = Int32(amplitude * sin(2 * .pi * (440 + Double(c) * 110) * t))
                for b in 0..<bytesPerSample { pcm.append(UInt8(truncatingIfNeeded: v >> (8 * b))) }
            }
        }

        let url = FileManager.default.temporaryDirectory.appending(path: "fixture-\(UUID().uuidString).flac")
        var flac = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatFLAC, mFormatFlags: bits == 16 ? 1 : 3,
            mBytesPerPacket: 0, mFramesPerPacket: 4096, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var ref: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &flac, nil,
                                            AudioFileFlags.eraseFile.rawValue, &ref))
        guard let file = ref else { throw Failure(status: -1) }
        defer { ExtAudioFileDispose(file) }

        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerSample * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerSample * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bits), mReserved: 0)
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))

        let frameBytes = bytesPerSample * channels
        var written = 0
        try pcm.withUnsafeMutableBytes { raw in
            while written < frames {
                let count = min(4096, frames - written)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(count * frameBytes),
                    mData: raw.baseAddress! + written * frameBytes))
                try check(ExtAudioFileWrite(file, UInt32(count), &list))
                written += count
            }
        }
        return (url, pcm)
    }
}
```

- [ ] **Step 2: Pruebas que fallan**

`Packages/AetherKit/Tests/FlacKitTests/PCMDigestTests.swift`:

```swift
import CryptoKit
import Foundation
import Testing
@testable import FlacKit

@Suite struct PCMDigestTests {
    @Test(arguments: [16, 24])
    func md5MatchesSourcePCM(bits: Int) throws {
        let (url, pcm) = try AudioFixture.makeFLAC(seconds: 1.5, bits: bits)
        let result = try PCMDigest.md5(ofFileAt: url, bitsPerSample: bits, channels: 2)
        #expect(result.md5 == Array(Insecure.MD5.hash(data: pcm)))
        #expect(result.frames == UInt64(pcm.count / (2 * bits / 8)))
    }

    @Test func reportsProgressToCompletion() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 3)
        let box = ProgressBox()
        _ = try PCMDigest.md5(ofFileAt: url, bitsPerSample: 16, channels: 2, totalFrames: 132_300) { box.values.append($0) }
        #expect(box.values.last == 1.0)
        #expect(box.values == box.values.sorted())
    }

    @Test func rejectsOddBitDepth() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 0.1)
        #expect(throws: PCMDigestError.unsupportedBitDepth(20)) {
            try PCMDigest.md5(ofFileAt: url, bitsPerSample: 20, channels: 2)
        }
    }
}

final class ProgressBox: @unchecked Sendable { var values: [Double] = [] }
```

Run: `swift test --package-path Packages/AetherKit --filter PCMDigestTests`
Expected: FAIL de compilación — `cannot find 'PCMDigest' in scope`.

- [ ] **Step 3: Implementar `PCMDigest`**

`Packages/AetherKit/Sources/FlacKit/PCMDigest.swift`:

```swift
import AudioToolbox
import CryptoKit
public import Foundation

public struct PCMDigestResult: Equatable, Sendable {
    public var md5: [UInt8]
    public var frames: UInt64
}

public enum PCMDigestError: Error, Equatable, Sendable {
    case unsupportedBitDepth(Int)
    case audioToolbox(Int32)
}

/// MD5 over decoded PCM in FLAC's canonical layout (RFC 9639 §8.2): interleaved, signed, little-endian,
/// ceil(bps/8) bytes per sample. Decodes in 64 Ki-frame chunks: constant memory regardless of file size.
public enum PCMDigest {
    public static func md5(ofFileAt url: URL, bitsPerSample: Int, channels: Int, totalFrames: UInt64? = nil,
                           progress: ((Double) -> Void)? = nil) throws -> PCMDigestResult {
        guard [8, 16, 24, 32].contains(bitsPerSample) else { throw PCMDigestError.unsupportedBitDepth(bitsPerSample) }
        var ref: ExtAudioFileRef?
        try check(ExtAudioFileOpenURL(url as CFURL, &ref))
        guard let file = ref else { throw PCMDigestError.audioToolbox(-1) }
        defer { ExtAudioFileDispose(file) }

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat))

        let bytesPerSample = bitsPerSample / 8
        let frameBytes = bytesPerSample * channels
        var client = AudioStreamBasicDescription(
            mSampleRate: fileFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(frameBytes), mFramesPerPacket: 1, mBytesPerFrame: UInt32(frameBytes),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bitsPerSample), mReserved: 0)
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))

        let chunkFrames = 65_536
        var buffer = [UInt8](repeating: 0, count: chunkFrames * frameBytes)
        var hasher = Insecure.MD5()
        var decoded: UInt64 = 0
        var lastReported = -1.0
        while true {
            var frames = UInt32(chunkFrames)
            try buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                try check(ExtAudioFileRead(file, &frames, &list))
            }
            if frames == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<(Int(frames) * frameBytes)])) }
            decoded += UInt64(frames)
            if let total = totalFrames, total > 0, let progress {
                let fraction = min(Double(decoded) / Double(total), 1)
                if fraction - lastReported >= 0.02 { progress(fraction); lastReported = fraction }
            }
        }
        if lastReported < 1 { progress?(1) }
        return PCMDigestResult(md5: Array(hasher.finalize()), frames: decoded)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw PCMDigestError.audioToolbox(status) }
    }
}
```

- [ ] **Step 4: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter PCMDigestTests`
Expected: 4 PASS (2 parametrizadas + 2). Si `md5MatchesSourcePCM` falla solo en 24 bits, comparar con `docs/spikes.md` S1 (que validó 24 bits con `afconvert`) y revisar `mFormatFlags` del cliente antes de seguir.

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(flackit): compute FLAC canonical PCM MD5 with AudioToolbox"
```

---

### Task 3: `FlacFrameScanner` (CRC de cada frame sobre archivo mapeado)

**Files:**
- Create: `Packages/AetherKit/Sources/FlacKit/FlacFrameScanner.swift`
- Test: `Packages/AetherKit/Tests/FlacKitTests/FlacFrameScannerTests.swift`

**Interfaces:**
- Consumes: `CRC`, `FrameHeaderParser`, `FlacMetadataIO`, `StreamInfo`.
- Produces:
  - `public struct FrameScanReport: Equatable, Sendable, Codable { var frames: Int; var samples: UInt64; var minFrameSize: Int; var maxFrameSize: Int; var firstBadOffset: Int?; var frameOffsets: [Int]?; var isClean: Bool }`
  - `public enum FlacFrameScanner { static func scan(fileAt url: URL, collectOffsets: Bool = false, progress: ((Double) -> Void)? = nil) throws -> FrameScanReport; static func scan(_ buf: UnsafeRawBufferPointer, audioOffset: Int, streamInfo: StreamInfo, collectOffsets: Bool, progress: ((Double) -> Void)?) -> FrameScanReport }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/FlacKitTests/FlacFrameScannerTests.swift`:

```swift
import Foundation
import Testing
@testable import FlacKit
import TagKit

@Suite struct FlacFrameScannerTests {
    @Test(arguments: [16, 24])
    func cleanFileCountsEverySample(bits: Int) throws {
        let (url, pcm) = try AudioFixture.makeFLAC(seconds: 2.5, bits: bits)
        let report = try FlacFrameScanner.scan(fileAt: url, collectOffsets: true)
        #expect(report.isClean)
        #expect(report.samples == UInt64(pcm.count / (2 * bits / 8)))
        #expect(report.frames == report.frameOffsets?.count)
        #expect(report.frames > 1)
        #expect(report.minFrameSize > 0 && report.maxFrameSize >= report.minFrameSize)
    }

    @Test func detectsSingleFlippedByte() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2.5)
        let clean = try FlacFrameScanner.scan(fileAt: url, collectOffsets: true)
        var bytes = [UInt8](try Data(contentsOf: url))
        let target = clean.frameOffsets![clean.frames / 2] + 40
        bytes[target] ^= 0x01
        try Data(bytes).write(to: url)
        let report = try FlacFrameScanner.scan(fileAt: url)
        #expect(!report.isClean)
        #expect(report.firstBadOffset == clean.frameOffsets![clean.frames / 2])
    }

    @Test func detectsTruncation() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2.5)
        let bytes = [UInt8](try Data(contentsOf: url))
        try Data(bytes.dropLast(500)).write(to: url)
        #expect(!(try FlacFrameScanner.scan(fileAt: url).isClean))
    }

    @Test func reportsMonotonicProgress() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 4)
        let box = ProgressBox()
        _ = try FlacFrameScanner.scan(fileAt: url) { box.values.append($0) }
        #expect(!box.values.isEmpty)
        #expect(box.values == box.values.sorted())
        #expect(box.values.last == 1.0)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter FlacFrameScannerTests`
Expected: FAIL de compilación — `cannot find 'FlacFrameScanner' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/FlacKit/FlacFrameScanner.swift`:

```swift
import Darwin
public import Foundation
public import TagKit

public struct FrameScanReport: Equatable, Sendable, Codable {
    public var frames = 0
    public var samples: UInt64 = 0
    public var minFrameSize = Int.max
    public var maxFrameSize = 0
    /// Offset of the first frame whose header or CRC-16 is invalid; nil when every frame verified.
    public var firstBadOffset: Int?
    /// Frame start offsets, only when requested (tests, DASH fixture building).
    public var frameOffsets: [Int]?

    public var isClean: Bool { firstBadOffset == nil && frames > 0 }
}

/// Walks every FLAC frame without decoding: a frame ends where the next valid header begins AND the
/// CRC-16 of the bytes in between matches. Corruption fails fast (bounded search window per frame).
public enum FlacFrameScanner {
    public static func scan(fileAt url: URL, collectOffsets: Bool = false,
                            progress: ((Double) -> Void)? = nil) throws -> FrameScanReport {
        let header = try FlacMetadataIO.read(url)
        let streamInfo = try header.streamInfo()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return data.withUnsafeBytes {
            scan($0, audioOffset: header.audioOffset, streamInfo: streamInfo, collectOffsets: collectOffsets, progress: progress)
        }
    }

    public static func scan(_ buf: UnsafeRawBufferPointer, audioOffset: Int, streamInfo: StreamInfo,
                            collectOffsets: Bool, progress: ((Double) -> Void)?) -> FrameScanReport {
        var report = FrameScanReport()
        if collectOffsets { report.frameOffsets = [] }
        let n = buf.count
        let maxBlock = Int(streamInfo.maxBlockSize)
        // Upper bound for one frame: verbatim subframes plus generous header/padding slack.
        let maxFrameBytes = streamInfo.maxFrameSize > 0
            ? Int(streamInfo.maxFrameSize) + 16
            : max(maxBlock, 4096) * Int(streamInfo.channels) * ((Int(streamInfo.bitsPerSample) + 7) / 8) + 1024
        guard let base = buf.baseAddress,
              var current = FrameHeaderParser.parse(buf, at: audioOffset, maxBlockSize: maxBlock)
        else {
            report.firstBadOffset = audioOffset
            report.minFrameSize = 0
            return report
        }

        var start = audioOffset
        var lastReport = 0
        func record(_ end: Int, _ header: FrameHeader) {
            let size = end - start
            report.frames += 1
            report.samples += UInt64(header.blockSize)
            report.minFrameSize = min(report.minFrameSize, size)
            report.maxFrameSize = max(report.maxFrameSize, size)
            report.frameOffsets?.append(start)
        }
        func storedCRC(at end: Int) -> UInt16 { UInt16(buf[end - 2]) << 8 | UInt16(buf[end - 1]) }
        func crcMatches(until end: Int) -> Bool {
            end - start >= current.headerLength + 2
                && CRC.crc16(UnsafeRawBufferPointer(rebasing: buf[start..<(end - 2)])) == storedCRC(at: end)
        }

        while true {
            let limit = min(n - 1, start + maxFrameBytes)
            var i = start + current.headerLength
            var next: (offset: Int, header: FrameHeader)?
            while i < limit, let hit = memchr(base + i, 0xFF, limit - i) {
                let j = base.distance(to: UnsafeRawPointer(hit))
                if buf[j + 1] & 0xFE == 0xF8,
                   let h = FrameHeaderParser.parse(buf, at: j, maxBlockSize: maxBlock),
                   crcMatches(until: j) {
                    next = (j, h)
                    break
                }
                i = j + 1
            }

            if let next {
                record(next.offset, current)
                start = next.offset
                current = next.header
                if let progress, start - lastReport >= 1 << 20 {
                    progress(Double(start) / Double(n))
                    lastReport = start
                }
                continue
            }
            if n - start <= maxFrameBytes, crcMatches(until: n) {
                record(n, current)
            } else {
                report.firstBadOffset = start
            }
            break
        }
        if report.frames == 0 { report.minFrameSize = 0 }
        progress?(1)
        return report
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter FlacFrameScannerTests`
Expected: 5 PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(flackit): verify every FLAC frame CRC over a memory-mapped file"
```

---

### Task 4: Cajas MP4 y demux fMP4 → frames FLAC

**Files:**
- Create: `Packages/AetherKit/Sources/FlacKit/MP4.swift`
- Create: `Packages/AetherKit/Sources/FlacKit/FMP4Flac.swift`
- Create: `Packages/AetherKit/Tests/FlacKitTests/MP4Fixture.swift`
- Test: `Packages/AetherKit/Tests/FlacKitTests/FMP4FlacTests.swift`

**Interfaces:**
- Produces:
  - `public struct MP4Box: Equatable, Sendable { let type: String; let start: Int; let payload: Range<Int> }`
  - `public enum MP4Error: Error, Equatable { case truncated; case missing(String); case segmentSizeMismatch(expected: Int, actual: Int); case unsupported(String) }`
  - `public enum MP4 { static func children(of: [UInt8], in: Range<Int>) throws -> [MP4Box]; static func find(_ path: [String], in: [UInt8]) throws -> MP4Box? }`
  - `public struct FlacTrackConfig: Equatable, Sendable { var streamInfo: StreamInfo; var metadataBlocks: [FlacBlock] }`
  - `public struct MediaSegment: Equatable, Sendable { var frameRanges: [Range<Int>]; var samples: UInt64; var sampleCount: Int; var byteCount: Int }`
  - `public enum FMP4Flac { static func parseInit(_: [UInt8]) throws -> FlacTrackConfig; static func parseMediaSegment(_: [UInt8]) throws -> MediaSegment }`
  - (tests) `enum MP4Fixture { static func initSegment(streamInfo:) -> [UInt8]; static func mediaSegment(frames: [[UInt8]], duration: UInt32 = 4096, sizeOverride: Int? = nil) -> [UInt8] }`

- [ ] **Step 1: Fixture sintético (estructura idéntica a la de Tidal, §2.6–2.7)**

`Packages/AetherKit/Tests/FlacKitTests/MP4Fixture.swift`:

```swift
import TagKit

enum MP4Fixture {
    static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(8 + payload.count) + Array(type.utf8) + payload }

    static func initSegment(streamInfo: StreamInfo) -> [UInt8] {
        let dfLa = box("dfLa", [0, 0, 0, 0] + [0x80, 0, 0, 34] + streamInfo.payload)
        let sampleEntry = box("fLaC", [UInt8](repeating: 0, count: 28) + dfLa)
        let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + sampleEntry)
        let moov = box("moov", box("mvhd", [UInt8](repeating: 0, count: 100))
            + box("trak", box("tkhd", [UInt8](repeating: 0, count: 84))
                + box("mdia", box("mdhd", [UInt8](repeating: 0, count: 24))
                    + box("minf", box("stbl", stsd)))))
        return box("ftyp", Array("iso6".utf8) + [0, 0, 0, 0]) + moov
    }

    /// tfhd flags 0x2002A (default duration) + trun flags 0x201 (data offset + sizes), like Tidal.
    static func mediaSegment(frames: [[UInt8]], duration: UInt32 = 4096, sizeOverride: Int? = nil) -> [UInt8] {
        let tfhd = box("tfhd", [0x00, 0x02, 0x00, 0x2A] + be32(1) + be32(1) + be32(Int(duration)) + be32(0))
        var trun = [0x00, 0x00, 0x02, 0x01] + be32(frames.count) + be32(0)
        for (i, f) in frames.enumerated() { trun += be32(i == 0 ? (sizeOverride ?? f.count) : f.count) }
        let moof = box("moof", box("mfhd", [0, 0, 0, 0] + be32(1)) + box("traf", tfhd + box("tfdt", [UInt8](repeating: 0, count: 12)) + box("trun", trun)))
        return box("styp", Array("msdh".utf8)) + moof + box("mdat", frames.flatMap { $0 })
    }
}
```

- [ ] **Step 2: Pruebas que fallan**

`Packages/AetherKit/Tests/FlacKitTests/FMP4FlacTests.swift`:

```swift
import Testing
@testable import FlacKit
import TagKit

@Suite struct FMP4FlacTests {
    static let si = StreamInfo(minBlockSize: 4096, maxBlockSize: 4096, minFrameSize: 0, maxFrameSize: 0,
                               sampleRate: 44_100, channels: 2, bitsPerSample: 24, totalSamples: 10_418_594,
                               md5: Array(repeating: 0xEE, count: 16))

    @Test func findsNestedBoxesIncludingSampleEntryChildren() throws {
        let bytes = MP4Fixture.initSegment(streamInfo: Self.si)
        let dfLa = try #require(try MP4.find(["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"], in: bytes))
        #expect(dfLa.payload.count == 4 + 4 + 34)
    }

    @Test func parsesLargeSizeBoxes() throws {
        let payload: [UInt8] = [1, 2, 3]
        let bytes = MP4Fixture.be32(1) + Array("free".utf8) + [0, 0, 0, 0, 0, 0, 0, 19] + payload
        let boxes = try MP4.children(of: bytes, in: 0..<bytes.count)
        #expect(boxes == [MP4Box(type: "free", start: 0, payload: 16..<19)])
    }

    @Test func truncatedBoxThrows() {
        let bytes = MP4Fixture.be32(50) + Array("moov".utf8)
        #expect(throws: MP4Error.truncated) { try MP4.children(of: bytes, in: 0..<bytes.count) }
    }

    @Test func initYieldsStreamInfo() throws {
        let config = try FMP4Flac.parseInit(MP4Fixture.initSegment(streamInfo: Self.si))
        #expect(config.streamInfo == Self.si)
        #expect(config.metadataBlocks == [Self.si.block])
    }

    @Test func mediaSegmentYieldsFrameBytesAndSamples() throws {
        let frames: [[UInt8]] = [[0xFF, 0xF8, 1, 2], [0xFF, 0xF8, 3], [0xFF, 0xF8, 4, 5, 6]]
        let segment = MP4Fixture.mediaSegment(frames: frames)
        let parsed = try FMP4Flac.parseMediaSegment(segment)
        #expect(parsed.sampleCount == 3)
        #expect(parsed.samples == 3 * 4096)
        #expect(parsed.byteCount == 10)
        #expect(parsed.frameRanges.flatMap { Array(segment[$0]) } == frames.flatMap { $0 })
    }

    @Test func sizeMismatchIsAnError() {
        let segment = MP4Fixture.mediaSegment(frames: [[0xFF, 0xF8, 1, 2]], sizeOverride: 9)
        #expect(throws: MP4Error.segmentSizeMismatch(expected: 9, actual: 4)) { try FMP4Flac.parseMediaSegment(segment) }
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter FMP4FlacTests`
Expected: FAIL de compilación — `cannot find 'MP4' in scope`.

- [ ] **Step 3: Implementar cajas MP4**

`Packages/AetherKit/Sources/FlacKit/MP4.swift`:

```swift
import ByteKit

public struct MP4Box: Equatable, Sendable {
    public let type: String
    public let start: Int
    public let payload: Range<Int>

    public init(type: String, start: Int, payload: Range<Int>) {
        self.type = type
        self.start = start
        self.payload = payload
    }
}

public enum MP4Error: Error, Equatable, Sendable {
    case truncated
    case missing(String)
    case segmentSizeMismatch(expected: Int, actual: Int)
    case unsupported(String)
}

public enum MP4 {
    /// Where children start inside a box's payload (full boxes / sample entries).
    private static let childOffset: [String: Int] = ["stsd": 8, "fLaC": 28]

    public static func children(of bytes: [UInt8], in range: Range<Int>) throws -> [MP4Box] {
        var boxes: [MP4Box] = []
        var o = range.lowerBound
        while o + 8 <= range.upperBound {
            var r = ByteReader(bytes)
            try r.seek(to: o)
            var size = Int(try r.u32BE())
            let type = try r.ascii(4)
            var header = 8
            if size == 1 {
                size = Int(try r.u64BE())
                header = 16
            } else if size == 0 {
                size = range.upperBound - o
            }
            guard size >= header, o + size <= range.upperBound else { throw MP4Error.truncated }
            boxes.append(MP4Box(type: type, start: o, payload: (o + header)..<(o + size)))
            o += size
        }
        return boxes
    }

    public static func find(_ path: [String], in bytes: [UInt8]) throws -> MP4Box? {
        var range = 0..<bytes.count
        for (depth, type) in path.enumerated() {
            guard let box = try children(of: bytes, in: range).first(where: { $0.type == type }) else { return nil }
            if depth == path.count - 1 { return box }
            range = (box.payload.lowerBound + (childOffset[type] ?? 0))..<box.payload.upperBound
        }
        return nil
    }
}
```

- [ ] **Step 4: Implementar demux FLAC**

`Packages/AetherKit/Sources/FlacKit/FMP4Flac.swift`:

```swift
import ByteKit
public import TagKit

public struct FlacTrackConfig: Equatable, Sendable {
    public var streamInfo: StreamInfo
    /// Metadata blocks exactly as carried in `dfLa` (STREAMINFO first).
    public var metadataBlocks: [FlacBlock]
}

public struct MediaSegment: Equatable, Sendable {
    /// Byte ranges (into the segment) holding raw FLAC frames, in order.
    public var frameRanges: [Range<Int>]
    /// Sum of sample durations in timescale units (== PCM frames when timescale == sample rate).
    public var samples: UInt64
    public var sampleCount: Int
    public var byteCount: Int
}

public enum FMP4Flac {
    public static func parseInit(_ bytes: [UInt8]) throws -> FlacTrackConfig {
        guard let dfLa = try MP4.find(["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"], in: bytes) else {
            throw MP4Error.missing("dfLa")
        }
        let blocks = Array(bytes[(dfLa.payload.lowerBound + 4)..<dfLa.payload.upperBound])
        let header = try FlacMetadataIO.parse(Array("fLaC".utf8) + blocks)
        return FlacTrackConfig(streamInfo: try header.streamInfo(), metadataBlocks: header.blocks)
    }

    public static func parseMediaSegment(_ bytes: [UInt8]) throws -> MediaSegment {
        var result = MediaSegment(frameRanges: [], samples: 0, sampleCount: 0, byteCount: 0)
        var pending: (sizes: Int?, samples: UInt64, count: Int)?
        for box in try MP4.children(of: bytes, in: 0..<bytes.count) {
            switch box.type {
            case "moof":
                pending = try parseMoof(bytes, box)
            case "mdat":
                guard let fragment = pending else { throw MP4Error.missing("moof") }
                if let expected = fragment.sizes, expected != box.payload.count {
                    throw MP4Error.segmentSizeMismatch(expected: expected, actual: box.payload.count)
                }
                result.frameRanges.append(box.payload)
                result.samples += fragment.samples
                result.sampleCount += fragment.count
                result.byteCount += box.payload.count
                pending = nil
            default:
                continue
            }
        }
        guard !result.frameRanges.isEmpty else { throw MP4Error.missing("mdat") }
        return result
    }

    private static func parseMoof(_ bytes: [UInt8], _ moof: MP4Box) throws -> (sizes: Int?, samples: UInt64, count: Int) {
        var totalSize: Int? = 0
        var totalSamples: UInt64 = 0
        var totalCount = 0
        for traf in try MP4.children(of: bytes, in: moof.payload) where traf.type == "traf" {
            var defaultDuration: UInt32?
            var defaultSize: UInt32?
            for child in try MP4.children(of: bytes, in: traf.payload) {
                var r = ByteReader(Array(bytes[child.payload]))
                switch child.type {
                case "tfhd":
                    let flags = try r.u32BE() & 0xFF_FFFF
                    try r.skip(4)
                    if flags & 0x01 != 0 { try r.skip(8) }
                    if flags & 0x02 != 0 { try r.skip(4) }
                    if flags & 0x08 != 0 { defaultDuration = try r.u32BE() }
                    if flags & 0x10 != 0 { defaultSize = try r.u32BE() }
                case "trun":
                    let flags = try r.u32BE() & 0xFF_FFFF
                    let count = Int(try r.u32BE())
                    if flags & 0x001 != 0 { try r.skip(4) }
                    if flags & 0x004 != 0 { try r.skip(4) }
                    for _ in 0..<count {
                        let duration: UInt32? = try flags & 0x100 != 0 ? r.u32BE() : defaultDuration
                        let size: UInt32? = try flags & 0x200 != 0 ? r.u32BE() : defaultSize
                        if flags & 0x400 != 0 { try r.skip(4) }
                        if flags & 0x800 != 0 { try r.skip(4) }
                        guard let duration else { throw MP4Error.unsupported("sample duration from trex") }
                        totalSamples += UInt64(duration)
                        if let size, let running = totalSize { totalSize = running + Int(size) } else { totalSize = nil }
                    }
                    totalCount += count
                default:
                    continue
                }
            }
        }
        return (totalSize, totalSamples, totalCount)
    }
}
```

- [ ] **Step 5: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter FMP4FlacTests`
Expected: 6 PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(flackit): demux FLAC frames from fragmented MP4 DASH segments"
```

---

### Task 5: `FlacAssembler` (escritura incremental con reanudación)

**Files:**
- Create: `Packages/AetherKit/Sources/FlacKit/FlacAssembler.swift`
- Test: `Packages/AetherKit/Tests/FlacKitTests/FlacAssemblerTests.swift`

**Interfaces:**
- Consumes: `FMP4Flac.parseMediaSegment`, `FlacMetadataIO.serialize`.
- Produces:
  - `public struct AssemblerCheckpoint: Codable, Equatable, Sendable { var validLength: Int; var samplesWritten: UInt64; var segmentsWritten: Int }`
  - `public final class FlacAssembler` con `init(partURL: URL, headerBlocks: [FlacBlock]) throws`, `init(resuming partURL: URL, from checkpoint: AssemblerCheckpoint) throws`, `func append(segment: [UInt8]) throws -> MediaSegment`, `var checkpoint: AssemblerCheckpoint`, `func finish() throws`, `let partURL: URL`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/FlacKitTests/FlacAssemblerTests.swift`:

```swift
import Foundation
import Testing
@testable import FlacKit
import TagKit

@Suite struct FlacAssemblerTests {
    private let header = [FMP4FlacTests.si.block, FlacBlock.padding(64)]
    private let seg1 = MP4Fixture.mediaSegment(frames: [[0xFF, 0xF8, 1], [0xFF, 0xF8, 2]])
    private let seg2 = MP4Fixture.mediaSegment(frames: [[0xFF, 0xF8, 3, 3]])

    private func partURL() -> URL { FileManager.default.temporaryDirectory.appending(path: ".a-\(UUID().uuidString).aether-part") }

    @Test func writesHeaderThenFramesInOrder() throws {
        let url = partURL()
        let assembler = try FlacAssembler(partURL: url, headerBlocks: header)
        _ = try assembler.append(segment: seg1)
        _ = try assembler.append(segment: seg2)
        #expect(assembler.checkpoint.samplesWritten == 3 * 4096)
        #expect(assembler.checkpoint.segmentsWritten == 2)
        try assembler.finish()
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(bytes == (try FlacMetadataIO.serialize(header)) + [0xFF, 0xF8, 1, 0xFF, 0xF8, 2, 0xFF, 0xF8, 3, 3])
    }

    @Test func resumesFromCheckpointDiscardingPartialTail() throws {
        let url = partURL()
        let first = try FlacAssembler(partURL: url, headerBlocks: header)
        _ = try first.append(segment: seg1)
        let checkpoint = first.checkpoint
        _ = try first.append(segment: seg2)   // simulate a crash after a partial write…
        try first.finish()
        let handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: [0xDE, 0xAD])   // …with garbage past the checkpoint
        try handle.close()

        let resumed = try FlacAssembler(resuming: url, from: checkpoint)
        _ = try resumed.append(segment: seg2)
        try resumed.finish()
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(bytes == (try FlacMetadataIO.serialize(header)) + [0xFF, 0xF8, 1, 0xFF, 0xF8, 2, 0xFF, 0xF8, 3, 3])
        #expect(resumed.checkpoint.segmentsWritten == 2)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter FlacAssemblerTests`
Expected: FAIL de compilación — `cannot find 'FlacAssembler' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/FlacKit/FlacAssembler.swift`:

```swift
public import Foundation
public import TagKit

public struct AssemblerCheckpoint: Codable, Equatable, Sendable {
    public var validLength: Int
    public var samplesWritten: UInt64
    public var segmentsWritten: Int
}

/// Streams a native FLAC to disk: complete metadata header first (tags + artwork + padding), then the raw
/// frames of each DASH segment as it arrives. Memory use is one segment at a time.
/// Not thread-safe: owned by a single download task.
public final class FlacAssembler {
    public let partURL: URL
    private let handle: FileHandle
    public private(set) var checkpoint: AssemblerCheckpoint

    public init(partURL: URL, headerBlocks: [FlacBlock]) throws {
        self.partURL = partURL
        let header = try FlacMetadataIO.serialize(headerBlocks)
        guard FileManager.default.createFile(atPath: partURL.path, contents: Data(header)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: partURL)
        try handle.seekToEnd()
        checkpoint = AssemblerCheckpoint(validLength: header.count, samplesWritten: 0, segmentsWritten: 0)
    }

    public init(resuming partURL: URL, from checkpoint: AssemblerCheckpoint) throws {
        self.partURL = partURL
        handle = try FileHandle(forWritingTo: partURL)
        try handle.truncate(atOffset: UInt64(checkpoint.validLength))
        try handle.seekToEnd()
        self.checkpoint = checkpoint
    }

    @discardableResult
    public func append(segment bytes: [UInt8]) throws -> MediaSegment {
        let parsed = try FMP4Flac.parseMediaSegment(bytes)
        for range in parsed.frameRanges { try handle.write(contentsOf: bytes[range]) }
        checkpoint.validLength += parsed.byteCount
        checkpoint.samplesWritten += parsed.samples
        checkpoint.segmentsWritten += 1
        return parsed
    }

    public func finish() throws {
        try handle.synchronize()
        try handle.close()
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter FlacAssemblerTests`
Expected: 2 PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(flackit): stream DASH segments into a resumable FLAC part file"
```

---

### Task 6: `IntegrityVerifier` y prueba de extremo a extremo DASH → FLAC verificado

**Files:**
- Create: `Packages/AetherKit/Sources/FlacKit/IntegrityVerifier.swift`
- Test: `Packages/AetherKit/Tests/FlacKitTests/IntegrityVerifierTests.swift`

**Interfaces:**
- Consumes: `FlacFrameScanner`, `PCMDigest`, `FlacMetadataIO`, `StreamInfo`.
- Produces:
  - `public struct IntegrityReport: Equatable, Sendable, Codable` con `enum Verdict: String { verified, verifiedNoReference, failed }`, `verdict`, `frames`, `samples`, `expectedSamples: UInt64?`, `md5Expected: String?`, `md5Actual: String?`, `failure: String?`, `shortMD5: String`, `isPass: Bool`
  - `public enum IntegrityVerifier { static func verify(flacAt url: URL, expectedSamples: UInt64? = nil, progress: ((Double) -> Void)? = nil) throws -> IntegrityReport; static let verifiedFieldKey = "AETHER_VERIFIED"; static func verifiedFieldValue(_ report: IntegrityReport, at date: Date) -> String }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/FlacKitTests/IntegrityVerifierTests.swift`:

```swift
import CryptoKit
import Foundation
import Testing
@testable import FlacKit
import TagKit

@Suite struct IntegrityVerifierTests {
    /// Writes the reference MD5 (of the PCM we generated) into STREAMINFO, like Tidal's dfLa provides.
    private func sealedFixture(bits: Int = 24) throws -> (URL, [UInt8]) {
        let (url, pcm) = try AudioFixture.makeFLAC(seconds: 3, bits: bits)
        var header = try FlacMetadataIO.read(url)
        var si = try header.streamInfo()
        si.md5 = Array(Insecure.MD5.hash(data: pcm))
        header.blocks[0] = si.block
        try FlacMetadataIO.write(header.blocks, to: url)
        return (url, pcm)
    }

    @Test func verifiedWhenMD5MatchesSource() throws {
        let (url, pcm) = try sealedFixture()
        let report = try IntegrityVerifier.verify(flacAt: url, expectedSamples: UInt64(pcm.count / 6))
        #expect(report.verdict == .verified)
        #expect(report.isPass)
        #expect(report.md5Actual == report.md5Expected)
        #expect(report.failure == nil)
    }

    @Test func failsOnWrongReferenceMD5() throws {
        let (url, _) = try sealedFixture()
        var header = try FlacMetadataIO.read(url)
        var si = try header.streamInfo()
        si.md5[0] ^= 0xFF
        header.blocks[0] = si.block
        try FlacMetadataIO.write(header.blocks, to: url)
        let report = try IntegrityVerifier.verify(flacAt: url)
        #expect(report.verdict == .failed)
        #expect(report.failure == "MD5 no coincide con la fuente")
    }

    @Test func failsOnSampleCountMismatchBeforeDecoding() throws {
        let (url, pcm) = try sealedFixture()
        let report = try IntegrityVerifier.verify(flacAt: url, expectedSamples: UInt64(pcm.count / 6) + 1)
        #expect(report.verdict == .failed)
        #expect(report.md5Actual == nil)
        #expect(report.failure?.hasPrefix("Muestras") == true)
    }

    @Test func noReferenceWhenStreamInfoMD5IsZero() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1)
        var header = try FlacMetadataIO.read(url)
        var si = try header.streamInfo()
        si.md5 = Array(repeating: 0, count: 16)
        header.blocks[0] = si.block
        try FlacMetadataIO.write(header.blocks, to: url)
        #expect(try IntegrityVerifier.verify(flacAt: url).verdict == .verifiedNoReference)
    }

    @Test func verifiedFieldValueFormat() {
        let report = IntegrityReport(verdict: .verified, frames: 1, samples: 1, expectedSamples: nil,
                                     md5Expected: "ab", md5Actual: "ab", failure: nil)
        let value = IntegrityVerifier.verifiedFieldValue(report, at: Date(timeIntervalSince1970: 0))
        #expect(value == "md5:ab;1970-01-01T00:00:00Z")
    }

    /// Full offline rehearsal of Harvester's path: split a real FLAC into DASH-like segments,
    /// reassemble through FMP4Flac + FlacAssembler, then verify against the source MD5.
    @Test func dashRoundTripIsBitPerfect() throws {
        let (source, pcm) = try sealedFixture()
        let sourceBytes = [UInt8](try Data(contentsOf: source))
        let header = try FlacMetadataIO.read(source)
        let si = try header.streamInfo()
        let scan = try FlacFrameScanner.scan(fileAt: source, collectOffsets: true)
        let offsets = scan.frameOffsets! + [sourceBytes.count]
        let frames = (0..<scan.frames).map { Array(sourceBytes[offsets[$0]..<offsets[$0 + 1]]) }

        let config = try FMP4Flac.parseInit(MP4Fixture.initSegment(streamInfo: si))
        let part = FileManager.default.temporaryDirectory.appending(path: ".e2e-\(UUID().uuidString).aether-part")
        let assembler = try FlacAssembler(partURL: part, headerBlocks: config.metadataBlocks + [.padding(8192)])
        let block = UInt32(si.maxBlockSize)
        let tail = UInt32(si.totalSamples - UInt64(frames.count - 1) * UInt64(block))
        // Segments of 43 frames like Tidal; the stream's last frame is shorter, so it gets its own fragment.
        let body = Array(frames.dropLast())
        var start = 0
        while start < body.count {
            let chunk = Array(body[start..<min(start + 43, body.count)])
            try assembler.append(segment: MP4Fixture.mediaSegment(frames: chunk, duration: block))
            start += 43
        }
        try assembler.append(segment: MP4Fixture.mediaSegment(frames: [frames.last!], duration: tail))
        #expect(assembler.checkpoint.samplesWritten == si.totalSamples)
        try assembler.finish()

        let report = try IntegrityVerifier.verify(flacAt: part, expectedSamples: UInt64(pcm.count / 6))
        #expect(report.verdict == .verified)
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter IntegrityVerifierTests`
Expected: FAIL de compilación — `cannot find 'IntegrityVerifier' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/FlacKit/IntegrityVerifier.swift`:

```swift
public import Foundation
import TagKit

public struct IntegrityReport: Equatable, Sendable, Codable {
    public enum Verdict: String, Codable, Sendable {
        /// Every frame CRC valid, sample counts agree, decoded PCM MD5 == source MD5.
        case verified
        /// Structurally valid, but the file carries no reference MD5 to compare against.
        case verifiedNoReference
        case failed
    }

    public var verdict: Verdict
    public var frames: Int
    public var samples: UInt64
    public var expectedSamples: UInt64?
    public var md5Expected: String?
    public var md5Actual: String?
    public var failure: String?

    public init(verdict: Verdict, frames: Int, samples: UInt64, expectedSamples: UInt64?,
                md5Expected: String?, md5Actual: String?, failure: String?) {
        self.verdict = verdict
        self.frames = frames
        self.samples = samples
        self.expectedSamples = expectedSamples
        self.md5Expected = md5Expected
        self.md5Actual = md5Actual
        self.failure = failure
    }

    public var isPass: Bool { verdict != .failed }
    public var shortMD5: String {
        guard let md5 = md5Actual, md5.count >= 8 else { return "—" }
        return "\(md5.prefix(4))…\(md5.suffix(4))"
    }
}

public enum IntegrityVerifier {
    public static let verifiedFieldKey = "AETHER_VERIFIED"

    /// Cheap checks first (frame CRCs ≈ 10 % of the time, sample counts), PCM MD5 decode last (≈ 90 %).
    public static func verify(flacAt url: URL, expectedSamples: UInt64? = nil,
                              progress: ((Double) -> Void)? = nil) throws -> IntegrityReport {
        let streamInfo = try FlacMetadataIO.read(url).streamInfo()
        let scan = try FlacFrameScanner.scan(fileAt: url) { progress?($0 * 0.1) }
        var report = IntegrityReport(
            verdict: .failed, frames: scan.frames, samples: scan.samples, expectedSamples: expectedSamples,
            md5Expected: streamInfo.hasMD5 ? streamInfo.md5Hex : nil, md5Actual: nil, failure: nil)

        if let bad = scan.firstBadOffset {
            report.failure = "Frame inválido en el byte \(bad)"
            return report
        }
        if streamInfo.totalSamples != 0, scan.samples != streamInfo.totalSamples {
            report.failure = "Muestras: \(scan.samples) ≠ STREAMINFO \(streamInfo.totalSamples)"
            return report
        }
        if let expected = expectedSamples, scan.samples != expected {
            report.failure = "Muestras: \(scan.samples) ≠ esperado \(expected)"
            return report
        }

        let digest = try PCMDigest.md5(ofFileAt: url, bitsPerSample: Int(streamInfo.bitsPerSample),
                                       channels: Int(streamInfo.channels), totalFrames: scan.samples) {
            progress?(0.1 + $0 * 0.9)
        }
        report.md5Actual = digest.md5.map { String(format: "%02x", $0) }.joined()
        if digest.frames != scan.samples {
            report.failure = "Decodificadas \(digest.frames) ≠ \(scan.samples) muestras"
            return report
        }
        if streamInfo.hasMD5 {
            report.verdict = digest.md5 == streamInfo.md5 ? .verified : .failed
            if report.verdict == .failed { report.failure = "MD5 no coincide con la fuente" }
        } else {
            report.verdict = .verifiedNoReference
        }
        return report
    }

    /// Value stored in the `AETHER_VERIFIED` Vorbis field: `md5:<hex>;<ISO-8601 UTC>`.
    public static func verifiedFieldValue(_ report: IntegrityReport, at date: Date) -> String {
        let formatter = ISO8601DateFormatter()   // not Sendable: created per call, never shared
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .gmt
        return "md5:\(report.md5Actual ?? "");\(formatter.string(from: date))"
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter IntegrityVerifierTests`
Expected: 6 PASS, incluida `dashRoundTripIsBitPerfect`.

- [ ] **Step 4: Medir rendimiento (presupuesto §4)**

Run:

```bash
swift test --package-path Packages/AetherKit -c release --filter dashRoundTripIsBitPerfect
```

Y con el FLAC real del spike S1, añadir esta prueba opt-in a `IntegrityVerifierTests.swift` (se queda: solo corre si existe la variable de entorno):

```swift
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AETHER_SPIKE_FLAC"] != nil))
    func realTidalFileMeetsBudget() throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["AETHER_SPIKE_FLAC"]!)
        let clock = ContinuousClock()
        var report: IntegrityReport?
        let elapsed = try clock.measure { report = try IntegrityVerifier.verify(flacAt: url) }
        #expect(report?.verdict == .verified)
        #expect(elapsed < .milliseconds(1500))
    }
```

Run: `AETHER_SPIKE_FLAC="$PWD/Spikes/out/505935155_HI_RES_LOSSLESS.flac" swift test --package-path Packages/AetherKit -c release --filter realTidalFileMeetsBudget`
Expected: PASS. Anotar el tiempo en `docs/spikes.md`.

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit docs/spikes.md
git commit -m "feat(flackit): verify FLAC integrity against source MD5 end to end"
```
