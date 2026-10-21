# Aether v1 · Plan 08 — Optimización dirigida (reducido, para agentes)

> **Para agentes:** ejecuta las 4 tareas en orden. Una tarea = un commit. No avances si un comando de verificación falla; corrige o detente y reporta. No toques nada fuera de los archivos listados en cada tarea.

**Goal:** (A) dejar de decodificar el archivo entero en cada carga de pista, (B) cancelar correctamente la preescucha, (C) eliminar el fan-out de `@Observable` a 10 Hz sobre `SidebarView`/cola, (D) evitar peticiones HTTP duplicadas de álbum.

**Fuera de alcance (decidido, NO hacer):** extraer `TrackRowView`, pausar `TimelineView` de `TransportBar`, precalcular contadores de `CosmosStore`, optimizar `WaveformScrubber`, parametrizar `CosmosStoreTests`. Fueron descartados tras el análisis de la auditoría (`docs/audit-report.md` puntos 3, 4, 7, 8, 9).

**Stack:** Swift 6.2, SwiftUI macOS 27, `@Observable`, Swift Testing. App target: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

---

## 0. Preflight (obligatorio)

1. `git status --short`. El árbol tiene cambios sin commitear en `PlayerModel.swift`, `HarvesterStore.swift`, `TransportBar.swift`, `SidebarView.swift` y otros. **No los revertas ni los mezcles.** Si el usuario no los commiteó, haz `git stash push -u -m pre-plan08` solo si él lo autoriza; si no, trabaja encima y haz commits con `git add <archivos de la tarea>` únicamente (usa `git add -p` si el archivo ya tenía cambios ajenos).
2. Línea base: `swift test --package-path Packages/AetherKit` y `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' -only-testing:AetherTests test -quiet`. Anota qué falla ya antes de empezar; eso no es culpa tuya.

## 1. Invariantes (violarlos = crash o fallo de compilación)

- **No cambies `List` por `Table`** en `TrackTable.swift` (bug de AppKit en macOS 27).
- **No montes/desmontes `TimelineView`** ni pongas accesibilidad dinámica dentro de uno. Este plan no toca `TransportBar` ni `WaveformScrubber`.
- **No modifiques** `PlaybackEngine.meterBlock` ni `NowPlayingBridge.registerCommands` (closures `nonisolated` llamados desde hilos de CoreAudio/MediaPlayer).
- **Conserva `deferredLookup`** en `AppModel.swift`.
- En `Aether/` todo es `@MainActor` por defecto. Trabajo pesado fuera del main actor ⇒ función `nonisolated` + `@concurrent`.
- Código existente en español/inglés mezclado: sigue el estilo del archivo (comentarios escasos, nombres en inglés).

## 2. Verificación estándar

```bash
swift test --package-path Packages/AetherKit
xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' -only-testing:AetherTests test -quiet
```
Un test concreto: añade `-only-testing:AetherTests/JobModelTests`. Criterio global: **0 errores, 0 warnings nuevos, tests en verde**.

---

## Task A — Quitar la decodificación de waveform muerta (audit #5)

**Hecho verificado:** `grep -rn "\.waveform" Aether` solo coincide dentro de `PlayerModel.swift`; ninguna vista lee `player.waveform`. `WaveformScrubber` tampoco se instancia. `WaveformAnalyzer` (paquete) se conserva: tiene su propio test.

**Archivo:** `Aether/AetherCore/PlayerModel.swift` (único).

Edits exactos:
1. Borrar `private(set) var waveform: [Float] = []`.
2. Borrar `@ObservationIgnored private var waveformCache: [String: [Float]] = [:]`.
3. En `preview(_:client:)` borrar la línea `waveform = []`.
4. En `load(_:autoplay:)`:
   - borrar `let key = ...` y `waveform = waveformCache[key] ?? []`;
   - reescribir el `loadTask` así:
```swift
        loadTask = Task {
            let (t, art) = await Self.readMetadata(at: url)
            guard !Task.isCancelled else { return }
            let stem = url.deletingPathExtension().lastPathComponent
            current = NowPlaying(url: url, title: t.title ?? stem, artist: t.artist ?? "", album: t.album,
                                 formatLabel: probe?.label ?? url.pathExtension.uppercased(), artwork: art)
            nowPlaying.update()
        }
```
5. Añadir helper (mismo tipo, fuera de `load`):
```swift
    @concurrent
    private nonisolated static func readMetadata(at url: URL) async -> (TrackTags, CGImage?) {
        let tags = (try? TagIO.read(url)) ?? TrackTags()
        guard !Task.isCancelled else { return (tags, nil) }
        return (tags, tags.artwork.flatMap { ArtworkProcessor.thumbnail($0.data, maxPixel: 128) })
    }
```
   Con `@concurrent` la cancelación de `loadTask` se propaga (se elimina `Task.detached`/`async let`).

**Verificar:** compila; `grep -n "waveform" Aether/AetherCore/PlayerModel.swift` ⇒ sin resultados; suite estándar en verde. Si algo más referenciaba `waveform` y falla la compilación, **detente y reporta** (no inventes un reemplazo).

**Commit:** `perf(player): drop unused waveform decode on every track load`

---

## Task B — Cancelación de preescucha y reutilización de sesión (audit #2)

**Archivo:** `Aether/AetherCore/PlayerModel.swift` (mismo archivo que A; ya con A aplicado).

Edits exactos:
1. Propiedades:
```swift
    @ObservationIgnored private let previewSession = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var previewTask: Task<Void, Never>?
```
2. `preview(_:client:)`:
   - Tras el `guard`/toggle inicial: `previewTask?.cancel()`.
   - `Task { ... }` ⇒ `previewTask = Task { ... }`.
   - Reemplazar `let session = URLSession(configuration: .ephemeral)` por `let session = previewSession`.
   - **Trampa:** el `defer { isPreparingPreview = false }` de una tarea cancelada pisaría el estado de la preescucha nueva. Cámbialo a `defer { if previewingTrackID == track.id { isPreparingPreview = false } }`.
   - En el `catch`, primera línea: `guard !Task.isCancelled else { return }` (no hacer fallback a caché si fue cancelada).
   - Reemplazar `await Task.detached(priority: .userInitiated, operation: { ArtworkProcessor.thumbnail(data, maxPixel: 128) }).value` por `await Self.decodeThumbnail(data)` con:
```swift
    @concurrent
    private nonisolated static func decodeThumbnail(_ data: Data) async -> CGImage? {
        ArtworkProcessor.thumbnail(data, maxPixel: 128)
    }
```
3. `load(_:autoplay:)`: al inicio (junto a `loadTask?.cancel()`) añadir `previewTask?.cancel(); previewingTrackID = nil; isPreparingPreview = false`.
4. `shutdown()`: añadir `loadTask?.cancel(); previewTask?.cancel()`.

**Ojo:** `play(urls:startAt:)` (usado por el fallback de caché dentro de `preview`) llama a `load`, que ahora cancela `previewTask` y limpia `previewingTrackID`. Ese fallback corre *dentro* de `previewTask`; tras `play(...)` no hay más trabajo, así que es seguro, pero **comprueba** que el botón de preescucha sigue reflejando el estado correcto (si `previewingTrackID` se pone en nil el botón deja de marcarse como activo). Si quieres conservarlo, en el fallback restaura `previewingTrackID = track.id` después de `play(...)`.

**Verificar:** compila; suite estándar en verde; `grep -n "Task.detached\|URLSession(configuration" Aether/AetherCore/PlayerModel.swift` ⇒ solo la línea de `previewSession`.

**Commit:** `fix(player): cancel stale previews and reuse a single URLSession`

---

## Task C — Contadores almacenados en `HarvesterStore` (audit #1)

**Hecho verificado:** `activeCount`/`failedCount` son computados sobre `job.phase`, y los leen `SidebarView.swift:15`, `HarvesterQueueView.swift:22,26`, `AetherCommands.swift:27` y `HarvesterStore.persistQueueAndActivity` (l.273, **lógica de Dock/actividad**). Hay que conservar su semántica exacta.

**Archivos:** `Aether/Harvester/HarvesterStore.swift`, `Aether/Harvester/HarvesterQueueView.swift`, `AetherTests/JobModelTests.swift`.

**Step 1 — RED.** Para poder probar sin red ni disco, relaja `register(_:)` y `handle(_:)` de `private` a internal (sin modificador) en `HarvesterStore`. Añade a `JobModelTests` (reutiliza el helper `job()` / el JSON de `TidalTrack` ya presente; construye un `HarvestRequest` igual que `job()`):
```swift
    @Test func progressTicksDoNotInvalidateSummaryCounts() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = HarvesterStore(preferences: Preferences(defaults: defaults))
        let request = try job().request
        store.register([request])
        let model = try #require(store.jobs.first)
        #expect(store.activeCount == 1)
        #expect(store.failedCount == 0)
        #expect(!store.hasFinishedJobs)

        var invalidated = false
        withObservationTracking {
            _ = store.activeCount; _ = store.failedCount; _ = store.hasFinishedJobs
        } onChange: { invalidated = true }

        await store.handle(HarvestEvent(id: request.id, phase: .downloading(segment: 5, of: 20, bytes: 512_000, bytesPerSecond: 1_000_000)))
        #expect(!invalidated)
        #expect(model.phase != .queued)

        await store.handle(HarvestEvent(id: request.id, phase: .failed("boom")))
        #expect(store.activeCount == 0)
        #expect(store.failedCount == 1)
        #expect(store.hasFinishedJobs)
    }
```
Ajusta los inicializadores reales de `HarvestEvent`/`HarvestPhase.failed` mirando `Packages/AetherKit/Sources/Harvester/HarvestModels.swift`; si `HarvesterStore.init` toca disco/red de forma problemática, deténte y reporta. Ejecuta `-only-testing:AetherTests/JobModelTests` ⇒ debe **fallar/no compilar** (falta `hasFinishedJobs`).

**Step 2 — GREEN.** En `HarvesterStore`:
```swift
    private(set) var activeCount = 0
    private(set) var failedCount = 0
    private(set) var hasFinishedJobs = false

    private func refreshJobCounts() {
        var active = 0, failed = 0, finished = false
        for job in jobs {
            if job.phase.isTerminal {
                finished = true
                if case .failed = job.phase { failed += 1 }
            } else { active += 1 }
        }
        if activeCount != active { activeCount = active }
        if failedCount != failed { failedCount = failed }
        if hasFinishedJobs != finished { hasFinishedJobs = finished }
    }
```
(reemplaza las dos líneas computadas 48–49). Llamar `refreshJobCounts()`:
- al final de `register(_:)`;
- en `retryFailed()` tras `jobs.removeAll`/`jobsByID` y antes de `enqueue` (y `enqueue` ya pasa por `register`);
- al final de `clearFinished()`;
- en `handle(_:)`: `let wasTerminal = job.phase.isTerminal` **antes** de `job.phase = event.phase`; justo después, `if wasTerminal != event.phase.isTerminal || event.phase == .queued { refreshJobCounts() }`. Debe ir **antes** de `persistQueueAndActivity()`, que lee `activeCount`.
- Cualquier otro sitio que mute `jobs`: `grep -n "jobs\." Aether/Harvester/HarvesterStore.swift` y revisa cada uno.

En `HarvesterQueueView.swift`: `.disabled(!store.jobs.contains { $0.phase.isTerminal })` ⇒ `.disabled(!store.hasFinishedJobs)`.

**Verificar:** `-only-testing:AetherTests/JobModelTests` ⇒ PASS; suite estándar en verde. Prueba manual opcional: encolar 2 descargas, ver que el badge del sidebar y el Dock cambian al terminar.

**Commit:** `perf(harvester): store job summary counts so progress ticks stop invalidating sidebar`

---

## Task D — Coalescer peticiones de `AlbumCache` (audit #6)

**Archivos:** `Aether/Harvester/HarvesterStore.swift`, `AetherTests/JobModelTests.swift`.

**Step 1 — RED.** Añade `import os` a `JobModelTests.swift` y:
```swift
    @Test func albumCacheCoalescesConcurrentRequests() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let album = try JSONDecoder().decode(TidalAlbum.self, from: Data(#"{"id":42,"title":"Free Your Mind"}"#.utf8))
        let cache = AlbumCache { id in
            calls.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(40))
            return id == 42 ? album : nil
        }
        async let a = cache.album(42), b = cache.album(42), c = cache.album(42)
        let results = await [a, b, c]
        #expect(results.compactMap { $0 }.count == 3)
        #expect(calls.withLock { $0 } == 1)
    }
```
Si `TidalAlbum` no decodifica con ese JSON, ajusta según `HiFiClient` (mínimo requerido). Ejecuta ⇒ debe **no compilar** (`AlbumCache` es `private` y sin `init(fetch:)`).

**Step 2 — GREEN.** Reemplaza `private actor AlbumCache` (final de `HarvesterStore.swift`, uso en l.72 `AlbumCache(client: client)` se mantiene) por:
```swift
/// Album metadata is shared by every track of an album: fetch once, even across concurrent downloads.
actor AlbumCache {
    private let fetch: @Sendable (Int) async -> TidalAlbum?
    private var cache: [Int: TidalAlbum] = [:]
    private var inFlight: [Int: Task<TidalAlbum?, Never>] = [:]

    init(client: HiFiClient) { fetch = { id in try? await client.album(id: id).album } }
    init(fetch: @escaping @Sendable (Int) async -> TidalAlbum?) { self.fetch = fetch }

    func album(_ id: Int) async -> TidalAlbum? {
        guard id != 0 else { return nil }
        if let hit = cache[id] { return hit }
        if let existing = inFlight[id] { return await existing.value }
        let fetch = fetch
        let task = Task { await fetch(id) }
        inFlight[id] = task
        let album = await task.value
        inFlight[id] = nil
        if let album { cache[id] = album }
        return album
    }
}
```
Semántica preservada: fallo de red ⇒ `nil` y no se cachea (se reintenta en la próxima llamada).

**Verificar:** `-only-testing:AetherTests/JobModelTests` ⇒ PASS; suite estándar en verde.

**Commit:** `fix(harvester): coalesce concurrent album fetches`

---

## Definition of Done

- 4 commits (A, B, C, D), cada uno compilando y con tests en verde.
- `grep -rn "waveform" Aether/AetherCore/PlayerModel.swift` ⇒ vacío.
- Suite estándar completa (AetherKit + AetherTests) sin fallos nuevos respecto a la línea base de §0.
- Informe final breve al usuario: qué cambió por tarea, qué tests se añadieron, y cualquier desviación respecto a este plan (especialmente en B, el efecto de `load` sobre `previewingTrackID`).
