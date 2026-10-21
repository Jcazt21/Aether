# Aether v1 · Plan 07 — Calidad: rendimiento, accesibilidad, movimiento, HIG y release

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Demostrar con medidas que v1 cumple los presupuestos de recursos del §4, que es accesible, que el movimiento es correcto y que respeta la HIG de macOS; luego producir el build de release 1.0.

**Architecture:** Sin código nuevo de producto salvo correcciones que salgan de las mediciones. Evidencias en `docs/performance.md`, `docs/accessibility.md` y `docs/hig-review.md`. Trazas de Instruments con el script del skill `swiftui-expert-skill`; auditoría automática con `XCUIApplication.performAccessibilityAudit()`.

**Tech Stack:** Instruments (SwiftUI, Time Profiler, Allocations, Energy), `xctrace`, XCTest, Accessibility Inspector, Icon Composer, `xcodebuild archive`, `notarytool`.

**Spec:** `docs/superpowers/plans/2026-10-20-aether-v1-00-overview.md` (§4, §7, §8)

## Global Constraints

- Cada presupuesto del §4 tiene una medición registrada (valor, fecha, build, máquina). Un presupuesto incumplido bloquea el release.
- Las correcciones de rendimiento se miden antes y después; sin medición no se acepta el cambio.
- Ninguna regresión funcional: `swift test --package-path Packages/AetherKit` y `xcodebuild … test` en verde al final de cada tarea.

Rutas relativas a `~/Documents/Projects/Aether`. `SKILL=~/.claude/skills/swiftui-expert-skill`.

---

### Task 1: Medir los presupuestos de recursos

**Files:**
- Create: `docs/performance.md`
- Modify (solo si una medición falla): ver Step 4

- [ ] **Step 1: Build de release instrumentable**

```bash
xcodebuild -project Aether.xcodeproj -scheme Aether -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/perf build -quiet
open build/perf/Build/Products/Release/Aether.app
python3 $SKILL/scripts/record_trace.py --list-devices
```

Expected: la app abre; el Mac aparece como dispositivo `devices` (usar plantilla `SwiftUI`).

- [ ] **Step 2: Grabar los cuatro escenarios (60 s cada uno)**

```bash
for scenario in idle downloads playback scan; do
  echo "Escenario: $scenario — prepáralo y pulsa Enter"; read
  python3 $SKILL/scripts/record_trace.py --device "$(scutil --get ComputerName)" --attach Aether \
    --stop-file /tmp/stop-aether-trace --output ~/Desktop/aether-$scenario.trace &
  sleep 60; touch /tmp/stop-aether-trace; wait; rm -f /tmp/stop-aether-trace
done
```

Preparación de cada escenario:
- `idle`: app abierta en Master, nada sonando, sin descargas.
- `downloads`: 3 descargas Hi-Res simultáneas en curso (encolar un álbum).
- `playback`: un FLAC 24/96 sonando, popover de señal **cerrado**.
- `scan`: borrar `~/Library/Application Support/Aether/cosmos-index.plist`, abrir la app (escaneo en frío) y luego tocar un archivo del Master (escaneo en caliente).

- [ ] **Step 3: Analizar y registrar**

```bash
for scenario in idle downloads playback scan; do
  python3 $SKILL/scripts/analyze_trace.py --trace ~/Desktop/aether-$scenario.trace --json-only --top 10 > docs/trace-$scenario.json
done
python3 $SKILL/scripts/analyze_trace.py --trace ~/Desktop/aether-scan.trace --list-signposts --signpost-name-contains scan
python3 $SKILL/scripts/analyze_trace.py --trace ~/Desktop/aether-downloads.trace --list-signposts --signpost-name-contains verify
```

Crear `docs/performance.md` con esta tabla, rellenada con los valores medidos (RSS desde Activity Monitor en el mismo minuto):

```markdown
# Aether v1 — Presupuestos de recursos

Build: 1.0 (1) Release · Mac: <modelo/chip> · macOS 27.x · Fecha: <AAAA-MM-DD>

| Escenario | Presupuesto | Medido | ✓/✗ | Evidencia |
|---|---|---|---|---|
| Reposo | CPU ≈ 0 %, 0 timers, RSS < 120 MB | | | trace-idle.json |
| 3 descargas Hi-Res | RSS < 220 MB, CPU < 35 %, sin hitches | | | trace-downloads.json |
| Verificación 24/44.1 4 min | < 1.5 s | | | signpost `verify` |
| Escaneo frío / caliente | < 3 s / < 300 ms | | | signpost `scan` |
| Reproducción local | CPU < 3 % | | | trace-playback.json |
| Tags FLAC con padding | in-place | | | prueba `writeInPlaceWhenPaddingSuffices` |
```

Criterios de lectura (ver `$SKILL/references/trace-analysis.md`): en `idle`, ninguna vista SwiftUI debe actualizarse periódicamente; en `downloads`, las actualizaciones deben limitarse a filas `JobRow` (no a `HarvesterQueueView` entera) y `main_running_coverage_pct` < 25 %; en `playback`, solo `WaveformScrubber` (≤ 15 Hz).

- [ ] **Step 4: Correcciones condicionadas (solo si algo falla)**

**4a. Escaneo frío > 3 s** — el lector de resumen carga los bytes de las portadas. Añadir a `FlacMetadataIO` una lectura que salta payloads de PICTURE:

```swift
    /// Header read for indexing: PICTURE payloads are skipped (seeked over), returned empty.
    public static func readSkippingPictures(_ url: URL) throws -> (header: FlacHeader, hasPicture: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = (try handle.read(upToCount: 10)).map { [UInt8]($0) } ?? []
        let start = try leadingID3Length(head)
        try handle.seek(toOffset: UInt64(start))
        guard (try? handle.readExactly(4)) == magic else { throw FlacError.notFlac }
        var blocks: [FlacBlock] = []
        var offset = start + 4
        var isLast = false
        var hasPicture = false
        while !isLast {
            let h = try handle.readExactly(4)
            isLast = h[0] & 0x80 != 0
            let type = h[0] & 0x7F
            let length = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            if type == FlacBlockType.picture {
                hasPicture = true
                try handle.seek(toOffset: UInt64(offset + 4 + length))
                blocks.append(FlacBlock(type: type, payload: []))
            } else {
                blocks.append(FlacBlock(type: type, payload: try handle.readExactly(length)))
            }
            offset += 4 + length
        }
        return (FlacHeader(blocks: blocks, audioOffset: offset), hasPicture)
    }
```

y usarla en `ItemReader.read` para FLAC (tags desde el VORBIS_COMMENT, `hasArtwork = hasPicture`, `verifiedStamp` del mismo bloque, en una sola lectura). Prueba: `ItemReader` con un FLAC que tiene una portada de 2 MB debe leerse con < 64 KB de E/S (comprobar con `FileHandle` contando bytes en un test, o medir el escaneo antes/después).

**4b. `HarvesterQueueView` se re-evalúa en cada tick** — verificar que `JobRow` recibe `let job: JobModel` y que `HarvesterQueueView` no lee `job.phase`; si `activeCount` en `navigationSubtitle` causa la invalidación, moverlo a una subvista `QueueSubtitle` propia.

**4c. RSS de descargas > 220 MB** — comprobar en Allocations que no hay `Data` de segmentos retenidos: `SegmentFetcher.fetch` devuelve `[UInt8]` y el segmento se suelta tras `assembler.append`; si `URLSession` retiene buffers, usar `session.bytes(from:)` y escribir por bloques de 256 KiB.

Re-medir el escenario afectado y actualizar la tabla.

- [ ] **Step 5: Commit**

```bash
git add docs/performance.md docs/trace-*.json Packages Aether
git commit -m "perf: measure v1 resource budgets and fix regressions found"
```

---

### Task 2: Accesibilidad

**Files:**
- Modify: `AetherUITests/AetherUITests.swift`
- Create: `docs/accessibility.md`

- [ ] **Step 1: Auditoría automática por pantalla**

Añadir a `AetherUITests`:

```swift
    @MainActor
    func testAccessibilityAuditOnEveryScreen() throws {
        let app = XCUIApplication()
        app.launch()
        for key in ["1", "2", "3"] {
            app.typeKey(key, modifierFlags: .command)
            try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .textClipped])
        }
    }
```

Run: `xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' test -only-testing:AetherUITests/AetherUITests/testAccessibilityAuditOnEveryScreen -quiet`
Expected: PASS. Cada fallo se corrige (normalmente: `accessibilityLabel` en botones de icono, contraste de `.tertiary` sobre `canvas`) y se vuelve a ejecutar.

- [ ] **Step 2: Recorrido manual con VoiceOver y teclado (⌘F5)**

Registrar en `docs/accessibility.md` el resultado de cada punto:

```markdown
# Aether v1 — Accesibilidad

| Comprobación | Resultado | Notas |
|---|---|---|
| Tab recorre sidebar → contenido → inspector → cápsula sin trampas | | |
| VoiceOver lee fila de cola: título, estado y progreso ("Descargando 42 por ciento") | | |
| VoiceOver lee la cápsula: título, botones con nombre, posición ajustable (±10 s) | | |
| Lecturas técnicas (SF Mono) se leen como texto, no como dígitos sueltos | | |
| Increase Contrast: hairlines y verde/rojo más intensos | | |
| Reduce Transparency: cápsula sólida | | |
| Reduce Motion: solo fundidos | | |
| Bold Text / tamaño de texto del sistema: sin truncados críticos | | |
| Todo atajo del menú funciona sin ratón (§8) | | |
```

- [ ] **Step 3: Commit**

```bash
git add AetherUITests docs/accessibility.md Aether
git commit -m "a11y: audit every screen and fix accessibility issues"
```

---

### Task 3: Revisión de movimiento e interacción (emil-design-eng)

**Files:**
- Create: `docs/motion-review.md`
- Modify: archivos de UI afectados por la revisión

- [ ] **Step 1: Inventario y revisión con el formato obligatorio Before/After/Why**

Recorrer cada animación de la app (grabar con `⌘⇧5` y revisar a cámara lenta) y documentar en `docs/motion-review.md`:

```markdown
# Aether v1 — Revisión de movimiento

| Elemento | Frecuencia | Animación | Duración/curva | ¿Correcta? |
|---|---|---|---|---|
| Relleno de transferencia (HairlineProgress) | continua | scaleEffect x | 120 ms lineal | |
| Relleno de verificación | continua | scaleEffect x | 120 ms lineal | |
| Cambio de fase de fila | por pista | color/opacidad | 180 ms ease-out | |
| Glifo de estado | por pista | symbolEffect replace | sistema | |
| Aparición de la cápsula | ocasional | opacity + offset 8 pt | 220 ms ease-out | |
| Play/Pausa (Espacio) | cientos/día | ninguna | — | |
| Cambio de ruta ⌘1/⌘2/⌘3 | cientos/día | ninguna | — | |
| Medidores | 30 Hz solo con popover | directo (sin interpolación) | — | |

## Hallazgos

| Before | After | Why |
| --- | --- | --- |
```

Reglas a verificar (de `emil-design-eng`): nada animado en acciones de teclado frecuentes; entradas ease-out ≤ 300 ms y nunca desde escala 0; progreso lineal; salida más rápida que la entrada; *Reduce Motion* conserva solo opacidad; solo se anima `transform`/`opacity` (nada de `frame`/`padding`).

- [ ] **Step 2: Aplicar los hallazgos**

Cada fila de "Hallazgos" se implementa en su archivo. Ejemplo típico que debe comprobarse en `TransportBar`: la salida al terminar la cola usa la misma transición que la entrada → hacerla más rápida:

```swift
.transition(.asymmetric(
    insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)),
    removal: .opacity.animation(.easeOut(duration: 0.12))))
```

- [ ] **Step 3: Commit**

```bash
git add docs/motion-review.md Aether
git commit -m "polish(motion): review and tune every animation against the motion rules"
```

---

### Task 4: Revisión HIG de macOS y Liquid Glass

**Files:**
- Create: `docs/hig-review.md`
- Create (si falta en la revisión): `Aether/App/DockMenu.swift`

- [ ] **Step 1: Checklist HIG (`macos-design-guidelines`) aplicada a Aether**

`docs/hig-review.md`:

```markdown
# Aether v1 — Revisión HIG

| Regla | Implementación | ✓/✗ |
|---|---|---|
| Menús estándar + Harvester, Cosmos, Control | AetherCommands | |
| Toda acción con atajo (§8 del overview) | AetherCommands + toolbars | |
| Menús dinámicos (Pausa/Reproducir, deshabilitados sin selección) | AetherCommands | |
| Menú contextual en filas de búsqueda, cola, historial, Master | TrackTable, JobRow, HistoryView, CosmosBrowserView | |
| Ventana redimensionable, mínimo 960×600, estado restaurado | Window + defaultSize | |
| Toolbar unificada, búsqueda en toolbar | windowToolbarStyle(.unified), .searchable(placement: .toolbar) | |
| Sidebar colapsable (⌃⌘S), source list | SidebarCommands, .listStyle(.sidebar) | |
| Badges en sidebar (Cola, Por clasificar, Revisar) | SidebarView | |
| Esc cierra popovers/hojas; Return = acción por defecto | sheets/popovers del sistema, .defaultAction | |
| Delete / ⌘⌫ elimina con deshacer | CosmosBrowserView, HarvesterQueueView | |
| Quick Look (⌘Y) | CosmosCommands | |
| Hover y cursores en elementos interactivos | botones .borderless del sistema | |
| Arrastrar y soltar (filas → carpetas) | TableRow.draggable + dropDestination | |
| Notificaciones solo en segundo plano | HarvesterStore.notifyBatchFinished | |
| Dock badge con descargas activas | HarvesterStore | |
| Liquid Glass solo en navegación/controles; contenido opaco; sin vidrio sobre vidrio | TransportBar, sistema | |
| Reduce Transparency / Motion / Increase Contrast | Tokens, TransportBar | |
| Colores semánticos + acento del sistema en controles | Tokens | |
```

- [ ] **Step 2: Menú del Dock (si la revisión lo marca como faltante)**

`Aether/App/DockMenu.swift`:

```swift
import AppKit

@MainActor
final class DockMenuBuilder {
    weak var player: PlayerModel?

    func menu() -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: player?.state == .playing ? "Pausa" : "Reproducir",
                                action: #selector(togglePlayback), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let next = NSMenuItem(title: "Siguiente", action: #selector(nextTrack), keyEquivalent: "")
        next.target = self
        menu.addItem(next)
        return menu
    }

    @objc private func togglePlayback() { player?.toggle() }
    @objc private func nextTrack() { player?.next() }
}
```

En `AppDelegate`: `let dockMenu = DockMenuBuilder()` y `func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { dockMenu.menu() }`; en `AetherApp.onAppear`: `appDelegate.dockMenu.player = model.player`.

- [ ] **Step 3: Commit**

```bash
git add docs/hig-review.md Aether
git commit -m "polish(hig): review against macOS HIG and add Dock menu"
```

---

### Task 5: Ícono y build de release 1.0

**Files:**
- Create: `Aether/AppIcon.icon` (Icon Composer)
- Modify: `Aether.xcodeproj/project.pbxproj` (versión 1.0, build 1; ícono)
- Create: `docs/release.md`

- [ ] **Step 1: Ícono (manual, Jean)**

En Icon Composer (Xcode › Open Developer Tool): capas sobre fondo negro neutro — una forma de onda/órbita minimalista en el verde fósforo `#6CEB9E` con material Liquid Glass del sistema; exportar `AppIcon.icon` a `Aether/` y seleccionar "AppIcon" como icono del target. Verificar en el Dock en modo claro/oscuro/tintado.

- [ ] **Step 2: Versión y archivo**

```bash
sed -i '' 's/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = 1.0;/g; s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = 1;/g' Aether.xcodeproj/project.pbxproj
xcodebuild -project Aether.xcodeproj -scheme Aether -configuration Release -archivePath build/Aether.xcarchive archive -quiet
```

Expected: `build/Aether.xcarchive` creado sin warnings de concurrencia.

- [ ] **Step 3: Firma y notarización (si hay cuenta Developer ID; si no, firmar en local y documentarlo)**

```bash
xcodebuild -exportArchive -archivePath build/Aether.xcarchive -exportPath build/export \
  -exportOptionsPlist Config/ExportOptions.plist
xcrun notarytool submit build/export/Aether.app.zip --keychain-profile "AC_NOTARY" --wait
xcrun stapler staple build/export/Aether.app
```

`Config/ExportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
```

(Antes de `notarytool submit`: `ditto -c -k --keepParent build/export/Aether.app build/export/Aether.app.zip`.)

- [ ] **Step 4: Checklist de release en `docs/release.md`**

```markdown
# Aether 1.0 — Release

- [ ] `swift test --package-path Packages/AetherKit` verde
- [ ] `xcodebuild … test` verde (unit + UI + auditoría a11y)
- [ ] docs/performance.md: todos ✓
- [ ] docs/accessibility.md, docs/motion-review.md, docs/hig-review.md completos
- [ ] Spikes S1–S4 documentados; S3 decidió WAV editable o no
- [ ] Descarga real verificada importada en rekordbox y reproducida en el CDJ
- [ ] App notarizada (o firma local documentada)
```

- [ ] **Step 5: Commit y tag**

```bash
git add Aether Aether.xcodeproj Config docs
git commit -m "release: Aether 1.0"
git tag v1.0
```
