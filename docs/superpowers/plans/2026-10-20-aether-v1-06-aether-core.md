# Aether v1 · Plan 06 — Aether Core (reproductor lossless bit-perfect)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reproducir cualquier pista del Master o de Harvester sin pérdidas, ajustando el sample rate del DAC al del archivo (bit-perfect), con una cápsula de transporte Liquid Glass, forma de onda navegable, lectura técnica de la cadena de señal, medidores, teclas multimedia y preescucha de resultados de Tidal.

**Architecture:** Módulo `AetherCore`: `OutputDevice` (CoreAudio HAL), `PlaybackEngine` (`AVAudioEngine` + `AVAudioPlayerNode`, `@MainActor`, reprogramación por "generación" para seek/stop), `MeterTap` (vDSP + `Mutex`, solo instalado cuando se ve), `WaveformAnalyzer` (picos por bins). En la app: `PlayerModel` (`@Observable`) con cola, puente a `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` y restauración del sample rate al salir; `TransportBar` flotante con `glassEffect`; tiempo y medidores leídos con `TimelineView` **pausado** cuando no suena. Preescucha: base con caché local (siempre funciona) y mejora por streaming de frames FLAC si el spike S2 pasó.

**Tech Stack:** Swift 6, AVFAudio, CoreAudio, Accelerate (vDSP), Synchronization, MediaPlayer, SwiftUI (Liquid Glass: `glassEffect`, `GlassEffectContainer`), Swift Testing.

**Spec:** `docs/superpowers/plans/2026-10-20-aether-v1-00-overview.md` (§1 Aether Core, §4 presupuestos, §7 Liquid Glass/movimiento, §8 Control, §9.7)

## Global Constraints

- macOS 27, Swift 6, cero dependencias de terceros.
- Reproducción local: CPU < 3 %. Medidores apagados = **sin tap instalado**. Ningún `Timer`: el tiempo se pinta con `TimelineView(.animation(minimumInterval:paused:))` pausado salvo cuando suena.
- Bit-perfect: volumen del mezclador y del nodo a 1.0 (el volumen se controla en el sistema); sample rate del dispositivo = el del archivo cuando el dispositivo lo admite. Restaurar el sample rate original al salir.
- Liquid Glass solo en la cápsula de transporte (y controles del sistema). Nunca vidrio sobre vidrio. *Reduce Transparency* → superficie sólida `Tokens.surface`. *Reduce Motion* → solo opacidad.
- Sin animación en acciones de teclado (Espacio, ⌘→, ⌘←): cambian estado al instante.
- Espacio = reproducir/pausa vía `onKeyPress` en la raíz (no como equivalente de menú, para no robar espacios a los campos de texto).

Rutas relativas a `~/Documents/Projects/Aether`.

---

### Task 1: Target `AetherCore` y `OutputDevice`

**Files:**
- Modify: `Packages/AetherKit/Package.swift`
- Create: `Packages/AetherKit/Sources/AetherCore/OutputDevice.swift`
- Test: `Packages/AetherKit/Tests/AetherCoreTests/OutputDeviceTests.swift`

**Interfaces:**
- Produces: `public struct OutputDevice: Sendable, Equatable { let id: AudioObjectID; static func defaultOutput() -> OutputDevice?; var name: String; var nominalSampleRate: Double; var availableSampleRates: [Double]; func setNominalSampleRate(_ rate: Double) throws; func bestRate(for source: Double) -> Double }`, `public enum OutputDeviceError: Error, Equatable { case coreAudio(Int32) }`

- [ ] **Step 1: Target**

```swift
.library(name: "AetherKit", targets: ["ByteKit", "TagKit", "FlacKit", "HiFiClient", "Harvester", "Cosmos", "AetherCore"]),
```

```swift
.target(name: "AetherCore", dependencies: ["ByteKit", "FlacKit", "HiFiClient", "TagKit"], swiftSettings: settings),
.testTarget(name: "AetherCoreTests", dependencies: ["AetherCore", "TestSupport"], swiftSettings: settings),
```

- [ ] **Step 2: Pruebas que fallan**

`Packages/AetherKit/Tests/AetherCoreTests/OutputDeviceTests.swift`:

```swift
import Testing
@testable import AetherCore

@Suite struct OutputDeviceTests {
    @Test func bestRatePrefersExactThenIntegerMultipleThenMax() {
        let rates: [Double] = [44_100, 48_000, 88_200, 96_000]
        #expect(OutputDevice.bestRate(for: 96_000, among: rates) == 96_000)
        #expect(OutputDevice.bestRate(for: 176_400, among: rates) == 88_200)
        #expect(OutputDevice.bestRate(for: 192_000, among: rates) == 96_000)
        #expect(OutputDevice.bestRate(for: 22_050, among: rates) == 44_100)
        #expect(OutputDevice.bestRate(for: 32_000, among: []) == 32_000)
    }

    @Test(.enabled(if: OutputDevice.defaultOutput() != nil))
    func defaultDeviceReportsSaneValues() throws {
        let device = try #require(OutputDevice.defaultOutput())
        #expect(!device.name.isEmpty)
        #expect(device.nominalSampleRate >= 8_000)
        #expect(device.availableSampleRates.contains(device.nominalSampleRate))
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter OutputDeviceTests`
Expected: FAIL de compilación — `cannot find 'OutputDevice' in scope`.

- [ ] **Step 3: Implementar**

`Packages/AetherKit/Sources/AetherCore/OutputDevice.swift`:

```swift
public import CoreAudio
import Foundation

public enum OutputDeviceError: Error, Equatable, Sendable { case coreAudio(Int32) }

/// Thin CoreAudio HAL wrapper for the system default output device.
public struct OutputDevice: Sendable, Equatable {
    public let id: AudioObjectID

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    public static func defaultOutput() -> OutputDevice? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? OutputDevice(id: id) : nil
    }

    public var name: String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = Self.address(kAudioObjectPropertyName)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else { return "" }
        return value as String
    }

    public var nominalSampleRate: Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    public var availableSampleRates: [Double] {
        var addr = Self.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return Array(Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] })).sorted()
    }

    public func setNominalSampleRate(_ rate: Double) throws {
        var value = Float64(rate)
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        let status = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { throw OutputDeviceError.coreAudio(status) }
    }

    public func bestRate(for source: Double) -> Double { Self.bestRate(for: source, among: availableSampleRates) }

    /// Exact match → bit-perfect. Otherwise the highest rate that divides the source evenly (cleanest
    /// resample, e.g. 176.4 → 88.2), otherwise the highest rate available.
    public static func bestRate(for source: Double, among rates: [Double]) -> Double {
        guard !rates.isEmpty else { return source }
        if rates.contains(source) { return source }
        if let divisor = rates.filter({ source.truncatingRemainder(dividingBy: $0) == 0 }).max() { return divisor }
        if let multiple = rates.filter({ $0.truncatingRemainder(dividingBy: source) == 0 }).min() { return multiple }
        return rates.max()!
    }
}
```

- [ ] **Step 4: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter OutputDeviceTests`
Expected: 2 PASS (la segunda se omite si no hay dispositivo de salida).

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(aethercore): query and set the output device sample rate via CoreAudio"
```

---

### Task 2: `MeterTap` y `WaveformAnalyzer`

**Files:**
- Create: `Packages/AetherKit/Sources/AetherCore/MeterTap.swift`
- Create: `Packages/AetherKit/Sources/AetherCore/WaveformAnalyzer.swift`
- Test: `Packages/AetherKit/Tests/AetherCoreTests/MeterAndWaveformTests.swift`

**Interfaces:**
- Produces:
  - `public final class MeterTap: Sendable { struct Levels: Equatable, Sendable { peak: [Float]; rms: [Float]; static let silent }; var current: Levels; func process(_ buffer: AVAudioPCMBuffer); func reset() }` — picos con caída exponencial (×0.85 por buffer).
  - `public enum WaveformAnalyzer { static func peaks(for url: URL, bins: Int = 1200) throws -> [Float] }` — máximo absoluto por bin (0…1).

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/AetherCoreTests/MeterAndWaveformTests.swift`:

```swift
import AVFAudio
import Foundation
import Testing
@testable import AetherCore
import TestSupport

@Suite struct MeterAndWaveformTests {
    private func buffer(value: Float, frames: AVAudioFrameCount = 1024) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        for ch in 0..<2 { for i in 0..<Int(frames) { b.floatChannelData![ch][i] = (i % 2 == 0 ? value : -value) * (ch == 0 ? 1 : 0.5) } }
        return b
    }

    @Test func meterTracksPeakAndRMSWithDecay() {
        let meter = MeterTap()
        meter.process(buffer(value: 0.8))
        let first = meter.current
        #expect(abs(first.peak[0] - 0.8) < 0.0001)
        #expect(abs(first.peak[1] - 0.4) < 0.0001)
        #expect(abs(first.rms[0] - 0.8) < 0.0001)
        meter.process(buffer(value: 0))
        #expect(abs(meter.current.peak[0] - 0.8 * 0.85) < 0.0001)
        meter.reset()
        #expect(meter.current == .silent)
    }

    @Test func waveformPeaksFollowSignalAmplitude() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1)
        let peaks = try WaveformAnalyzer.peaks(for: url, bins: 100)
        #expect(peaks.count == 100)
        #expect(peaks.allSatisfy { $0 > 0.5 && $0 <= 0.61 })   // fixture amplitude = 0.6 FS
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter MeterAndWaveformTests`
Expected: FAIL de compilación — `cannot find 'MeterTap' in scope`.

- [ ] **Step 2: Implementar `MeterTap`**

`Packages/AetherKit/Sources/AetherCore/MeterTap.swift`:

```swift
import Accelerate
public import AVFAudio
import Synchronization

/// Written on the audio render thread, read by the UI at ≤ 30 Hz. One small lock, no allocation per read.
public final class MeterTap: Sendable {
    public struct Levels: Equatable, Sendable {
        public var peak: [Float]
        public var rms: [Float]
        public static let silent = Levels(peak: [0, 0], rms: [0, 0])
    }

    private let state = Mutex(Levels.silent)

    public init() {}

    public var current: Levels { state.withLock { $0 } }

    public func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frames = vDSP_Length(buffer.frameLength)
        var peaks = [Float](repeating: 0, count: channels)
        var rms = [Float](repeating: 0, count: channels)
        for ch in 0..<channels {
            vDSP_maxmgv(data[ch], 1, &peaks[ch], frames)
            vDSP_rmsqv(data[ch], 1, &rms[ch], frames)
        }
        state.withLock { levels in
            if levels.peak.count != channels { levels = Levels(peak: peaks, rms: rms); return }
            for ch in 0..<channels { levels.peak[ch] = max(peaks[ch], levels.peak[ch] * 0.85) }
            levels.rms = rms
        }
    }

    public func reset() { state.withLock { $0 = .silent } }
}
```

- [ ] **Step 3: Implementar `WaveformAnalyzer`**

`Packages/AetherKit/Sources/AetherCore/WaveformAnalyzer.swift`:

```swift
import Accelerate
@preconcurrency import AVFAudio
public import Foundation

public enum WaveformAnalyzer {
    /// Decodes in 64 Ki-frame chunks and keeps the absolute peak per bin across all channels.
    /// Blocking: call from a detached task.
    public static func peaks(for url: URL, bins: Int = 1200) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let total = max(file.length, 1)
        let framesPerBin = max(Double(total) / Double(bins), 1)
        var result = [Float](repeating: 0, count: bins)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { return result }
        var position: Int64 = 0
        while position < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            var offset = 0
            while offset < frames {
                let bin = min(Int(Double(position + Int64(offset)) / framesPerBin), bins - 1)
                let binEnd = Int64((Double(bin + 1) * framesPerBin).rounded(.up))
                let count = min(frames - offset, max(Int(binEnd - (position + Int64(offset))), 1))
                for ch in 0..<Int(buffer.format.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(data[ch] + offset, 1, &peak, vDSP_Length(count))
                    result[bin] = max(result[bin], peak)
                }
                offset += count
            }
            position += Int64(frames)
        }
        return result
    }
}
```

- [ ] **Step 4: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter MeterAndWaveformTests`
Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(aethercore): add render-thread meters and waveform peak analysis"
```

---

### Task 3: `PlaybackEngine`

**Files:**
- Create: `Packages/AetherKit/Sources/AetherCore/PlaybackEngine.swift`
- Test: `Packages/AetherKit/Tests/AetherCoreTests/PlaybackEngineTests.swift`

**Interfaces:**
- Consumes: `OutputDevice`, `MeterTap` (Task 2).
- Produces:
  - `public struct LoadedTrack: Equatable, Sendable { url: URL; sampleRate: Double; channels: Int; bitDepth: Int?; frames: Int64; var duration: Double }`
  - `@MainActor public final class PlaybackEngine` con `enum State { idle, playing, paused }`, `state`, `track: LoadedTrack?`, `deviceSampleRate: Double`, `deviceName: String`, `isBitPerfect: Bool`, `var bitPerfect: Bool`, `var onFinish: (() -> Void)?`, `var onStateChange: (() -> Void)?`, `let meter: MeterTap`, `init()`, `load(_ url: URL, bitDepth: Int?) throws -> LoadedTrack`, `play() throws`, `pause()`, `toggle() throws`, `stop()`, `seek(to seconds: Double)`, `var currentTime: Double`, `setMetering(_ on: Bool)`, `restoreDeviceRate()`

- [ ] **Step 1: Pruebas que fallan**

`Packages/AetherKit/Tests/AetherCoreTests/PlaybackEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import AetherCore
import TestSupport

@MainActor
@Suite(.enabled(if: OutputDevice.defaultOutput() != nil), .serialized)
struct PlaybackEngineTests {
    @Test func loadReportsFormat() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1, bits: 24)
        let engine = PlaybackEngine()
        engine.bitPerfect = false
        let track = try engine.load(url, bitDepth: 24)
        #expect(track.sampleRate == 44_100)
        #expect(track.channels == 2)
        #expect(track.frames == 44_100)
        #expect(engine.state == .paused)
        #expect(engine.currentTime == 0)
    }

    @Test func seekWhilePausedMovesTheClock() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2)
        let engine = PlaybackEngine()
        engine.bitPerfect = false
        _ = try engine.load(url, bitDepth: 16)
        engine.seek(to: 1.25)
        #expect(abs(engine.currentTime - 1.25) < 0.001)
        engine.seek(to: 99)
        #expect(engine.currentTime <= 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func playsToTheEndAndFiresOnFinishOnce() async throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 0.4)
        let engine = PlaybackEngine()
        engine.bitPerfect = false
        _ = try engine.load(url, bitDepth: 16)
        var finishes = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            engine.onFinish = { finishes += 1; done.resume() }
            try? engine.play()
        }
        #expect(finishes == 1)
        #expect(engine.state == .idle)
    }

    @Test func seekDuringPlaybackDoesNotFireFinish() async throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 3)
        let engine = PlaybackEngine()
        engine.bitPerfect = false
        _ = try engine.load(url, bitDepth: 16)
        var finished = false
        engine.onFinish = { finished = true }
        try engine.play()
        engine.seek(to: 1)
        engine.seek(to: 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!finished)
        #expect(engine.currentTime >= 2)
        engine.stop()
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter PlaybackEngineTests`
Expected: FAIL de compilación — `cannot find 'PlaybackEngine' in scope`.

- [ ] **Step 2: Implementar**

`Packages/AetherKit/Sources/AetherCore/PlaybackEngine.swift`:

```swift
@preconcurrency import AVFAudio
public import Foundation
import OSLog

public struct LoadedTrack: Equatable, Sendable {
    public let url: URL
    public let sampleRate: Double
    public let channels: Int
    public let bitDepth: Int?
    public let frames: Int64
    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
}

/// Local-file playback. Signal path: AVAudioFile → PlayerNode → MainMixer (gain 1.0) → device.
/// With `bitPerfect`, the device nominal rate is switched to the file's rate before starting, so the
/// mixer does no sample-rate conversion and 16/24-bit samples pass through Float32 unchanged.
@MainActor
public final class PlaybackEngine {
    public enum State: Equatable, Sendable { case idle, playing, paused }

    private static let log = Logger(subsystem: "com.jazar.Aether", category: "aethercore")

    public private(set) var state: State = .idle { didSet { if state != oldValue { onStateChange?() } } }
    public private(set) var track: LoadedTrack?
    public var bitPerfect = true
    public var onFinish: (() -> Void)?
    public var onStateChange: (() -> Void)?
    public let meter = MeterTap()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var isScheduled = false
    private var originalDeviceRate: Double?
    private var isMetering = false
    private var configObserver: (any NSObjectProtocol)?

    public init() {
        engine.attach(player)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    public var deviceSampleRate: Double { OutputDevice.defaultOutput()?.nominalSampleRate ?? 0 }
    public var deviceName: String { OutputDevice.defaultOutput()?.name ?? "" }

    public var isBitPerfect: Bool {
        guard let track else { return false }
        return track.sampleRate == deviceSampleRate && engine.mainMixerNode.outputVolume == 1 && player.volume == 1
    }

    @discardableResult
    public func load(_ url: URL, bitDepth: Int?) throws -> LoadedTrack {
        stop()
        let file = try AVAudioFile(forReading: url)
        self.file = file
        let format = file.processingFormat
        let loaded = LoadedTrack(url: url, sampleRate: format.sampleRate, channels: Int(format.channelCount),
                                 bitDepth: bitDepth, frames: file.length)
        track = loaded

        engine.stop()
        if bitPerfect, let device = OutputDevice.defaultOutput() {
            let target = device.bestRate(for: format.sampleRate)
            if device.nominalSampleRate != target {
                if originalDeviceRate == nil { originalDeviceRate = device.nominalSampleRate }
                do { try device.setNominalSampleRate(target) } catch { Self.log.error("rate switch failed: \(String(describing: error))") }
            }
        }
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        startFrame = 0
        state = .paused
        return loaded
    }

    public func play() throws {
        guard file != nil, state != .playing else { return }
        if !engine.isRunning { try engine.start() }
        if !isScheduled { schedule(from: startFrame) }
        player.play()
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        player.pause()
        state = .paused
    }

    public func toggle() throws { state == .playing ? pause() : try play() }

    public func stop() {
        generation += 1
        player.stop()
        isScheduled = false
        startFrame = 0
        if state != .idle { state = file == nil ? .idle : .paused }
    }

    public func seek(to seconds: Double) {
        guard let file else { return }
        let rate = file.processingFormat.sampleRate
        let frame = min(max(AVAudioFramePosition(seconds * rate), 0), file.length)
        let wasPlaying = state == .playing
        schedule(from: frame)
        if wasPlaying { player.play() }
    }

    public var currentTime: Double {
        guard let track, track.sampleRate > 0 else { return 0 }
        let rate = track.sampleRate
        guard state != .idle,
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return min(Double(startFrame) / rate, track.duration) }
        return min(Double(startFrame + max(playerTime.sampleTime, 0)) / rate, track.duration)
    }

    public func setMetering(_ on: Bool) {
        guard on != isMetering else { return }
        isMetering = on
        let mixer = engine.mainMixerNode
        if on {
            let meter = meter
            mixer.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in meter.process(buffer) }
        } else {
            mixer.removeTap(onBus: 0)
            meter.reset()
        }
    }

    public func restoreDeviceRate() {
        guard let original = originalDeviceRate, let device = OutputDevice.defaultOutput() else { return }
        try? device.setNominalSampleRate(original)
        originalDeviceRate = nil
    }

    /// Every (re)schedule bumps `generation`; completions from older generations (seek/stop) are ignored.
    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        generation += 1
        let token = generation
        player.stop()
        startFrame = frame
        isScheduled = false
        let remaining = AVAudioFrameCount(max(file.length - frame, 0))
        guard remaining > 0 else { return }
        isScheduled = true
        player.scheduleSegment(file, startingFrame: frame, frameCount: remaining, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(token) }
        }
    }

    private func segmentFinished(_ token: Int) {
        guard token == generation, state == .playing else { return }
        player.stop()
        isScheduled = false
        startFrame = 0
        state = .idle
        onFinish?()
    }

    /// Device rate or route changed: rebuild the graph and continue from where we were.
    private func handleConfigurationChange() {
        guard let file else { return }
        let resumeAt = currentTime
        let wasPlaying = state == .playing
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        engine.prepare()
        if wasPlaying {
            try? engine.start()
            seek(to: resumeAt)
            player.play()
        } else {
            startFrame = AVAudioFramePosition(resumeAt * file.processingFormat.sampleRate)
        }
    }
}
```

- [ ] **Step 3: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter PlaybackEngineTests`
Expected: 4 PASS (se oye ≈0.4 s de tono en la prueba de fin de pista; bajar el volumen del sistema).

- [ ] **Step 4: Commit**

```bash
git add Packages/AetherKit
git commit -m "feat(aethercore): add bit-perfect AVAudioEngine playback with generation-safe seeking"
```

---

### Task 4: `PlayerModel`, Now Playing y restauración del DAC

**Files:**
- Create: `Aether/AetherCore/PlayerModel.swift`
- Create: `Aether/AetherCore/NowPlayingBridge.swift`
- Modify: `Aether/App/AppModel.swift`
- Modify: `Aether/App/AetherApp.swift` (`.environment(model.player)`)
- Modify: `Aether/App/AppDelegate.swift` (restaurar sample rate al salir)
- Test: `AetherTests/PlayerQueueTests.swift`

**Interfaces:**
- Consumes: `PlaybackEngine`, `WaveformAnalyzer`, `TagIO`, `ArtworkProcessor`, `Preferences.bitPerfect`.
- Produces:
  - `struct NowPlaying: Equatable { url: URL; title: String; artist: String; album: String?; formatLabel: String; artwork: CGImage? }` (== por `url`)
  - `struct SignalPath: Equatable { sourceRate: Double; bitDepth: Int?; deviceRate: Double; deviceName: String; isBitPerfect: Bool; var summary: String }`
  - `struct PlayQueue: Equatable { urls: [URL]; index: Int; mutating func next() -> URL?; mutating func previous() -> URL?; var current: URL? }`
  - `@MainActor @Observable final class PlayerModel` con `current`, `state`, `waveform: [Float]`, `signal: SignalPath?`, `queue: PlayQueue`, `meteringVisible: Bool`, `engine: PlaybackEngine`, `duration`, `currentTime`, `play(urls:startAt:)`, `toggle()`, `next()`, `previous()`, `seek(toFraction:)`, `skip(by:)`, `shutdown()`

- [ ] **Step 1: Prueba de la cola (lógica pura) que falla**

`AetherTests/PlayerQueueTests.swift`:

```swift
import Foundation
import Testing
@testable import Aether

@Suite struct PlayerQueueTests {
    @Test func navigatesWithinBounds() {
        let urls = (1...3).map { URL(filePath: "/m/\($0).flac") }
        var q = PlayQueue(urls: urls, index: 1)
        #expect(q.current == urls[1])
        #expect(q.next() == urls[2])
        #expect(q.next() == nil)
        #expect(q.current == urls[2])
        #expect(q.previous() == urls[1])
        #expect(q.previous() == urls[0])
        #expect(q.previous() == nil)
    }

    @Test func signalSummary() {
        let s = SignalPath(sourceRate: 96_000, bitDepth: 24, deviceRate: 96_000, deviceName: "RME ADI-2", isBitPerfect: true)
        #expect(s.summary == "24/96 → RME ADI-2 · 96 kHz · BIT-PERFECT")
        let r = SignalPath(sourceRate: 44_100, bitDepth: 16, deviceRate: 48_000, deviceName: "MacBook Pro", isBitPerfect: false)
        #expect(r.summary == "16/44.1 → MacBook Pro · 48 kHz · REMUESTREADO")
    }
}
```

Run: `xcodebuild … test -only-testing:AetherTests/PlayerQueueTests -quiet`
Expected: FAIL — `cannot find 'PlayQueue' in scope`.

- [ ] **Step 2: `PlayerModel`**

`Aether/AetherCore/PlayerModel.swift`:

```swift
import AetherCore
import AppKit
import Cosmos
import Observation
import TagKit

struct NowPlaying: Equatable {
    let url: URL
    let title: String
    let artist: String
    let album: String?
    let formatLabel: String
    let artwork: CGImage?
    static func == (a: NowPlaying, b: NowPlaying) -> Bool { a.url == b.url && a.title == b.title && a.artist == b.artist }
}

struct SignalPath: Equatable {
    let sourceRate: Double
    let bitDepth: Int?
    let deviceRate: Double
    let deviceName: String
    let isBitPerfect: Bool

    private static func khz(_ rate: Double) -> String {
        let k = rate / 1000
        return k.rounded() == k ? String(Int(k)) : String(format: "%.1f", k)
    }

    var summary: String {
        let source = bitDepth.map { "\($0)/\(Self.khz(sourceRate))" } ?? "\(Self.khz(sourceRate)) kHz"
        return "\(source) → \(deviceName) · \(Self.khz(deviceRate)) kHz · \(isBitPerfect ? "BIT-PERFECT" : "REMUESTREADO")"
    }
}

struct PlayQueue: Equatable {
    var urls: [URL] = []
    var index = 0
    var current: URL? { urls.indices.contains(index) ? urls[index] : nil }
    mutating func next() -> URL? { guard index + 1 < urls.count else { return nil }; index += 1; return current }
    mutating func previous() -> URL? { guard index > 0 else { return nil }; index -= 1; return current }
}

@MainActor
@Observable
final class PlayerModel {
    private(set) var current: NowPlaying?
    private(set) var state: PlaybackEngine.State = .idle
    private(set) var waveform: [Float] = []
    private(set) var signal: SignalPath?
    private(set) var queue = PlayQueue()
    var meteringVisible = false { didSet { engine.setMetering(meteringVisible) } }

    @ObservationIgnored let engine = PlaybackEngine()
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var waveformCache: [String: [Float]] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    // @Observable does not support `lazy`: assigned once at the end of init.
    @ObservationIgnored private(set) var nowPlaying: NowPlayingBridge!

    init(preferences: Preferences) {
        self.preferences = preferences
        engine.onStateChange = { [weak self] in self?.syncState() }
        engine.onFinish = { [weak self] in self?.next() }
        nowPlaying = NowPlayingBridge(player: self)
    }

    var duration: Double { engine.track?.duration ?? 0 }
    /// Read only from TimelineView bodies (no observation, no timers).
    var currentTime: Double { engine.currentTime }

    func play(urls: [URL], startAt index: Int) {
        queue = PlayQueue(urls: urls, index: index)
        load(queue.current, autoplay: true)
    }

    func toggle() {
        if current == nil, let url = queue.current { load(url, autoplay: true); return }
        try? engine.toggle()
    }

    func next() {
        if let url = queue.next() { load(url, autoplay: true) } else { engine.stop() }
    }

    func previous() {
        if currentTime > 3 { engine.seek(to: 0); return }
        if let url = queue.previous() { load(url, autoplay: true) }
    }

    func seek(toFraction fraction: Double) {
        engine.seek(to: min(max(fraction, 0), 1) * duration)
        nowPlaying.update()
    }

    func skip(by seconds: Double) {
        engine.seek(to: min(max(currentTime + seconds, 0), duration))
        nowPlaying.update()
    }

    func shutdown() {
        engine.stop()
        engine.restoreDeviceRate()
    }

    private func load(_ url: URL?, autoplay: Bool) {
        guard let url else { return }
        loadTask?.cancel()
        engine.bitPerfect = preferences.bitPerfect
        let probe = try? AudioProbe.probe(url)
        do {
            _ = try engine.load(url, bitDepth: probe?.bitDepth)
            if autoplay { try engine.play() }
        } catch {
            current = nil
            return
        }
        refreshSignal()
        let key = "\(url.path)|\(probe?.duration ?? 0)"
        waveform = waveformCache[key] ?? []
        loadTask = Task {
            async let tags = Task.detached(priority: .userInitiated) { (try? TagIO.read(url)) ?? TrackTags() }.value
            async let peaks = Task.detached(priority: .utility) { try? WaveformAnalyzer.peaks(for: url, bins: 1200) }.value
            let t = await tags
            let art = await Task.detached(priority: .userInitiated) { t.artwork.flatMap { ArtworkProcessor.thumbnail($0.data, maxPixel: 128) } }.value
            guard !Task.isCancelled else { return }
            let stem = url.deletingPathExtension().lastPathComponent
            current = NowPlaying(url: url, title: t.title ?? stem, artist: t.artist ?? "", album: t.album,
                                 formatLabel: probe?.label ?? url.pathExtension.uppercased(), artwork: art)
            nowPlaying.update()
            if waveform.isEmpty, let p = await peaks, !Task.isCancelled {
                waveform = p
                waveformCache[key] = p
                if waveformCache.count > 32 { waveformCache.removeValue(forKey: waveformCache.keys.first!) }
            }
        }
    }

    private func syncState() {
        state = engine.state
        refreshSignal()
        nowPlaying.update()
    }

    private func refreshSignal() {
        guard let track = engine.track else { signal = nil; return }
        signal = SignalPath(sourceRate: track.sampleRate, bitDepth: track.bitDepth, deviceRate: engine.deviceSampleRate,
                            deviceName: engine.deviceName, isBitPerfect: engine.isBitPerfect)
    }
}
```

- [ ] **Step 3: Now Playing y teclas multimedia**

`Aether/AetherCore/NowPlayingBridge.swift`:

```swift
import MediaPlayer

@MainActor
final class NowPlayingBridge {
    private unowned let player: PlayerModel

    init(player: PlayerModel) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.player.toggle(); return .success }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.player.state != .playing else { return .success }
            self.player.toggle()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.player.state == .playing else { return .success }
            self.player.toggle()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.player.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.player.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent, self.player.duration > 0 else { return .commandFailed }
            self.player.seek(toFraction: e.positionTime / self.player.duration)
            return .success
        }
    }

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let now = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: now.title,
            MPMediaItemPropertyArtist: now.artist,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
        ]
        if let album = now.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let cg = now.artwork {
            let size = NSSize(width: cg.width, height: cg.height)
            // Capture the Sendable CGImage, build the NSImage inside the (Sendable) request handler.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in NSImage(cgImage: cg, size: size) }
        }
        center.nowPlayingInfo = info
        center.playbackState = player.state == .playing ? .playing : .paused
    }
}
```

- [ ] **Step 4: Cablear y restaurar al salir**

`AppModel`: añadir `let player: PlayerModel` e inicializar `player = PlayerModel(preferences: preferences)` en `init`. `AetherApp`: `.environment(model.player)`.

`AppDelegate`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AetherApp so termination can restore the DAC's original sample rate.
    var onTerminate: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
}
```

En `AetherApp`, dentro del contenido del `Window` añadir `.onAppear { appDelegate.onTerminate = { [player = model.player] in player.shutdown() } }`.

- [ ] **Step 5: Verificar**

Run: `xcodebuild … test -only-testing:AetherTests/PlayerQueueTests -quiet`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Aether AetherTests
git commit -m "feat(aethercore): add player model with queue, Now Playing, media keys and DAC rate restore"
```

---

### Task 5: Cápsula de transporte Liquid Glass, forma de onda, cadena de señal y comandos

**Files:**
- Create: `Aether/AetherCore/TransportBar.swift`
- Create: `Aether/AetherCore/WaveformScrubber.swift`
- Create: `Aether/AetherCore/SignalPopover.swift`
- Modify: `Aether/Shell/RootView.swift` (cápsula sobre el detalle, `onKeyPress(.space)`)
- Modify: `Aether/App/AetherCommands.swift` (menú Control)
- Modify: `Aether/Cosmos/CosmosBrowserView.swift` (doble clic = reproducir)
- Modify: `Aether/Harvester/HarvesterHistoryView.swift` (Reproducir)
- Modify: `Aether/Settings/SettingsView.swift` (pestaña Aether Core)

**Interfaces:**
- Consumes: `PlayerModel`, `NowPlaying`, `SignalPath`, `MeterTap.Levels`, `Tokens`.
- Produces: `TransportBar`, `WaveformScrubber(peaks:)`, `SignalPopover`, `LevelMeter`.

- [ ] **Step 1: Forma de onda navegable**

`Aether/AetherCore/WaveformScrubber.swift`:

```swift
import SwiftUI

/// Canvas waveform; the played portion is redrawn only while playing (TimelineView is paused otherwise).
struct WaveformScrubber: View {
    let peaks: [Float]
    @Environment(PlayerModel.self) private var player
    @State private var width: CGFloat = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: player.state != .playing)) { _ in
            let duration = player.duration
            let progress = duration > 0 ? player.currentTime / duration : 0
            HStack(spacing: Tokens.Space.s) {
                Readout(format(player.currentTime))
                Canvas { context, size in
                    let columns = max(Int(size.width / 2), 1)
                    let playedX = size.width * progress
                    for column in 0..<columns {
                        let x = CGFloat(column) * 2
                        let value = peaks.isEmpty ? 0.08 : CGFloat(sample(column, of: columns))
                        let height = max(size.height * value, 1)
                        let rect = CGRect(x: x, y: (size.height - height) / 2, width: 1, height: height)
                        context.fill(Path(rect), with: .color(x <= playedX ? .primary : .secondary.opacity(0.35)))
                    }
                }
                .frame(height: 26)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { seek($0.location.x) })
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                Readout("-" + format(max(duration - player.currentTime, 0)))
            }
            .accessibilityElement()
            .accessibilityLabel("Posición")
            .accessibilityValue("\(format(player.currentTime)) de \(format(duration))")
            .accessibilityAdjustableAction { direction in
                player.skip(by: direction == .increment ? 10 : -10)
            }
        }
    }

    private func seek(_ x: CGFloat) { player.seek(toFraction: Double(x / max(width, 1))) }

    private func sample(_ column: Int, of columns: Int) -> Float {
        let start = column * peaks.count / columns
        let end = max((column + 1) * peaks.count / columns, start + 1)
        return peaks[start..<min(end, peaks.count)].max() ?? 0
    }

    private func format(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}
```

- [ ] **Step 2: Popover de señal con medidores**

`Aether/AetherCore/SignalPopover.swift`:

```swift
import AetherCore
import SwiftUI

struct SignalPopover: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            SectionLabel("Cadena de señal")
            if let signal = player.signal, let now = player.current {
                row("Fuente", now.formatLabel)
                row("Salida", "\(signal.deviceName) · \(Int(signal.deviceRate)) Hz")
                row("Ganancia", "0.0 dB (volumen en el sistema)")
                Readout(signal.isBitPerfect ? "BIT-PERFECT" : "REMUESTREADO \(Int(signal.sourceRate)) → \(Int(signal.deviceRate)) Hz",
                        tone: signal.isBitPerfect ? .signal : .fault)
            }
            SectionLabel("Nivel")
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: player.state != .playing)) { _ in
                LevelMeter(levels: player.engine.meter.current)
            }
        }
        .padding(Tokens.Space.l)
        .frame(width: 300)
        .onAppear { player.meteringVisible = true }
        .onDisappear { player.meteringVisible = false }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent { Readout(value, tone: .primary) } label: { Text(label).foregroundStyle(.secondary) }
    }
}

struct LevelMeter: View {
    let levels: MeterTap.Levels

    var body: some View {
        VStack(spacing: Tokens.Space.xs) {
            ForEach(levels.peak.indices, id: \.self) { ch in
                let db = 20 * log10(max(Double(levels.peak[ch]), 0.000_01))
                let fraction = min(max((db + 60) / 60, 0), 1)
                HStack(spacing: Tokens.Space.s) {
                    Readout(ch == 0 ? "L" : "R", tone: .tertiary)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.hairline)
                        Capsule().fill(db > -0.1 ? AnyShapeStyle(Tokens.fault) : AnyShapeStyle(Tokens.signal))
                            .scaleEffect(x: fraction, y: 1, anchor: .leading)
                    }
                    .frame(height: 3)
                    Readout(db <= -60 ? "-∞" : String(format: "%.1f", db)).frame(width: 40, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Medidor de nivel")
    }
}
```

- [ ] **Step 3: Cápsula de transporte**

`Aether/AetherCore/TransportBar.swift`:

```swift
import SwiftUI

struct TransportBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale
    @State private var showSignal = false

    var body: some View {
        if let now = player.current {
            GlassEffectContainer(spacing: Tokens.Space.s) {
                HStack(spacing: Tokens.Space.m) {
                    artwork(now)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(now.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(now.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 180, alignment: .leading)

                    HStack(spacing: Tokens.Space.xs) {
                        transportButton("backward.fill", "Anterior") { player.previous() }
                        transportButton(player.state == .playing ? "pause.fill" : "play.fill",
                                        player.state == .playing ? "Pausa" : "Reproducir") { player.toggle() }
                        transportButton("forward.fill", "Siguiente") { player.next() }
                    }

                    WaveformScrubber(peaks: player.waveform)
                        .frame(minWidth: 200)

                    Button { showSignal.toggle() } label: {
                        Readout(player.signal.map { $0.isBitPerfect ? "\(now.formatLabel) · BIT-PERFECT" : now.formatLabel } ?? now.formatLabel,
                                tone: player.signal?.isBitPerfect == true ? .signal : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cadena de señal")
                    .popover(isPresented: $showSignal, arrowEdge: .top) { SignalPopover() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, Tokens.Space.s)
                .background {
                    if reduceTransparency { Capsule().fill(Tokens.surface).overlay(Capsule().strokeBorder(Tokens.hairline)) }
                }
                .glassEffect(reduceTransparency ? .identity : .regular, in: .capsule)
            }
            .padding(.horizontal, Tokens.Space.l)
            .padding(.bottom, Tokens.Space.m)
        }
    }

    private func artwork(_ now: NowPlaying) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Tokens.surface)
            if let cg = now.artwork {
                Image(decorative: cg, scale: displayScale).resizable().scaledToFill()
            } else {
                Image(systemName: "waveform").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(.rect(cornerRadius: 4))
    }

    private func transportButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body).frame(width: 28, height: 24)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(label))
    }
}
```

- [ ] **Step 4: Integrar en la ventana, teclado y menú Control**

En `RootView`, sobre el `NavigationSplitView` (después de `.inspector`):

```swift
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TransportBar()
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Tokens.Motion.enter, value: model.player.current?.url)
        .onKeyPress(.space) {
            // Text fields consume space first, so this only fires from tables/lists/background.
            model.player.toggle()
            return .handled
        }
```

con `@Environment(\.accessibilityReduceMotion) private var reduceMotion` en `RootView`.

En `AetherCommands`:

```swift
        CommandMenu("Control") {
            Button(model.player.state == .playing ? "Pausa" : "Reproducir") { model.player.toggle() }
                .disabled(model.player.current == nil && model.player.queue.current == nil)
            Button("Siguiente") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Anterior") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Avanzar 10 s") { model.player.skip(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Retroceder 10 s") { model.player.skip(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
```

(El menú muestra "Reproducir" sin atajo visible: Espacio lo gestiona `onKeyPress` en la raíz, como en Música, sin robar espacios a los campos de texto.)

En `CosmosBrowserView`, cambiar `primaryAction` del menú contextual por:

```swift
        } primaryAction: { ids in
            let urls = store.visible.map(store.url(for:))
            guard let first = store.visible.firstIndex(where: { ids.contains($0.id) }) else { return }
            player.play(urls: urls, startAt: first)
        }
```

con `@Environment(PlayerModel.self) private var player`. En `HarvesterHistoryView`, añadir al menú contextual `Button("Reproducir") { player.play(urls: entries.map(\.fileURL), startAt: 0) }` donde `entries = store.history.filter { ids.contains($0.id) }`.

En `SettingsView`, añadir:

```swift
            Tab("Aether Core", systemImage: "waveform") { CoreSettings() }
```

```swift
private struct CoreSettings: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Bit-perfect: ajustar el sample rate del DAC a cada pista", isOn: $preferences.bitPerfect)
                Text("Aether devuelve el sample rate original al salir. El volumen se controla en el sistema o en el DAC.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { SectionLabel("Salida") }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 5: Verificación manual (con un DAC externo si hay)**

1. Doble clic en una pista FLAC 24/96 de Cosmos: aparece la cápsula de vidrio abajo (fundido + 8 pt, 220 ms); Audio MIDI Setup muestra el DAC a 96 kHz; la lectura dice `FLAC 24/96 · BIT-PERFECT` en verde.
2. Pasar a una pista 16/44.1: el DAC cambia a 44.1 kHz sin clics audibles largos; la reproducción continúa.
3. Espacio pausa/reanuda desde la tabla; escribir en el buscador **no** pausa.
4. Teclas multimedia del teclado y el widget Now Playing del Centro de control funcionan.
5. Con *Reducir transparencia* activado la cápsula es sólida; con *Reducir movimiento* solo hay fundido.
6. Activity Monitor: CPU de Aether < 3 % reproduciendo con el popover cerrado; ≈0 % en pausa.
7. Salir con ⌘Q: el DAC vuelve a su sample rate anterior.

- [ ] **Step 6: Commit**

```bash
git add Aether
git commit -m "feat(aethercore-ui): add Liquid Glass transport capsule, waveform scrubber and signal path popover"
```

---

### Task 6: Preescucha de resultados de Tidal (base: caché local)

**Files:**
- Create: `Aether/AetherCore/PreviewCache.swift`
- Modify: `Aether/AetherCore/PlayerModel.swift` (`preview(_:)`, `previewingTrackID`, `isPreparingPreview`)
- Modify: `Aether/Harvester/TrackTable.swift` (botón de preescucha por fila)
- Modify: `Aether/App/AppModel.swift` (pasar `HiFiClient` actual)

**Interfaces:**
- Consumes: `HarvestPipeline`, `HarvestRequest`, `SegmentFetcher`, `HiFiClient`, `TidalTrack`.
- Produces: `actor PreviewCache { init(directory: URL, limitBytes: Int64 = 500_000_000); func file(for: TidalTrack, client: HiFiClient) async throws -> URL; func purge() }`; en `PlayerModel`: `func preview(_ track: TidalTrack, client: HiFiClient)`, `private(set) var previewingTrackID: Int?`, `private(set) var isPreparingPreview: Bool`

- [ ] **Step 1: Caché de preescucha**

`Aether/AetherCore/PreviewCache.swift`:

```swift
import Foundation
import Harvester
import HiFiClient

/// Previews reuse the verified Harvester pipeline at 16/44.1 into ~/Library/Caches (LRU, 500 MB cap).
actor PreviewCache {
    private let directory: URL
    private let limitBytes: Int64

    init(directory: URL = URL.cachesDirectory.appending(path: "Aether/Preview"), limitBytes: Int64 = 500_000_000) {
        self.directory = directory
        self.limitBytes = limitBytes
    }

    func file(for track: TidalTrack, client: HiFiClient) async throws -> URL {
        let folder = directory.appending(path: "\(track.id)", directoryHint: .isDirectory)
        if let existing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "flac" }) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: existing.path)
            return existing
        }
        let session = SegmentFetcher.makeAudioSession()
        let pipeline = HarvestPipeline(client: HiFiClient(baseURL: client.baseURL, session: session),
                                       fetcher: SegmentFetcher(session: session), albumLookup: { _ in nil })
        let request = HarvestRequest(track: track, destinationFolder: folder, genre: nil, policy: .lossless)
        let result = try await pipeline.execute(request) { _ in }
        purge()
        return result.fileURL
    }

    func purge() {
        let files = Self.listFlacs(in: directory)
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limitBytes {
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
            total -= file.size
        }
    }

    /// Synchronous: NSDirectoryEnumerator iteration is unavailable from async contexts.
    private nonisolated static func listFlacs(in directory: URL) -> [(url: URL, date: Date, size: Int64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var files: [(url: URL, date: Date, size: Int64)] = []
        for case let url as URL in enumerator where url.pathExtension == "flac" {
            let v = try? url.resourceValues(forKeys: Set(keys))
            files.append((url, v?.contentModificationDate ?? .distantPast, Int64(v?.totalFileAllocatedSize ?? 0)))
        }
        return files
    }
}
```

- [ ] **Step 2: `PlayerModel.preview`**

```swift
    private(set) var previewingTrackID: Int?
    private(set) var isPreparingPreview = false
    @ObservationIgnored private let previewCache = PreviewCache()

    func preview(_ track: TidalTrack, client: HiFiClient) {
        if previewingTrackID == track.id, current != nil { toggle(); return }
        previewingTrackID = track.id
        isPreparingPreview = true
        Task {
            defer { isPreparingPreview = false }
            guard let url = try? await previewCache.file(for: track, client: client), previewingTrackID == track.id else { return }
            play(urls: [url], startAt: 0)
        }
    }
```

(`import HiFiClient` en `PlayerModel.swift`.) `HarvesterStore` expone `var currentClient: HiFiClient { client }`.

- [ ] **Step 3: Botón por fila**

En `TrackTable`, columna inicial (antes de la de "Master"):

```swift
            TableColumn("") { track in
                Button {
                    player.preview(track, client: store.currentClient)
                } label: {
                    if player.isPreparingPreview && player.previewingTrackID == track.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: player.previewingTrackID == track.id && player.state == .playing ? "pause.fill" : "play.fill")
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Preescuchar")
            }
            .width(22)
```

con `@Environment(PlayerModel.self) private var player`.

- [ ] **Step 4: Verificar**

A mano: en la búsqueda, pulsar ▶︎ en una fila → indicador → suena en ≲ 5–10 s (16/44.1) en la cápsula; repetir la misma pista → instantáneo (caché). `~/Library/Caches/Aether/Preview` no supera 500 MB.

- [ ] **Step 5: Commit**

```bash
git add Aether
git commit -m "feat(aethercore): preview Tidal search results through a verified local cache"
```

---

### Task 7 (solo si S2 = PASS): Preescucha en streaming desde los frames DASH

**Files:**
- Create: `Packages/AetherKit/Sources/AetherCore/DashFlacStream.swift`
- Modify: `Packages/AetherKit/Sources/AetherCore/PlaybackEngine.swift` (`loadStream`)
- Modify: `Aether/AetherCore/PlayerModel.swift` (`preview` usa streaming y cae a caché si falla)
- Test: `Packages/AetherKit/Tests/AetherCoreTests/DashFlacStreamTests.swift`

**Interfaces:**
- Consumes: `DashManifest`, `FMP4Flac`, `SegmentFetcher` (Harvester → **no**: AetherCore no depende de Harvester; se pasa un closure `fetch: @Sendable (URL) async throws -> [UInt8]`), cookie validada en `docs/spikes.md`.
- Produces:
  - `public final class FlacPacketDecoder { init(config: FlacTrackConfig, cookie: Data, maxPacketSize: Int) throws; func decode(segment: [UInt8]) throws -> AVAudioPCMBuffer; var outputFormat: AVAudioFormat }`
  - `public enum StreamCookie { static func make(from initSegment: [UInt8]) throws -> Data }` — implementa la variante que pasó S2.
  - `PlaybackEngine.loadStream(manifest: DashManifest, initSegment: [UInt8], fetch: @escaping @Sendable (URL) async throws -> [UInt8]) async throws -> LoadedTrack` — agenda buffers PCM con contrapresión (≤ 3 segmentos por delante).

- [ ] **Step 1: Prueba que falla (offline, con fixtures)**

`Packages/AetherKit/Tests/AetherCoreTests/DashFlacStreamTests.swift`:

```swift
import FlacKit
import Foundation
import TagKit
import Testing
@testable import AetherCore
import TestSupport

@Suite struct DashFlacStreamTests {
    @Test func decodesASegmentToTheRightFrameCount() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2)
        let bytes = [UInt8](try Data(contentsOf: url))
        let si = try FlacMetadataIO.read(url).streamInfo()
        let scan = try FlacFrameScanner.scan(fileAt: url, collectOffsets: true)
        let offsets = scan.frameOffsets! + [bytes.count]
        let frames = (0..<10).map { Array(bytes[offsets[$0]..<offsets[$0 + 1]]) }
        let initSegment = MP4Fixture.initSegment(streamInfo: si)
        let decoder = try FlacPacketDecoder(config: try FMP4Flac.parseInit(initSegment),
                                            cookie: try StreamCookie.make(from: initSegment),
                                            maxPacketSize: frames.map(\.count).max()!)
        let pcm = try decoder.decode(segment: MP4Fixture.mediaSegment(frames: frames, duration: UInt32(si.maxBlockSize)))
        #expect(Int(pcm.frameLength) == 10 * Int(si.maxBlockSize))
    }
}
```

Run: `swift test --package-path Packages/AetherKit --filter DashFlacStreamTests`
Expected: FAIL de compilación — `cannot find 'FlacPacketDecoder' in scope`.

- [ ] **Step 2: Decodificador de paquetes**

`Packages/AetherKit/Sources/AetherCore/DashFlacStream.swift`:

```swift
@preconcurrency public import AVFAudio
import ByteKit
public import FlacKit
public import Foundation

public enum StreamCookie {
    /// Variant validated by spike S2 (docs/spikes.md). Default: the full `dfLa` box.
    public static func make(from initSegment: [UInt8]) throws -> Data {
        guard let dfLa = try MP4.find(["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"], in: initSegment) else {
            throw MP4Error.missing("dfLa")
        }
        return Data(initSegment[dfLa.start..<dfLa.payload.upperBound])
    }
}

public final class FlacPacketDecoder {
    public let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let maxPacketSize: Int
    private let blockSize: AVAudioFrameCount

    public init(config: FlacTrackConfig, cookie: Data, maxPacketSize: Int) throws {
        let si = config.streamInfo
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(si.sampleRate), mFormatID: kAudioFormatFLAC,
            mFormatFlags: si.bitsPerSample == 16 ? 1 : (si.bitsPerSample == 24 ? 3 : 4),
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(si.maxBlockSize), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(si.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(standardFormatWithSampleRate: Double(si.sampleRate), channels: AVAudioChannelCount(si.channels))
        else { throw MP4Error.unsupported("FLAC stream format") }
        input.magicCookie = cookie
        guard let converter = AVAudioConverter(from: input, to: output) else { throw MP4Error.unsupported("FLAC decoder") }
        inputFormat = input
        outputFormat = output
        self.converter = converter
        self.maxPacketSize = maxPacketSize
        blockSize = AVAudioFrameCount(si.maxBlockSize)
    }

    public func decode(segment bytes: [UInt8]) throws -> AVAudioPCMBuffer {
        let parsed = try FMP4Flac.parseMediaSegment(bytes)
        let sizes = try packetSizes(bytes)
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(sizes.count),
                                                 maximumPacketSize: max(maxPacketSize, sizes.max() ?? 0))
        var offset = 0
        for range in parsed.frameRanges {
            bytes[range].withUnsafeBytes { compressed.data.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: range.count) }
            offset += range.count
        }
        var start = 0
        for (i, size) in sizes.enumerated() {
            compressed.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: Int64(start), mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
            start += size
        }
        compressed.packetCount = AVAudioPacketCount(sizes.count)
        compressed.byteLength = UInt32(offset)

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(parsed.samples) + blockSize) else {
            throw MP4Error.unsupported("PCM buffer")
        }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if delivered { outStatus.pointee = .noDataNow; return nil }
            delivered = true
            outStatus.pointee = .haveData
            return compressed
        }
        if status == .error { throw error ?? MP4Error.unsupported("decode") }
        return pcm
    }

    /// Per-sample sizes from `trun` (FMP4Flac validates their sum against mdat).
    private func packetSizes(_ bytes: [UInt8]) throws -> [Int] {
        guard let trun = try MP4.find(["moof", "traf", "trun"], in: bytes) else { throw MP4Error.missing("trun") }
        var r = ByteReader(Array(bytes[trun.payload]))
        let flags = try r.u32BE() & 0xFF_FFFF
        let count = Int(try r.u32BE())
        if flags & 0x001 != 0 { try r.skip(4) }
        if flags & 0x004 != 0 { try r.skip(4) }
        guard flags & 0x200 != 0 else { throw MP4Error.unsupported("trun without sample sizes") }
        var sizes: [Int] = []
        sizes.reserveCapacity(count)
        for _ in 0..<count {
            if flags & 0x100 != 0 { try r.skip(4) }
            sizes.append(Int(try r.u32BE()))
            if flags & 0x400 != 0 { try r.skip(4) }
            if flags & 0x800 != 0 { try r.skip(4) }
        }
        return sizes
    }
}
```

- [ ] **Step 3: Streaming en el motor (contrapresión de 3 segmentos)**

Añadir a `PlaybackEngine`:

```swift
    private var streamTask: Task<Void, Never>?

    /// Streams DASH: fetch → decode → schedule, keeping ≤ 3 segments queued in the player node.
    public func loadStream(manifest: DashManifest, initSegment: [UInt8], bitDepth: Int?,
                           fetch: @escaping @Sendable (URL) async throws -> [UInt8]) async throws -> LoadedTrack {
        stop()
        streamTask?.cancel()
        file = nil
        let config = try FMP4Flac.parseInit(initSegment)
        let decoder = try FlacPacketDecoder(config: config, cookie: try StreamCookie.make(from: initSegment), maxPacketSize: 1 << 20)
        let format = decoder.outputFormat
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        let loaded = LoadedTrack(url: manifest.initializationURL, sampleRate: format.sampleRate,
                                 channels: Int(format.channelCount), bitDepth: bitDepth, frames: Int64(manifest.totalSamples))
        track = loaded
        generation += 1
        let token = generation
        let inFlight = InFlightCounter()
        streamTask = Task { [weak self] in
            for number in manifest.segmentNumbers {
                while inFlight.value >= 3 { try? await Task.sleep(for: .milliseconds(100)) }
                guard !Task.isCancelled, let bytes = try? await fetch(manifest.mediaURL(number: number)),
                      let pcm = try? decoder.decode(segment: bytes), let self, self.generation == token else { return }
                inFlight.increment()
                self.player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { _ in inFlight.decrement() }
            }
        }
        player.play()
        state = .playing
        return loaded
    }
```

con un contador `Sendable` local:

```swift
private final class InFlightCounter: Sendable {
    private let value_ = Mutex(0)
    var value: Int { value_.withLock { $0 } }
    func increment() { value_.withLock { $0 += 1 } }
    func decrement() { value_.withLock { $0 -= 1 } }
}
```

(`import Synchronization`, `import HiFiClient` para `DashManifest`.) Seek en streaming queda fuera de v1: en preescucha, el scrubber se deshabilita (`player.duration` vale, `currentTime` usa el reloj del nodo).

- [ ] **Step 4: `PlayerModel.preview` usa streaming con caída a caché**

```swift
    func preview(_ track: TidalTrack, client: HiFiClient) {
        if previewingTrackID == track.id, current != nil { toggle(); return }
        previewingTrackID = track.id
        isPreparingPreview = true
        Task {
            defer { isPreparingPreview = false }
            let session = URLSession(configuration: .ephemeral)
            do {
                let info = try await client.playbackInfo(trackID: track.id, quality: .lossless)
                let manifest = try info.dashManifest()
                let (initData, _) = try await session.data(from: manifest.initializationURL)
                _ = try await engine.loadStream(manifest: manifest, initSegment: [UInt8](initData), bitDepth: info.bitDepth) { url in
                    [UInt8](try await session.data(from: url).0)
                }
                current = NowPlaying(url: manifest.initializationURL, title: track.displayTitle, artist: track.allArtistNames,
                                     album: track.album?.title, formatLabel: "TIDAL · \(info.bitDepth ?? 16)/44.1 · STREAM", artwork: nil)
                waveform = []
            } catch {
                guard let url = try? await previewCache.file(for: track, client: client), previewingTrackID == track.id else { return }
                play(urls: [url], startAt: 0)
            }
        }
    }
```

- [ ] **Step 5: Verificar**

Run: `swift test --package-path Packages/AetherKit --filter DashFlacStreamTests`
Expected: PASS. A mano: ▶︎ en un resultado suena en < 1.5 s.

- [ ] **Step 6: Commit**

```bash
git add Packages/AetherKit Aether
git commit -m "feat(aethercore): stream Tidal previews by decoding DASH FLAC frames directly"
```
