# Auditoría de Rendimiento y Calidad — Aether

Esta auditoría evalúa **Aether** (`Aether` app + paquete `AetherKit`) aplicando las reglas de los 7 skills instalados:
- **`swiftui-performance-audit`** & **`swiftui-expert-skill`** & **`swiftui-pro`** (Invalidación de `@Observable`, límites de subvistas, `TimelineView`, accesibilidad).
- **`swift-concurrency`** & **`swift-concurrency-pro`** & **`write-swift`** (Modelo de concurrencia de Swift 6.2, reentrancia de actores, `Task.detached` vs `@concurrent`, cancelación cooperativa).
- **`swift-testing-pro`** (Pruebas parametrizadas y determinismo en `AetherTests`).

> [!NOTE]
> El proyecto ya cuenta con una base sólida: presupuestos medidos en [performance.md](file:///Users/jazar/Documents/Projects/Aether/docs/performance.md), `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` con `SWIFT_APPROACHABLE_CONCURRENCY = YES`, y uso de Swift Testing en `AetherTests`. Los hallazgos a continuación se enfocan en problemas reales de invalidación en caliente, concurrencia y fugas de recursos.

---

## Resumen de Hallazgos Priorizados

| # | Prioridad | Categoría | Archivo / Símbolo | Impacto |
|---|---|---|---|---|
| **1** | **Alta** | Invalidación `@Observable` (Fan-out) | [HarvesterStore.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/HarvesterStore.swift#L48-L49), [SidebarView.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/Shell/SidebarView.swift#L15), [HarvesterQueueView.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/HarvesterQueueView.swift#L22-L28) | Cada tick de progreso (10 Hz por descarga) invalida toda la barra lateral y la lista completa de la cola. |
| **2** | **Alta** | Concurrencia / Cancelación y Fuga de Sesión | [PlayerModel.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/AetherCore/PlayerModel.swift#L82-L111) (`preview(_:client:)`) | Tarea no estructurada sin cancelación al cambiar de pista y creación de `URLSession(configuration: .ephemeral)` sin `finishTasksAndInvalidate()`. |
| **3** | **Alta** | Límites de Subvista (`View` Invalidation Boundary) | [TrackTable.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/TrackTable.swift#L60-L94) (`row(_:)`) | `row(_:)` es un método, no un `View` separado: cambios en `player.state` o `previewingTrackID` re-evalúan toda la tabla de pistas. |
| **4** | **Media** | Doble `TimelineView` activo a 15 Hz | [TransportBar.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/AetherCore/TransportBar.swift#L30-L38) (`ProgressLine`) | Dos instancias de `ProgressLine` montadas simultáneamente duplican los ticks de `TimelineView` (30 Hz totales en vez de 15 Hz). |
| **5** | **Media** | `Task.detached` y decodificación muerta de `WaveformAnalyzer` | [PlayerModel.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/AetherCore/PlayerModel.swift#L157-L162) (`load(_:autoplay:)`) | `async let` envolviendo `Task.detached(...).value` impide que `loadTask?.cancel()` propague la cancelación, y `WaveformAnalyzer.peaks` decodifica todo el archivo FLAC aunque ninguna vista lee `player.waveform`. |
| **6** | **Media** | Reentrancia de Actor en caché de álbumes | [HarvesterStore.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/HarvesterStore.swift#L308-L320) (`AlbumCache`) | Descargas simultáneas del mismo álbum disparan peticiones HTTP duplicadas antes de que se escriba el caché tras el `await`. |
| **7** | **Media** | Costo de `CosmosStore.recompute()` + filtrado en `body` | [CosmosStore.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/Cosmos/CosmosStore.swift#L46-L50), [SidebarView.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/Shell/SidebarView.swift#L28) | `inboxCount`, `untaggedCount` y `lossyCount` recorren `items` en cada lectura de `SidebarView`; `ForEach` filtra carpetas inline en `body`. |
| **8** | **Baja** | Árbol de Accesibilidad y `Canvas` a 15 Hz | [WaveformScrubber.swift](file:///Users/jazar/Documents/Projects/Aether/Aether/AetherCore/WaveformScrubber.swift#L11-L39) | Los modificadores `.accessibilityValue` están dentro del `TimelineView` a 15 Hz y `Canvas` ejecuta `context.fill` por columna en cada frame. |
| **9** | **Baja** | Pruebas Parametrizadas en Swift Testing | [CosmosStoreTests.swift](file:///Users/jazar/Documents/Projects/Aether/AetherTests/CosmosStoreTests.swift#L15-L28) | Múltiples `#expect` independientes en un solo test que se benefician de `@Test(arguments:)`. |

---

## Detalle por Hallazgo y Solución Propuesta

### 1. Fan-out de `@Observable` en `HarvesterStore` y `JobModel` (`swiftui-performance-audit` / `swiftui-expert-skill`)

En [`JobModel`](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/JobModel.swift#L7-L14), el comentario indica:
> `/// One observable per queue row: a progress tick invalidates only its own row.`

Sin embargo, [`HarvesterStore.activeCount`](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/HarvesterStore.swift#L48) y [`HarvesterStore.failedCount`](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/HarvesterStore.swift#L49) se calculan leyendo `job.phase` sobre todos los elementos de `jobs`:
- [`SidebarView`](file:///Users/jazar/Documents/Projects/Aether/Aether/Shell/SidebarView.swift#L15) lee `.badge(harvester.activeCount)`.
- [`HarvesterQueueView`](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/HarvesterQueueView.swift#L22-L28) lee `store.activeCount`, `store.failedCount` y `store.jobs.contains { $0.phase.isTerminal }`.

Como `job.phase` contiene el payload de progreso (`.downloading(segment, total, bytes, rate)` y `.verifying(fraction)`), **cada actualización de progreso a 10 Hz muta `job.phase` y dispara la re-evaluación de `SidebarView` y `HarvesterQueueView` completas**.

```swift
// Antes (HarvesterStore.swift)
var activeCount: Int { jobs.count { !$0.phase.isTerminal } }
var failedCount: Int { jobs.count { if case .failed = $0.phase { true } else { false } } }

// Después (HarvesterStore.swift) — actualizar solo cuando cambia el estado terminal
private(set) var activeCount = 0
private(set) var failedCount = 0
private(set) var hasFinishedJobs = false
```
Llamar a `refreshJobCounts()` únicamente en `register(_:)`, `retryFailed()`, `clearFinished()`, y dentro de `handle(_:)` cuando `wasTerminal != event.phase.isTerminal || event.phase == .queued` elimina por completo las invalidaciones a 10 Hz sobre `SidebarView` y `HarvesterQueueView`.

---

### 2. Tarea huérfana y fuga de `URLSession` en `PlayerModel.preview(_:client:)` (`swift-concurrency-pro` / `write-swift`)

En [`PlayerModel.preview(_:client:)`](file:///Users/jazar/Documents/Projects/Aether/Aether/AetherCore/PlayerModel.swift#L82-L111):
1. El `Task { ... }` de línea 86 no se almacena ni se cancela cuando el usuario pulsa otra pista o reproduce un archivo local en `load(_:autoplay:)`.
2. Se crea `URLSession(configuration: .ephemeral)` en cada preescucha (línea 88) y se captura en el closure de streaming (`engine.loadStream`), sin reutilizar sesión ni invalidarla.
3. En [`PlayerModel.swift#L170`](file:///Users/jazar/Documents/Projects/Aether/Aether/AetherCore/PlayerModel.swift#L170), `waveformCache.removeValue(forKey: waveformCache.keys.first!)` usa force-unwrap sobre orden de diccionario arbitrario.

```swift
// Después (PlayerModel.swift)
@ObservationIgnored private let previewSession = URLSession(configuration: .ephemeral)
@ObservationIgnored private var previewTask: Task<Void, Never>?
```
Cancelar `previewTask?.cancel()` tanto al iniciar un nuevo `preview` como en `load(_:autoplay:)` y `shutdown()`.

---

### 3. Extraer fila de `TrackTable` como subvista independiente (`swiftui-expert-skill`)

En [`TrackTable.swift`](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/TrackTable.swift#L60-L94), `row(_ track: TidalTrack)` es un método de `TrackTable` que lee `player.isPreparingPreview`, `player.previewingTrackID`, `player.state` y `store.masterMatch(for: track)`.
Cualquier cambio en el estado del reproductor invalida el `body` de `TrackTable` completo y todas las filas visibles. Extraer `TrackRowView` y `TrackPreviewButton` aísla la invalidación exclusivamente al botón de 22 pt afectado.

---

### 4. Pausar el `TimelineView` oculto en `TransportBar` (`swiftui-performance-audit`)

En [`TransportBar.swift`](file:///Users/jazar/Documents/Projects/Aether/Aether/AetherCore/TransportBar.swift#L30-L38), se montan dos instancias de `ProgressLine` (`expanded: false` y `expanded: true`) al mismo tiempo ocultando una con `.opacity`. Cada una instancia su propio `TimelineView` a 15 Hz.
Pasar `isActive: !scrubbing` y `isActive: scrubbing` al parámetro `paused: player.state != .playing || !isActive` del `TimelineView` conserva ambas vistas montadas en el `ZStack` (evitando el crash `"no subgraph"` de `AttributeGraph`) pero reduce a la mitad las evaluaciones por segundo durante la reproducción.

---

### 5. Reemplazar `Task.detached` por `@concurrent` y eliminar decodificación muerta de `WaveformAnalyzer` (`write-swift` / `swift-concurrency`)

En [`PlayerModel.load(_:autoplay:)`](file:///Users/jazar/Documents/Projects/Aether/Aether/AetherCore/PlayerModel.swift#L157-L162):
- `Task.detached` dentro de `async let` rompe la propagación de cancelación de `loadTask`.
- Además, `WaveformAnalyzer.peaks(for: url, bins: 1200)` decodifica el archivo FLAC entero en cada carga de pista aunque ninguna vista lee `player.waveform` (desde que `TransportBar` usa `ProgressLine`).
Definir helpers `nonisolated` marcados con `@concurrent` para metadatos/portada, eliminar la llamada innecesaria a `WaveformAnalyzer.peaks` en `PlayerModel.load`, y agregar `try Task.checkCancellation()` en `WaveformAnalyzer.peaks` ahorra cientos de milisegundos de CPU y E/S por pista.

---

### 6. Reentrancia en `AlbumCache` (`swift-concurrency-pro` / `write-swift`)

En [`HarvesterStore.swift`](file:///Users/jazar/Documents/Projects/Aether/Aether/Harvester/HarvesterStore.swift#L308-L320), coalescer las peticiones en vuelo mediante `inFlight: [Int: Task<TidalAlbum?, Never>]` evita que 3 descargas simultáneas de un mismo álbum hagan 3 llamadas HTTP idénticas a `client.album(id:)`.

---

### 7. Contadores precalculados en `CosmosStore` y filtrado fuera de `ForEach` (`swiftui-performance-audit`)

En [`CosmosStore.swift`](file:///Users/jazar/Documents/Projects/Aether/Aether/Cosmos/CosmosStore.swift#L46-L50), `inboxCount`, `untaggedCount` y `lossyCount` hacen `items.count { ... }` O(N) en cada lectura, y [`SidebarView.swift`](file:///Users/jazar/Documents/Projects/Aether/Aether/Shell/SidebarView.swift#L28) ejecuta `cosmos.folders.filter { $0.name != preferences.inboxFolderName }` dentro de `ForEach`.
Precalcular estos contadores y `sidebarFolders` dentro de `CosmosStore` hace que `SidebarView` lea propiedades O(1) sin trabajo derivado en `body`.

---

### 8. Accesibilidad y `Canvas` en `WaveformScrubber` (`swiftui-expert-skill` / `swiftui-performance-audit`)

En [`WaveformScrubber.swift`](file:///Users/jazar/Documents/Projects/Aether/Aether/AetherCore/WaveformScrubber.swift#L11-L39):
1. Mover `.accessibilityRepresentation` fuera del `TimelineView` a 15 Hz (igual que `ProgressLine`).
2. En el `Canvas`, construir dos únicos `Path` (`played` y `remaining`) y rellenarlos una sola vez por frame evita cientos de llamadas individuales a `context.fill(Path(rect), ...)`.

---

### 9. Pruebas Parametrizadas en `CosmosStoreTests` (`swift-testing-pro`)

En [`CosmosStoreTests.swift`](file:///Users/jazar/Documents/Projects/Aether/AetherTests/CosmosStoreTests.swift#L15-L28), separar los casos de filtrado con `@Test(arguments:)` permite ejecutarlos en paralelo y diagnosticar inmediatamente qué filtro falló sin detener el resto de casos.
