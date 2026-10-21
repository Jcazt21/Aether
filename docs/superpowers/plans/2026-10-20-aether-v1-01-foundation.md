# Aether v1 · Plan 01 — Spikes, fundación y shell de la app

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolver los supuestos de riesgo con spikes, dejar el proyecto en Swift 6 con el paquete `AetherKit` enlazado y una app que arranca en oscuro con sidebar, rutas, comandos y Settings.

**Architecture:** Spikes desechables en `Spikes/` (no se enlazan a nada). Paquete SPM local en `Packages/AetherKit` con el primer módulo `ByteKit`. App SwiftUI con `Window` único, `NavigationSplitView`, `AppModel` dueño del estado y `Preferences` persistido en `UserDefaults`.

**Tech Stack:** Swift 6, SwiftUI (macOS 27), Swift Testing, Python 3 + `afconvert` (solo spikes).

**Spec:** `docs/superpowers/plans/2026-10-20-aether-v1-00-overview.md`

## Global Constraints

- macOS 27.0, Xcode 27, Swift 6, strict concurrency. App con aislamiento `MainActor` por defecto; paquete `nonisolated` por defecto.
- Cero dependencias de terceros en runtime.
- UI solo oscura; copy en español; nombres: Aether, Aether Core, Harvester, Cosmos.
- hifi-api por defecto `http://127.0.0.1:8000`; Master por defecto `~/Master`; entrada `Por clasificar`.
- Pruebas con Swift Testing; `swift test --package-path Packages/AetherKit`.
- Commits Conventional Commits en inglés.

Todas las rutas son relativas a la raíz del repo `~/Documents/Projects/Aether`.

---

### Task 0: Spikes de riesgo (S1–S4)

Los spikes responden preguntas; su código no se reutiliza. Resultado obligatorio: `docs/spikes.md` con un veredicto por spike. **Si S1 falla, detener la ejecución y replanificar** (todo Harvester depende de él).

**Files:**
- Create: `Spikes/s1_dash_to_flac.py`
- Create: `Spikes/s2_flac_packets.swift`
- Create: `docs/spikes.md`
- Modify: `.gitignore` (ignorar `Spikes/out/`)

- [ ] **Step 1: Preparar carpeta e ignorar salidas**

```bash
mkdir -p Spikes/out
printf '\nSpikes/out/\n' >> .gitignore
```

- [ ] **Step 2: Escribir S1 — DASH → FLAC nativo y comparación de MD5**

Pregunta: ¿concatenar los `mdat` tras `"fLaC"+bloques de dfLa` produce un FLAC que AudioToolbox decodifica y cuyo MD5 PCM coincide con el STREAMINFO de la fuente, en 16 y 24 bits?

`Spikes/s1_dash_to_flac.py`:

```python
#!/usr/bin/env python3
"""S1: rebuild a native FLAC from Tidal DASH segments and compare PCM MD5 with STREAMINFO.
Usage: python3 Spikes/s1_dash_to_flac.py <track_id> <HI_RES_LOSSLESS|LOSSLESS> [api]"""
import base64, hashlib, html, json, re, struct, subprocess, sys, urllib.request
from pathlib import Path

track_id, quality = sys.argv[1], sys.argv[2]
api = sys.argv[3] if len(sys.argv) > 3 else "http://127.0.0.1:8000"
out = Path(__file__).parent / "out"
out.mkdir(exist_ok=True)

def get(url):
    return urllib.request.urlopen(url, timeout=30).read()

info = json.loads(get(f"{api}/track/?id={track_id}&quality={quality}"))["data"]
print("playbackinfo:", {k: v for k, v in info.items() if k != "manifest"})
mpd = base64.b64decode(info["manifest"]).decode()
init_url = html.unescape(re.search(r'initialization="([^"]+)"', mpd).group(1))
media = html.unescape(re.search(r'media="([^"]+)"', mpd).group(1))
timeline = re.findall(r'<S d="(\d+)"(?: r="(\d+)")?/>', mpd)
durations = [int(d) for d, r in timeline for _ in range(int(r or 0) + 1)]
print("segments:", len(durations), "timeline samples:", sum(durations))

def find(b, path, off=0, end=None):
    end = len(b) if end is None else end
    while off + 8 <= end:
        size, typ = struct.unpack(">I4s", b[off:off + 8])
        typ = typ.decode("latin1")
        if typ == path[0]:
            if len(path) == 1:
                return off, size
            skip = {"stsd": 16, "fLaC": 36}.get(typ, 8)
            return find(b, path[1:], off + skip, off + size)
        off += size
    return None

init = get(init_url)
(out / "init.mp4").write_bytes(init)
o, s = find(init, ["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"])
blocks = init[o + 12:o + s]
si = blocks[4:38]
packed = int.from_bytes(si[10:18], "big")
rate, ch, bps = packed >> 44, ((packed >> 41) & 7) + 1, ((packed >> 36) & 31) + 1
total, md5 = packed & 0xFFFFFFFFF, si[18:34].hex()
print(f"STREAMINFO rate={rate} ch={ch} bps={bps} total={total} md5={md5}")

flac = bytearray(b"fLaC" + blocks)
for n in range(1, len(durations) + 1):
    seg = get(media.replace("$Number$", str(n)))
    if n == 1:
        (out / "seg1.m4s").write_bytes(seg)
    off = 0
    while off < len(seg):
        size, typ = struct.unpack(">I4s", seg[off:off + 8])
        if typ == b"mdat":
            flac += seg[off + 8:off + size]
        off += size
path = out / f"{track_id}_{quality}.flac"
path.write_bytes(flac)
print("wrote", path, len(flac), "bytes")

wav = out / f"{track_id}_{quality}.wav"
fmt = "LEI16" if bps == 16 else "LEI24"
subprocess.run(["afconvert", "-f", "WAVE", "-d", fmt, str(path), str(wav)], check=True)
w = wav.read_bytes()
off = 12
while off < len(w):
    cid, size = struct.unpack("<4sI", w[off:off + 8])
    if cid == b"data":
        pcm = w[off + 8:off + 8 + size]
        break
    off += 8 + size + (size & 1)
actual = hashlib.md5(pcm).hexdigest()
frames = len(pcm) // (ch * bps // 8)
print(f"decoded frames={frames} expected={total} md5={actual}")
print("S1 VERDICT:", "PASS" if actual == md5 and frames == total == sum(durations) else "FAIL")
```

- [ ] **Step 3: Ejecutar S1 en ambas calidades**

```bash
python3 Spikes/s1_dash_to_flac.py 505935155 HI_RES_LOSSLESS
python3 Spikes/s1_dash_to_flac.py 505935155 LOSSLESS
```

Expected: ambas terminan con `S1 VERDICT: PASS`. Si `afconvert` no abre el FLAC, o el MD5 difiere, anotar la salida completa en `docs/spikes.md` y **detenerse**.

- [ ] **Step 4: Escribir S2 — decodificación de paquetes FLAC con `AVAudioConverter`**

Pregunta: ¿podemos decodificar frames FLAC sueltos (sin archivo) para la preescucha en streaming? ¿Qué *magic cookie* acepta CoreAudio?

`Spikes/s2_flac_packets.swift`:

```swift
// S2: decode raw FLAC frames from a DASH media segment with AVAudioConverter.
// Usage: swift Spikes/s2_flac_packets.swift Spikes/out
import AVFoundation

let dir = URL(filePath: CommandLine.arguments[1])
let initBytes = [UInt8](try Data(contentsOf: dir.appending(path: "init.mp4")))
let segBytes = [UInt8](try Data(contentsOf: dir.appending(path: "seg1.m4s")))

func u32(_ d: [UInt8], _ o: Int) -> Int {
    Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
}

func find(_ d: [UInt8], _ path: [String], _ start: Int = 0, _ end: Int? = nil) -> (Int, Int)? {
    var o = start
    let e = end ?? d.count
    while o + 8 <= e {
        let size = u32(d, o)
        let type = String(decoding: d[(o + 4)..<(o + 8)], as: UTF8.self)
        if type == path[0] {
            if path.count == 1 { return (o, size) }
            let skip = ["stsd": 16, "fLaC": 36][type] ?? 8
            return find(d, Array(path.dropFirst()), o + skip, o + size)
        }
        o += size
    }
    return nil
}

let (dfo, dfs) = find(initBytes, ["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"])!
let blocks = Array(initBytes[(dfo + 12)..<(dfo + dfs)])
let streamInfo = Array(blocks[4..<38])
let packed = streamInfo[10..<18].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
let rate = Double(packed >> 44)
let channels = UInt32((packed >> 41) & 7) + 1
let bps = UInt32((packed >> 36) & 31) + 1

let (to, _) = find(segBytes, ["moof", "traf", "trun"])!
let flags = u32(segBytes, to + 8) & 0xFFFFFF
let count = u32(segBytes, to + 12)
var p = to + 16
if flags & 0x1 != 0 { p += 4 }
if flags & 0x4 != 0 { p += 4 }
var sizes: [Int] = []
for _ in 0..<count {
    if flags & 0x100 != 0 { p += 4 }
    sizes.append(u32(segBytes, p)); p += 4
    if flags & 0x400 != 0 { p += 4 }
    if flags & 0x800 != 0 { p += 4 }
}
let (mo, ms) = find(segBytes, ["mdat"])!
let payload = Array(segBytes[(mo + 8)..<(mo + ms)])
precondition(sizes.reduce(0, +) == payload.count, "trun sizes != mdat payload")

let candidates: [(String, [UInt8])] = [
    ("dfLa full box", Array(initBytes[dfo..<(dfo + dfs)])),
    ("dfLa payload (fullbox+blocks)", Array(initBytes[(dfo + 8)..<(dfo + dfs)])),
    ("fLaC + blocks", Array("fLaC".utf8) + blocks),
    ("blocks only", blocks),
]

for (name, cookie) in candidates {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatFLAC,
        mFormatFlags: bps == 16 ? 1 : (bps == 24 ? 3 : 4),
        mBytesPerPacket: 0, mFramesPerPacket: 4096, mBytesPerFrame: 0,
        mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
    guard let inFormat = AVAudioFormat(streamDescription: &asbd) else { print(name, "→ no input format"); continue }
    inFormat.magicCookie = Data(cookie)
    let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { print(name, "→ no converter"); continue }
    let compressed = AVAudioCompressedBuffer(format: inFormat, packetCapacity: AVAudioPacketCount(sizes.count), maximumPacketSize: sizes.max()!)
    payload.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
    var offset = 0
    for (i, size) in sizes.enumerated() {
        compressed.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
        offset += size
    }
    compressed.packetCount = AVAudioPacketCount(sizes.count)
    compressed.byteLength = UInt32(payload.count)
    let pcm = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(sizes.count * 4096))!
    var delivered = false
    var error: NSError?
    let status = converter.convert(to: pcm, error: &error) { _, outStatus in
        if delivered { outStatus.pointee = .endOfStream; return nil }
        delivered = true
        outStatus.pointee = .haveData
        return compressed
    }
    print("\(name) → status=\(status.rawValue) frames=\(pcm.frameLength) expected=\(sizes.count * 4096) error=\(String(describing: error))")
}
```

- [ ] **Step 5: Ejecutar S2**

Run: `swift Spikes/s2_flac_packets.swift Spikes/out`
Expected: al menos un candidato con `frames=` igual (o ±4096) a `expected=` y `error=nil`. Anotar **cuál** cookie funciona. Si ninguno, S2 = FAIL → la preescucha usará el plan B (descarga a caché) descrito en el plan 06.

- [ ] **Step 6: S3 — validación manual en rekordbox (Jean)**

Importar `Spikes/out/505935155_HI_RES_LOSSLESS.flac` en rekordbox y anotar en `docs/spikes.md`:
1. ¿Duración 3:56 correcta?
2. ¿Analiza BPM/beatgrid sin error?
3. ¿Exporta a USB y reproduce en el CDJ? Modelo de CDJ y si acepta 24 bit.
4. (Se completa en el plan 05, Task 8) ¿rekordbox lee títulos de un WAV con chunk `id3 `?

- [ ] **Step 7: S4 — codificador FLAC de AudioToolbox para fixtures**

```bash
python3 -c "
import math,struct,wave
w=wave.open('Spikes/out/sine.wav','wb');w.setnchannels(2);w.setsampwidth(2);w.setframerate(44100)
w.writeframes(b''.join(struct.pack('<hh',int(12000*math.sin(i/20)),int(-12000*math.sin(i/20))) for i in range(44100)))"
afconvert -f flac -d flac Spikes/out/sine.wav Spikes/out/sine.flac && xxd -l 64 Spikes/out/sine.flac
```

Expected: el archivo empieza con `664c 6143` (`fLaC`). Anotar si los bytes 26–41 del STREAMINFO (MD5) son ceros o no. Las pruebas del plan 03 calculan el MD5 esperado ellas mismas, así que ambos resultados son válidos; solo se documenta.

- [ ] **Step 8: Documentar veredictos**

`docs/spikes.md`:

```markdown
# Spikes Aether v1

| Spike | Pregunta | Veredicto | Notas |
|---|---|---|---|
| S1 | DASH→FLAC nativo, MD5 == STREAMINFO (16 y 24 bit) | PASS/FAIL | salida relevante |
| S2 | AVAudioConverter decodifica frames FLAC sueltos | PASS/FAIL | cookie que funciona: … |
| S3 | rekordbox/CDJ aceptan el FLAC producido | PASS/FAIL | modelo CDJ, límites |
| S4 | afconvert codifica FLAC; ¿MD5 en STREAMINFO? | PASS/FAIL | MD5 cero: sí/no |
```

- [ ] **Step 9: Commit**

```bash
git add Spikes/s1_dash_to_flac.py Spikes/s2_flac_packets.swift docs/spikes.md .gitignore
git commit -m "chore(spikes): validate DASH-to-FLAC rebuild, FLAC packet decoding and fixtures"
```

---

### Task 1: Proyecto en Swift 6, Info.plist y paquete `AetherKit`

**Files:**
- Modify: `Aether.xcodeproj/project.pbxproj` (SWIFT_VERSION, INFOPLIST_FILE, referencia al paquete local)
- Create: `Config/Aether-Info.plist`
- Create: `Packages/AetherKit/Package.swift`
- Create: `Packages/AetherKit/Sources/ByteKit/ByteKit.swift`
- Create: `Packages/AetherKit/Tests/ByteKitTests/SmokeTests.swift`

**Interfaces:**
- Produces: producto de librería `AetherKit` (umbrella de todos los módulos); módulo `ByteKit`.

- [ ] **Step 1: Subir a Swift 6**

```bash
sed -i '' 's/SWIFT_VERSION = 5.0;/SWIFT_VERSION = 6.0;/g' Aether.xcodeproj/project.pbxproj
grep -c "SWIFT_VERSION = 6.0;" Aether.xcodeproj/project.pbxproj
```

Expected: `6` (Debug/Release × app, tests, UI tests).

- [ ] **Step 2: Info.plist con red local**

`Config/Aether-Info.plist` (fuera de la carpeta sincronizada `Aether/` para que no se copie como recurso):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
</dict>
</plist>
```

```bash
perl -pi -e 's/^(\s*)PRODUCT_BUNDLE_IDENTIFIER = com\.jazar\.Aether;/$1INFOPLIST_FILE = Config\/Aether-Info.plist;\n$1PRODUCT_BUNDLE_IDENTIFIER = com.jazar.Aether;/' Aether.xcodeproj/project.pbxproj
grep -c "INFOPLIST_FILE = Config/Aether-Info.plist;" Aether.xcodeproj/project.pbxproj
```

Expected: `2` (Debug y Release del target de la app; los targets de test usan `com.jazar.AetherTests` y no coinciden).

- [ ] **Step 3: Crear el paquete**

`Packages/AetherKit/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "AetherKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AetherKit", targets: ["ByteKit"]),
    ],
    targets: [
        .target(name: "ByteKit", swiftSettings: settings),
        .testTarget(name: "ByteKitTests", dependencies: ["ByteKit"], swiftSettings: settings),
    ]
)
```

> Cada plan posterior **añade** sus targets a `targets:` y al array del producto `AetherKit`.

`Packages/AetherKit/Sources/ByteKit/ByteKit.swift`:

```swift
/// Binary reading/writing primitives shared by every AetherKit module.
public enum ByteKit {
    public static let version = "1.0.0"
}
```

`Packages/AetherKit/Tests/ByteKitTests/SmokeTests.swift`:

```swift
import Testing
@testable import ByteKit

@Test func packageBuilds() {
    #expect(ByteKit.version == "1.0.0")
}
```

- [ ] **Step 4: Probar el paquete**

Run: `swift test --package-path Packages/AetherKit`
Expected: `Test run with 1 test passed`.

- [ ] **Step 5: Enlazar el paquete a la app (manual, Jean, 1 minuto)**

En Xcode: *File › Add Package Dependencies… › Add Local…* → seleccionar `Packages/AetherKit` → en el diálogo, producto `AetherKit` al target **Aether**. Cerrar Xcode o guardar.

Verificación automatizable:

```bash
grep -c "XCLocalSwiftPackageReference" Aether.xcodeproj/project.pbxproj
```

Expected: `≥ 1`.

- [ ] **Step 6: Verificar que la app importa el módulo**

Añadir `import ByteKit` al principio de `Aether/AetherApp.swift` y compilar:

Run: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' build -quiet`
Expected: termina sin errores. (Quitar el `import` en la Task 4, cuando se reescriba el archivo.)

- [ ] **Step 7: Commit**

```bash
git add Aether.xcodeproj/project.pbxproj Config Packages Aether/AetherApp.swift
git commit -m "build: adopt Swift 6, add Info.plist with local networking and AetherKit package"
```

---

### Task 2: ByteKit — lector, escritor y reescritor de cabeceras

**Files:**
- Create: `Packages/AetherKit/Sources/ByteKit/ByteReader.swift`
- Create: `Packages/AetherKit/Sources/ByteKit/ByteWriter.swift`
- Create: `Packages/AetherKit/Sources/ByteKit/HeaderRegionRewriter.swift`
- Test: `Packages/AetherKit/Tests/ByteKitTests/ByteReaderTests.swift`
- Test: `Packages/AetherKit/Tests/ByteKitTests/HeaderRegionRewriterTests.swift`
- Delete: `Packages/AetherKit/Tests/ByteKitTests/SmokeTests.swift`

**Interfaces:**
- Produces:
  - `public enum ByteError: Error, Equatable { case outOfBounds(offset: Int, needed: Int); case invalid(String) }`
  - `public struct ByteReader` con `init(_ bytes: [UInt8])`, `init(_ data: Data)`, `offset: Int`, `remaining: Int`, `isAtEnd: Bool`, `peek() throws -> UInt8`, `u8()`, `u16BE()`, `u24BE()`, `u32BE()`, `u64BE()`, `u32LE()`, `u16LE()`, `syncsafe32()`, `bytes(_:) -> [UInt8]`, `ascii(_:) -> String`, `skip(_:)`, `seek(to:)`
  - `public struct ByteWriter` con `bytes: [UInt8]`, `u8/u16BE/u24BE/u32BE/u64BE/u16LE/u32LE/syncsafe32(_:)`, `append(_:)`, `ascii(_:)`
  - `public enum HeaderRegionRewriter { static func replace(fileAt: URL, oldLength: Int, with: [UInt8]) throws }`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/ByteKitTests/ByteReaderTests.swift`:

```swift
import Testing
@testable import ByteKit

@Suite struct ByteReaderTests {
    @Test func readsBigAndLittleEndianIntegers() throws {
        var r = ByteReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C])
        #expect(try r.u16BE() == 0x0102)
        #expect(try r.u24BE() == 0x030405)
        #expect(try r.u32LE() == 0x0908_0706)
        #expect(r.remaining == 3)
        #expect(try r.peek() == 0x0A)
        #expect(try r.u8() == 0x0A)
    }

    @Test func readsU64AndSyncsafe() throws {
        var r = ByteReader([0, 0, 0, 0, 0, 0, 1, 0, 0x00, 0x00, 0x02, 0x01])
        #expect(try r.u64BE() == 256)
        #expect(try r.syncsafe32() == 257)
    }

    @Test func throwsOutOfBounds() {
        var r = ByteReader([0x01])
        #expect(throws: ByteError.outOfBounds(offset: 0, needed: 2)) { try r.u16BE() }
    }

    @Test func asciiAndSeek() throws {
        var r = ByteReader(Array("fLaCxyz".utf8))
        #expect(try r.ascii(4) == "fLaC")
        try r.seek(to: 1)
        #expect(try r.ascii(3) == "LaC")
        #expect(throws: ByteError.self) { try r.seek(to: 99) }
    }

    @Test func writerRoundTrip() throws {
        var w = ByteWriter()
        w.u8(0xAB); w.u16BE(0x0102); w.u24BE(0x030405); w.u32BE(0x0607_0809)
        w.u64BE(0x0A0B_0C0D_0E0F_1011); w.u32LE(0x1213_1415); w.u16LE(0x1617)
        w.syncsafe32(0x0FFF_FFFF); w.ascii("ID3")
        var r = ByteReader(w.bytes)
        #expect(try r.u8() == 0xAB)
        #expect(try r.u16BE() == 0x0102)
        #expect(try r.u24BE() == 0x030405)
        #expect(try r.u32BE() == 0x0607_0809)
        #expect(try r.u64BE() == 0x0A0B_0C0D_0E0F_1011)
        #expect(try r.u32LE() == 0x1213_1415)
        #expect(try r.u16LE() == 0x1617)
        #expect(try r.syncsafe32() == 0x0FFF_FFFF)
        #expect(try r.ascii(3) == "ID3")
        #expect(r.isAtEnd)
    }
}
```

`Packages/AetherKit/Tests/ByteKitTests/HeaderRegionRewriterTests.swift`:

```swift
import Foundation
import Testing
@testable import ByteKit

@Suite struct HeaderRegionRewriterTests {
    private func temp(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hrr-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func sameLengthWritesInPlaceAndKeepsInode() throws {
        let url = try temp([1, 2, 3, 4, 9, 9, 9])
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        try HeaderRegionRewriter.replace(fileAt: url, oldLength: 4, with: [5, 6, 7, 8])
        #expect(try [UInt8](Data(contentsOf: url)) == [5, 6, 7, 8, 9, 9, 9])
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        #expect(inodeBefore == inodeAfter)
    }

    @Test func differentLengthRewritesTail() throws {
        let tail = [UInt8](repeating: 7, count: 3_000_000)
        let url = try temp([1, 2] + tail)
        try HeaderRegionRewriter.replace(fileAt: url, oldLength: 2, with: [3, 4, 5, 6])
        let result = try [UInt8](Data(contentsOf: url))
        #expect(Array(result.prefix(4)) == [3, 4, 5, 6])
        #expect(result.count == 4 + tail.count)
        #expect(result.last == 7)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".aether-tmp") }
        #expect(leftovers.isEmpty)
    }
}
```

```bash
rm Packages/AetherKit/Tests/ByteKitTests/SmokeTests.swift
```

- [ ] **Step 2: Verificar que fallan**

Run: `swift test --package-path Packages/AetherKit`
Expected: FAIL de compilación — `cannot find 'ByteReader' in scope`.

- [ ] **Step 3: Implementar**

`Packages/AetherKit/Sources/ByteKit/ByteReader.swift`:

```swift
public import Foundation

public enum ByteError: Error, Equatable, Sendable {
    case outOfBounds(offset: Int, needed: Int)
    case invalid(String)
}

/// Forward-only cursor over an immutable byte buffer. Value type; copying is cheap (CoW array).
public struct ByteReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init(_ data: Data) { self.bytes = [UInt8](data) }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { remaining == 0 }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else { throw ByteError.outOfBounds(offset: offset, needed: count) }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    public func peek() throws -> UInt8 {
        guard remaining >= 1 else { throw ByteError.outOfBounds(offset: offset, needed: 1) }
        return bytes[offset]
    }

    public mutating func u8() throws -> UInt8 { try take(1).first! }
    public mutating func u16BE() throws -> UInt16 { try take(2).reduce(0) { $0 << 8 | UInt16($1) } }
    public mutating func u24BE() throws -> UInt32 { try take(3).reduce(0) { $0 << 8 | UInt32($1) } }
    public mutating func u32BE() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    public mutating func u64BE() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    public mutating func u16LE() throws -> UInt16 { try take(2).reversed().reduce(0) { $0 << 8 | UInt16($1) } }
    public mutating func u32LE() throws -> UInt32 { try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }

    /// ID3v2 "syncsafe" integer: 4 bytes, 7 significant bits each.
    public mutating func syncsafe32() throws -> UInt32 { try take(4).reduce(0) { $0 << 7 | UInt32($1 & 0x7F) } }

    public mutating func bytes(_ count: Int) throws -> [UInt8] { Array(try take(count)) }

    public mutating func ascii(_ count: Int) throws -> String {
        String(decoding: try take(count), as: UTF8.self)
    }

    public mutating func skip(_ count: Int) throws { _ = try take(count) }

    public mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= bytes.count else {
            throw ByteError.outOfBounds(offset: newOffset, needed: 0)
        }
        offset = newOffset
    }
}
```

`Packages/AetherKit/Sources/ByteKit/ByteWriter.swift`:

```swift
/// Append-only byte buffer builder.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init(reservingCapacity capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16BE(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(truncatingIfNeeded: v)] }
    public mutating func u24BE(_ v: UInt32) {
        bytes += [UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }
    public mutating func u32BE(_ v: UInt32) {
        bytes += [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }
    public mutating func u64BE(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift))) }
    }
    public mutating func u16LE(_ v: UInt16) { bytes += [UInt8(truncatingIfNeeded: v), UInt8(v >> 8)] }
    public mutating func u32LE(_ v: UInt32) {
        bytes += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), UInt8(v >> 24)]
    }
    public mutating func syncsafe32(_ v: UInt32) {
        bytes += [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }
    public mutating func append(_ other: some Sequence<UInt8>) { bytes.append(contentsOf: other) }
    public mutating func ascii(_ s: String) { bytes.append(contentsOf: s.utf8) }
}
```

`Packages/AetherKit/Sources/ByteKit/HeaderRegionRewriter.swift`:

```swift
public import Foundation

/// Replaces the leading region `[0, oldLength)` of a file (a tag/metadata header) without loading the audio.
/// - Same length: overwrites in place (no copy, inode preserved — fastest path, used whenever padding allows).
/// - Different length: streams `newHeader + tail` into a sibling temp file in 1 MiB chunks and swaps it in atomically.
public enum HeaderRegionRewriter {
    public static func replace(fileAt url: URL, oldLength: Int, with newHeader: [UInt8]) throws {
        if newHeader.count == oldLength {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: newHeader)
            try handle.synchronize()
            return
        }

        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).aether-tmp")
        let fm = FileManager.default
        guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let output = try FileHandle(forWritingTo: temp)
            let input = try FileHandle(forReadingFrom: url)
            try output.write(contentsOf: newHeader)
            try input.seek(toOffset: UInt64(oldLength))
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
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

- [ ] **Step 4: Verificar que pasan**

Run: `swift test --package-path Packages/AetherKit`
Expected: 7 pruebas PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(bytekit): add byte reader/writer and in-place header region rewriter"
```

---

### Task 3: Sistema de diseño (tokens y componentes base)

**Files:**
- Create: `Aether/DesignSystem/Tokens.swift`
- Create: `Aether/DesignSystem/Readout.swift`
- Create: `Aether/DesignSystem/HairlineProgress.swift`
- Create: `Aether/DesignSystem/StatusGlyph.swift`

**Interfaces:**
- Produces:
  - `enum Tokens` con `canvas`, `surface`, `hairline`, `signal`, `fault` (`Color`), `Tokens.Space.{xxs,xs,s,m,l,xl,xxl}`, `Tokens.Motion.{enter,state,progress}`
  - `extension Font { static var readout: Font; static var readoutEmphasis: Font }`
  - `struct Readout: View` (`init(_ text: String, tone: Readout.Tone = .secondary)`), `enum Readout.Tone { primary, secondary, tertiary, signal, fault }`
  - `struct SectionLabel: View` (`init(_ title: LocalizedStringKey)`)
  - `struct HairlineProgress: View` (`init(transfer: Double, verify: Double, stage: HairlineProgress.Stage)`), `enum Stage { idle, transferring, verifying, verified, failed }`
  - `struct StatusGlyph: View` (`init(_ status: StatusGlyph.Status)`), `enum Status { queued, working, verifying, verified, failed, cancelled }`

- [ ] **Step 1: Tokens**

`Aether/DesignSystem/Tokens.swift`:

```swift
import AppKit
import SwiftUI

/// Aether design tokens. Dark-only app: values are tuned for darkAqua, with
/// Increase Contrast variants resolved dynamically by AppKit.
enum Tokens {
    static let canvas = Color(red: 11 / 255, green: 12 / 255, blue: 14 / 255)
    static let surface = Color(red: 18 / 255, green: 20 / 255, blue: 23 / 255)
    static let hairline = Color.adaptive(
        .white.withAlphaComponent(0.08),
        highContrast: .white.withAlphaComponent(0.16))
    /// Phosphor green: verified / bit-perfect. The only brand color.
    static let signal = Color.adaptive(
        NSColor(srgbRed: 0.424, green: 0.922, blue: 0.620, alpha: 1),
        highContrast: NSColor(srgbRed: 0.62, green: 1.0, blue: 0.76, alpha: 1))
    static let fault = Color.adaptive(
        NSColor(srgbRed: 1.0, green: 0.420, blue: 0.369, alpha: 1),
        highContrast: NSColor(srgbRed: 1.0, green: 0.60, blue: 0.55, alpha: 1))

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 32
    }

    enum Motion {
        /// Elements entering/leaving (occasional events only).
        static let enter = Animation.easeOut(duration: 0.22)
        /// State/color changes.
        static let state = Animation.easeOut(duration: 0.18)
        /// Progress fills: constant motion is linear.
        static let progress = Animation.linear(duration: 0.12)
    }
}

extension Color {
    static func adaptive(_ normal: NSColor, highContrast: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .accessibilityHighContrastDarkAqua])
            return match == .accessibilityHighContrastDarkAqua ? highContrast : normal
        })
    }
}

extension Font {
    /// Technical readouts: sample rates, sizes, hashes, speeds.
    static var readout: Font { .system(.caption, design: .monospaced).monospacedDigit() }
    static var readoutEmphasis: Font { .system(.callout, design: .monospaced).weight(.medium).monospacedDigit() }
}
```

- [ ] **Step 2: Readout y SectionLabel**

`Aether/DesignSystem/Readout.swift`:

```swift
import SwiftUI

struct Readout: View {
    enum Tone { case primary, secondary, tertiary, signal, fault }

    private let text: String
    private let tone: Tone

    init(_ text: String, tone: Tone = .secondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(verbatim: text)
            .font(.readout)
            .foregroundStyle(style)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var style: AnyShapeStyle {
        switch tone {
        case .primary: AnyShapeStyle(.primary)
        case .secondary: AnyShapeStyle(.secondary)
        case .tertiary: AnyShapeStyle(.tertiary)
        case .signal: AnyShapeStyle(Tokens.signal)
        case .fault: AnyShapeStyle(Tokens.fault)
        }
    }
}

struct SectionLabel: View {
    private let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        SectionLabel("Señal")
        Readout("FLAC · 24 bit · 44.1 kHz", tone: .primary)
        Readout("VERIFICADO · ee68…7a1f", tone: .signal)
        Readout("CRC frame 1 204 inválido", tone: .fault)
    }
    .padding()
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
```

- [ ] **Step 3: Barra de progreso limpia**

`Aether/DesignSystem/HairlineProgress.swift`:

```swift
import SwiftUI

/// Two-pass hairline: transfer fill (accent) then verification fill (signal) over the same 2 pt track.
/// Only `scaleEffect(x:)` is animated — a transform, no layout pass per update.
struct HairlineProgress: View {
    enum Stage: Equatable { case idle, transferring, verifying, verified, failed }

    private let transfer: Double
    private let verify: Double
    private let stage: Stage

    init(transfer: Double, verify: Double, stage: Stage) {
        self.transfer = transfer.clamped
        self.verify = verify.clamped
        self.stage = stage
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(stage == .failed ? AnyShapeStyle(Tokens.fault) : AnyShapeStyle(Tokens.hairline))
            Capsule()
                .fill(.tint)
                .opacity(stage == .verified || stage == .failed ? 0 : 0.85)
                .scaleEffect(x: transfer, y: 1, anchor: .leading)
                .animation(Tokens.Motion.progress, value: transfer)
            Capsule()
                .fill(Tokens.signal)
                .scaleEffect(x: stage == .verified ? 1 : verify, y: 1, anchor: .leading)
                .animation(Tokens.Motion.progress, value: verify)
        }
        .frame(height: 2)
        .animation(Tokens.Motion.state, value: stage)
        .accessibilityElement()
        .accessibilityLabel("Progreso")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        switch stage {
        case .idle: Text("En cola")
        case .transferring: Text("Descargando \(Int(transfer * 100)) por ciento")
        case .verifying: Text("Verificando \(Int(verify * 100)) por ciento")
        case .verified: Text("Verificado")
        case .failed: Text("Falló")
        }
    }
}

private extension Double {
    var clamped: Double { Swift.min(Swift.max(self, 0), 1) }
}

#Preview {
    VStack(spacing: 16) {
        HairlineProgress(transfer: 0.0, verify: 0, stage: .idle)
        HairlineProgress(transfer: 0.42, verify: 0, stage: .transferring)
        HairlineProgress(transfer: 1, verify: 0.6, stage: .verifying)
        HairlineProgress(transfer: 1, verify: 1, stage: .verified)
        HairlineProgress(transfer: 0.7, verify: 0, stage: .failed)
    }
    .padding()
    .frame(width: 420)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
```

- [ ] **Step 4: Glifo de estado**

`Aether/DesignSystem/StatusGlyph.swift`:

```swift
import SwiftUI

struct StatusGlyph: View {
    enum Status: Equatable { case queued, working, verifying, verified, failed, cancelled }

    private let status: Status

    init(_ status: Status) { self.status = status }

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 16)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch status {
        case .queued: "circle.dotted"
        case .working: "arrow.down.circle"
        case .verifying: "checkmark.shield"
        case .verified: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var color: AnyShapeStyle {
        switch status {
        case .verified: AnyShapeStyle(Tokens.signal)
        case .failed: AnyShapeStyle(Tokens.fault)
        case .working, .verifying: AnyShapeStyle(.tint)
        case .queued, .cancelled: AnyShapeStyle(.tertiary)
        }
    }

    private var label: Text {
        switch status {
        case .queued: Text("En cola")
        case .working: Text("Descargando")
        case .verifying: Text("Verificando")
        case .verified: Text("Verificado")
        case .failed: Text("Falló")
        case .cancelled: Text("Cancelado")
        }
    }
}
```

- [ ] **Step 5: Compilar y revisar previews**

Run: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' build -quiet`
Expected: sin errores. Abrir los `#Preview` de `Readout` y `HairlineProgress` en Xcode y comprobar visualmente: pista visible, relleno de transferencia en acento, verificación en verde fósforo, fallo en rojo.

- [ ] **Step 6: Commit**

```bash
git add Aether/DesignSystem
git commit -m "feat(design): add dark technical tokens, readouts, hairline progress and status glyphs"
```

---

### Task 4: Shell — `AppModel`, `Preferences`, rutas, sidebar, comandos y Settings

**Files:**
- Modify (reescribir): `Aether/AetherApp.swift` → mover a `Aether/App/AetherApp.swift`
- Delete: `Aether/ContentView.swift`
- Create: `Aether/App/AppDelegate.swift`
- Create: `Aether/App/AppModel.swift`
- Create: `Aether/App/Route.swift`
- Create: `Aether/App/AetherCommands.swift`
- Create: `Aether/Settings/Preferences.swift`
- Create: `Aether/Settings/SettingsView.swift`
- Create: `Aether/Shell/RootView.swift`
- Create: `Aether/Shell/SidebarView.swift`
- Modify: `AetherUITests/AetherUITests.swift`
- Test: `AetherTests/PreferencesTests.swift`

**Interfaces:**
- Produces:
  - `enum Route: Hashable { case harvesterSearch, harvesterQueue, harvesterHistory, cosmosAll, cosmosFolder(String), cosmosInbox, cosmosReview(ReviewFilter) }`, `enum ReviewFilter: String, Hashable, CaseIterable { untagged, duplicates, lossy }`
  - `@MainActor @Observable final class Preferences` con `masterFolder: URL`, `inboxFolderName: String`, `inboxFolder: URL` (computed), `hifiBaseURL: URL`, `qualityPolicyRaw: String`, `maxConcurrentDownloads: Int`, `bitPerfect: Bool`, `rekordboxXMLEnabled: Bool`, `rekordboxXMLURL: URL`; `init(defaults: UserDefaults = .standard)`
  - `@MainActor @Observable final class AppModel` con `preferences: Preferences`, `route: Route`, `isInspectorPresented: Bool`

- [ ] **Step 1: Prueba de `Preferences` que falla**

`AetherTests/PreferencesTests.swift`:

```swift
import Foundation
import Testing
@testable import Aether

@MainActor
@Suite struct PreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "aether-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsMatchSpec() {
        let p = Preferences(defaults: freshDefaults())
        #expect(p.masterFolder == URL.homeDirectory.appending(path: "Master"))
        #expect(p.inboxFolderName == "Por clasificar")
        #expect(p.inboxFolder == URL.homeDirectory.appending(path: "Master/Por clasificar"))
        #expect(p.hifiBaseURL == URL(string: "http://127.0.0.1:8000")!)
        #expect(p.qualityPolicyRaw == "hiResCapped96")
        #expect(p.maxConcurrentDownloads == 3)
        #expect(p.bitPerfect)
        #expect(p.rekordboxXMLEnabled)
        #expect(p.rekordboxXMLURL == URL.homeDirectory.appending(path: "Music/Aether/rekordbox.xml"))
    }

    @Test func persistsChanges() {
        let d = freshDefaults()
        let p = Preferences(defaults: d)
        p.maxConcurrentDownloads = 2
        p.masterFolder = URL(filePath: "/tmp/Master")
        let reloaded = Preferences(defaults: d)
        #expect(reloaded.maxConcurrentDownloads == 2)
        #expect(reloaded.masterFolder == URL(filePath: "/tmp/Master"))
    }

    @Test func clampsConcurrency() {
        let p = Preferences(defaults: freshDefaults())
        p.maxConcurrentDownloads = 9
        #expect(p.maxConcurrentDownloads == 4)
        p.maxConcurrentDownloads = 0
        #expect(p.maxConcurrentDownloads == 1)
    }
}
```

Run: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' test -only-testing:AetherTests -quiet`
Expected: FAIL — `cannot find 'Preferences' in scope`.

- [ ] **Step 2: Implementar `Preferences`**

`Aether/Settings/Preferences.swift`:

```swift
import Foundation
import Observation

@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let master = "masterFolder"
        static let inbox = "inboxFolderName"
        static let hifi = "hifiBaseURL"
        static let quality = "qualityPolicy"
        static let concurrency = "maxConcurrentDownloads"
        static let bitPerfect = "bitPerfect"
        static let xmlEnabled = "rekordboxXMLEnabled"
        static let xmlURL = "rekordboxXMLURL"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var masterFolder: URL { didSet { defaults.set(masterFolder.path, forKey: Key.master) } }
    var inboxFolderName: String { didSet { defaults.set(inboxFolderName, forKey: Key.inbox) } }
    var hifiBaseURL: URL { didSet { defaults.set(hifiBaseURL.absoluteString, forKey: Key.hifi) } }
    /// Raw value of `Harvester.QualityPolicy` (plan 04): "hiResCapped96" | "hiRes" | "lossless".
    var qualityPolicyRaw: String { didSet { defaults.set(qualityPolicyRaw, forKey: Key.quality) } }
    var maxConcurrentDownloads: Int {
        didSet {
            let clamped = min(max(maxConcurrentDownloads, 1), 4)
            if clamped != maxConcurrentDownloads { maxConcurrentDownloads = clamped; return }
            defaults.set(maxConcurrentDownloads, forKey: Key.concurrency)
        }
    }
    var bitPerfect: Bool { didSet { defaults.set(bitPerfect, forKey: Key.bitPerfect) } }
    var rekordboxXMLEnabled: Bool { didSet { defaults.set(rekordboxXMLEnabled, forKey: Key.xmlEnabled) } }
    var rekordboxXMLURL: URL { didSet { defaults.set(rekordboxXMLURL.path, forKey: Key.xmlURL) } }

    var inboxFolder: URL { masterFolder.appending(path: inboxFolderName, directoryHint: .isDirectory) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = URL.homeDirectory
        masterFolder = defaults.string(forKey: Key.master).map { URL(filePath: $0) } ?? home.appending(path: "Master")
        inboxFolderName = defaults.string(forKey: Key.inbox) ?? "Por clasificar"
        hifiBaseURL = defaults.string(forKey: Key.hifi).flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8000")!
        qualityPolicyRaw = defaults.string(forKey: Key.quality) ?? "hiResCapped96"
        let storedConcurrency = defaults.integer(forKey: Key.concurrency)
        maxConcurrentDownloads = storedConcurrency == 0 ? 3 : min(max(storedConcurrency, 1), 4)
        bitPerfect = defaults.object(forKey: Key.bitPerfect) as? Bool ?? true
        rekordboxXMLEnabled = defaults.object(forKey: Key.xmlEnabled) as? Bool ?? true
        rekordboxXMLURL = defaults.string(forKey: Key.xmlURL).map { URL(filePath: $0) }
            ?? home.appending(path: "Music/Aether/rekordbox.xml")
    }
}
```

- [ ] **Step 3: Rutas y modelo de app**

`Aether/App/Route.swift`:

```swift
enum ReviewFilter: String, Hashable, CaseIterable {
    case untagged, duplicates, lossy

    var title: String {
        switch self {
        case .untagged: "Sin tags"
        case .duplicates: "Duplicados"
        case .lossy: "Lossy"
        }
    }

    var symbol: String {
        switch self {
        case .untagged: "tag.slash"
        case .duplicates: "square.on.square"
        case .lossy: "waveform.badge.minus"
        }
    }
}

enum Route: Hashable {
    case harvesterSearch
    case harvesterQueue
    case harvesterHistory
    case cosmosAll
    case cosmosFolder(String)
    case cosmosInbox
    case cosmosReview(ReviewFilter)
}
```

`Aether/App/AppModel.swift`:

```swift
import Observation

/// Owns app-wide state. Feature stores (Harvester, Cosmos, Aether Core) are added by plans 04–06.
@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    var route: Route = .harvesterSearch
    var isInspectorPresented = false

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
    }
}
```

- [ ] **Step 4: App, delegate y comandos**

```bash
mkdir -p Aether/App && git mv Aether/AetherApp.swift Aether/App/AetherApp.swift && git rm -q Aether/ContentView.swift
```

`Aether/App/AetherApp.swift`:

```swift
import SwiftUI

@main
struct AetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // Single library window, like Music: Harvester's queue and Cosmos' index are app-wide singletons,
        // so additional windows would only mirror the same state.
        Window("Aether", id: "main") {
            RootView()
                .environment(model)
                .environment(model.preferences)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { AetherCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model.preferences)
                .preferredColorScheme(.dark)
        }
    }
}
```

`Aether/App/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Dark-only product: menus, alerts and panels follow the window appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    /// Downloads keep running with the window closed; the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
```

`Aether/App/AetherCommands.swift`:

```swift
import SwiftUI

struct AetherCommands: Commands {
    let model: AppModel

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Buscar en Tidal") { model.route = .harvesterSearch }
                .keyboardShortcut("1")
            Button("Cola de Harvester") { model.route = .harvesterQueue }
                .keyboardShortcut("2")
            Button("Master") { model.route = .cosmosAll }
                .keyboardShortcut("3")
        }
    }
}
```

> Nota para el overview: el inspector usa el atajo estándar de `InspectorCommands` (⌃⌘I), no ⌥⌘I.

- [ ] **Step 5: Shell — RootView y Sidebar**

`Aether/Shell/RootView.swift`:

```swift
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(route: $model.route)
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
        } detail: {
            DetailRouter(route: model.route)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.canvas)
        }
    }
}

/// Each plan replaces its routes' unavailable states with the real screen.
struct DetailRouter: View {
    let route: Route

    var body: some View {
        switch route {
        case .harvesterSearch:
            ContentUnavailableView("Buscar en Tidal", systemImage: "magnifyingglass",
                                   description: Text("Escribe un artista, una pista o un álbum."))
        case .harvesterQueue:
            ContentUnavailableView("Cola vacía", systemImage: "arrow.down.circle",
                                   description: Text("Las descargas aparecerán aquí."))
        case .harvesterHistory:
            ContentUnavailableView("Sin historial", systemImage: "clock",
                                   description: Text("Las descargas verificadas aparecerán aquí."))
        case .cosmosAll, .cosmosFolder, .cosmosInbox, .cosmosReview:
            ContentUnavailableView("Master", systemImage: "folder",
                                   description: Text("Cosmos indexará tu carpeta Master."))
        }
    }
}
```

`Aether/Shell/SidebarView.swift`:

```swift
import SwiftUI

struct SidebarView: View {
    @Binding var route: Route

    var body: some View {
        List(selection: Binding<Route?>(get: { route }, set: { if let new = $0 { route = new } })) {
            Section("Harvester") {
                Label("Buscar", systemImage: "magnifyingglass").tag(Route.harvesterSearch)
                Label("Cola", systemImage: "arrow.down.circle").tag(Route.harvesterQueue)
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

- [ ] **Step 6: Settings (pestaña General)**

`Aether/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var preferences
    @State private var isPickingMaster = false

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                LabeledContent("Carpeta Master") {
                    HStack {
                        Readout(preferences.masterFolder.path(percentEncoded: false), tone: .primary)
                        Button("Elegir…") { isPickingMaster = true }
                    }
                }
                TextField("Carpeta de entrada", text: $preferences.inboxFolderName)
            } header: {
                SectionLabel("Biblioteca")
            }
            Section {
                TextField("URL de hifi-api", value: $preferences.hifiBaseURL, format: .url)
                    .font(.readout)
            } header: {
                SectionLabel("Fuente")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isPickingMaster, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { preferences.masterFolder = url }
        }
    }
}
```

- [ ] **Step 7: Prueba de UI de arranque**

Reemplazar el contenido de `AetherUITests/AetherUITests.swift`:

```swift
import XCTest

final class AetherUITests: XCTestCase {
    @MainActor
    func testLaunchShowsSidebarSections() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Buscar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Master"].exists)
    }
}
```

- [ ] **Step 8: Ejecutar todo**

Run: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' test -quiet`
Expected: `PreferencesTests` (3) y `AetherUITests` PASS. Abrir la app: ventana oscura, sidebar con Harvester/Cosmos, ⌘1/⌘2/⌘3 cambian la ruta, ⌘, abre Settings, ⌃⌘S oculta la sidebar.

- [ ] **Step 9: Commit**

```bash
git add Aether AetherTests AetherUITests
git commit -m "feat(app): add dark app shell with routes, sidebar, commands and settings"
```
