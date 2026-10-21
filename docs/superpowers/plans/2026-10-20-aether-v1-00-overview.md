# Aether v1 — Visión general, arquitectura y hoja de ruta

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Este documento es la **especificación** de v1. Los planes ejecutables son los archivos `01`–`07` de esta carpeta, en orden. Cada plan produce software que compila y pasa sus pruebas por sí solo.

**Goal:** App nativa de macOS para descargar música lossless desde Tidal (vía la hifi-api local), verificar su integridad bit a bit, etiquetarla para rekordbox y organizarla dentro de `~/Master`, con un reproductor lossless integrado.

**Architecture:** App SwiftUI (macOS 27, Liquid Glass) sobre un paquete Swift local `AetherKit` con siete módulos sin dependencias de terceros. Toda la lógica pesada (red, demux, CRC, MD5, escaneo de disco, decodificación) vive en el paquete, fuera del hilo principal, y se prueba con `swift test`. La app solo contiene vistas y *stores* `@Observable` delgados que traducen eventos del motor a estado de UI.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, AVFoundation/AVFAudio, AudioToolbox, CoreAudio, Accelerate, CryptoKit, ImageIO, MediaPlayer, CoreServices (FSEvents), UserNotifications, OSLog, Swift Testing. Cero paquetes de terceros.

**Spec:** este archivo.

---

## 1. Producto

| Módulo | Nombre | Qué hace en v1 |
|---|---|---|
| Descargas | **Harvester** | Busca en Tidal, encola descargas, baja DASH → FLAC nativo, etiqueta, **verifica integridad automáticamente** (CRC por frame + conteo de muestras + MD5 de la fuente), lo deja en `~/Master/<carpeta>` y lo publica en un `rekordbox.xml`. |
| Gestor de archivos | **Cosmos** | Lee e indexa `~/Master`, vigila cambios (FSEvents), edita tags **Vorbis (FLAC)** e **ID3 (MP3/AIFF/WAV)**, mueve entre carpetas de género con deshacer, renombra desde tags, detecta duplicados, re-verifica FLAC. |
| Reproductor | **Aether Core** | Reproduce cualquier archivo del Master/descargas en lossless, con cambio automático del sample rate del DAC (bit-perfect), lectura técnica de la señal, forma de onda, teclas multimedia. Preescucha de resultados de búsqueda (sujeta al spike S2). |

**Prioridad:** Harvester > Cosmos > Aether Core. El orden de los planes refleja eso.

**Para quién:** un DJ que prepara música para rekordbox. Todo lo que Harvester produce debe importarse limpio en rekordbox (duración correcta, artwork, tags) y reproducirse en CDJ.

## 2. Hechos verificados (2026-10-20, contra la hifi-api local `http://127.0.0.1:8000`, v2.10)

Estos datos fundamentan el diseño. Si alguno deja de ser cierto, el plan afectado lo dice.

1. `GET /search/?s=<q>&limit=N` → `{version, data:{limit, offset, totalNumberOfItems, items:[Track]}}`. `Track` incluye `id, title, version, duration, trackNumber, volumeNumber, isrc, bpm (casi siempre null), key (null), copyright, audioQuality, mediaMetadata.tags (["LOSSLESS","HIRES_LOSSLESS"]), artist, artists[], album{id,title,cover}, replayGain, peak`.
2. `GET /search/?al=<q>` → `data.albums.items[]` con `releaseDate, copyright ("(C) 2026 CircoLoco Records"), upc, numberOfTracks, cover, artists[]`.
3. `GET /album/?id=<id>` → `{data:{...album, items:[{item: Track, type: "track"}]}}`.
4. `GET /track/?id=<id>&quality=HI_RES_LOSSLESS|LOSSLESS` → `{data:{trackId, audioQuality, manifestMimeType:"application/dash+xml", manifest:<base64 MPD>, bitDepth, sampleRate, trackReplayGain, trackPeakAmplitude, albumReplayGain, albumPeakAmplitude}}`. **Ambas calidades llegan como DASH**; no hay URL FLAC directa.
5. El MPD: un `Representation id="FLAC_HIRES,44100,24" codecs="flac" audioSamplingRate="44100"`, `SegmentTemplate timescale=<sampleRate> initialization=<url> media=<url con $Number$> startNumber="1"`, `SegmentTimeline` con `<S d="176128" r="58"/><S d="27042"/>`. **Σ duraciones = total de muestras exacto** (10 418 594 → 236.249 s = `mediaPresentationDuration`).
6. Init segment (619 bytes): `ftyp, moov/trak/mdia/minf/stbl/stsd/fLaC/dfLa`. El `dfLa` contiene un solo bloque STREAMINFO (last=1) con **total_samples y MD5 rellenos** (p. ej. `md5 ee68086136375cebd3f65e8ead407a1f`), blocksize 4096.
7. Media segment: `moof(mfhd, traf(tfhd flags 0x2002a, tfdt, trun flags 0x201 — data-offset + sample-size))` + `mdat` cuyo payload empieza en `fff8…` = frames FLAC crudos. 43 frames × 4096 = 176 128 muestras = `d` del timeline.
8. Portadas: `https://resources.tidal.com/images/<cover con "-"→"/">/1280x1280.jpg`.

**Consecuencia de diseño:** un FLAC perfecto = `"fLaC"` + bloques de metadatos (STREAMINFO del `dfLa` + Vorbis + Picture + Padding) + concatenación de los payloads `mdat` en orden. No hace falta ffmpeg ni re-codificar. La verificación puede ser **bit a bit contra el MD5 que la propia fuente publica**.

## 3. Restricciones globales (aplican a TODAS las tareas)

- Deployment target: **macOS 27.0**. Xcode 27. Ningún `#available` por debajo de 27 (no hay fallback que mantener), salvo APIs marcadas 27.1+.
- Lenguaje: **Swift 6** (`SWIFT_VERSION = 6.0`), strict concurrency completo. App: aislamiento por defecto `MainActor` (ya configurado). Paquete: aislamiento por defecto `nonisolated`.
- **Cero dependencias de terceros.** Solo frameworks de Apple. (Herramientas de desarrollo opcionales: `flac`/`metaflac` de Homebrew para validar spikes, nunca en runtime.)
- App **no sandboxed** (ya `ENABLE_APP_SANDBOX = NO`): acceso directo a `~/Master`. Hardened runtime activado.
- Red: la hifi-api corre en `http://127.0.0.1:8000` (configurable). Info.plist con `NSAppTransportSecurity › NSAllowsLocalNetworking = YES`.
- **UI solo oscura**: `.preferredColorScheme(.dark)` + `NSApp.appearance = .darkAqua`. Estética: oscura, minimalista, técnica.
- Copy de la UI **en español**; términos técnicos sin traducir (FLAC, Hi-Res, MD5, BPM, sample rate, bit-perfect). String Catalog `Localizable.xcstrings` con idioma de desarrollo `es`.
- Nombres de producto exactos: **Aether** (app), **Aether Core** (reproductor), **Harvester** (descargas), **Cosmos** (gestor).
- Nomenclatura de archivo por defecto: `{Artista principal} - {Título}{ (Versión)}.flac`, igual que el Master existente. Caracteres prohibidos `/` y `:` → `-`. Nunca sobrescribir: colisión → sufijo ` (2)`, ` (3)`…
- Carpeta de entrada por defecto: `~/Master/Por clasificar` (ya existe).
- Archivos temporales de descarga: `.<nombre>.aether-part` en la carpeta destino (mismo volumen → rename atómico). Cosmos ignora archivos ocultos.
- Pruebas: Swift Testing (`import Testing`, `@Test`, `#expect`). Paquete: `swift test --package-path Packages/AetherKit`. App: `xcodebuild … test`.
- Commits pequeños, uno por tarea como mínimo, mensajes Conventional Commits en inglés.
- Logging: `Logger(subsystem: "com.jazar.Aether", category: …)`; intervalos `OSSignposter` en descarga, demux, verificación y escaneo.

## 4. Presupuesto de recursos (criterios de aceptación de v1)

| Escenario | Presupuesto | Cómo se mide (plan 07) |
|---|---|---|
| App en reposo, Master indexado | CPU ≈ 0 %, **0 timers activos**, RSS < 120 MB | Activity Monitor + Instruments *Time Profiler* 60 s |
| 3 descargas Hi-Res en paralelo | RSS < 220 MB, CPU media < 35 % de un núcleo, UI sin *hitches* | Instruments *SwiftUI* + *Animation Hitches* |
| Verificación de un FLAC 24/44.1 de 4 min | < 1.5 s en Apple Silicon | Signpost `verify` |
| Escaneo en frío de `~/Master` (~640 archivos) | < 3 s; en caliente (índice en disco) < 300 ms | Signpost `scan` |
| Reproducción local | CPU < 3 %; medidores apagados = coste cero | Time Profiler |
| Escritura de tags en FLAC con padding suficiente | In-place, sin reescribir el audio | Prueba unitaria + tamaño de archivo constante |

Principios que producen esos números:

1. **Streaming a disco**, nunca blobs en memoria: cada segmento (~0.7–1.2 MB) se escribe y se libera.
2. **Metadatos antes que audio**: Harvester resuelve tags y portada *antes* de bajar audio y escribe la cabecera FLAC completa con padding; el audio se añade detrás. Cero reescrituras de 40 MB.
3. **`URLSession` sin caché** (`urlCache = nil`) para audio: no duplicar 40 MB por pista en `~/Library/Caches`.
4. Trabajo pesado en funciones `nonisolated`/`@concurrent` fuera de actores y del MainActor; actores solo para contabilidad.
5. Progreso **limitado a 10 Hz por trabajo**; estado `@Observable` **por fila** (un `JobModel` por descarga) para que solo se invalide la fila que cambia.
6. Sin `Timer`: el tiempo de reproducción se lee con `TimelineView` solo mientras suena; los medidores solo instalan el *tap* de audio cuando están visibles.
7. Lectura de tags = solo cabeceras (bloques FLAC / tag ID3), nunca el archivo entero. Índice de Cosmos persistido en plist binario con `(tamaño, mtime)` para escaneos incrementales.
8. Archivos mapeados en memoria (`.alwaysMapped`) para el escaneo CRC; el kernel pagina, la RSS no se dispara.
9. Artwork decodificado a tamaño de pantalla con `CGImageSourceCreateThumbnailAtIndex`, `NSCache` con límite de coste.
10. `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` solo mientras hay descargas; App Nap el resto del tiempo.

## 5. Arquitectura

```
Aether/                                  (repo: ~/Documents/Projects/Aether)
├─ Aether.xcodeproj
├─ Config/Aether-Info.plist              ATS local networking
├─ Aether/                               App target (carpeta sincronizada)
│  ├─ App/            AetherApp, AppDelegate, AppModel, AetherCommands, Route
│  ├─ DesignSystem/   Tokens, HairlineProgress, Readout, StatusGlyph, EmptyState
│  ├─ Shell/          RootView, SidebarView
│  ├─ Harvester/      HarvesterStore, JobModel, SearchView, AlbumView, QueueView, JobRow, HistoryView
│  ├─ Cosmos/         CosmosStore, BrowserView, TagInspector, TagDraft, RenamePreviewSheet
│  ├─ AetherCore/     PlayerModel, TransportBar, WaveformScrubber, SignalPopover, NowPlayingBridge
│  └─ Settings/       SettingsView, Preferences
├─ Packages/AetherKit/                   Paquete local SPM
│  └─ Sources/
│     ├─ ByteKit/       ByteReader, ByteWriter, HeaderRegionRewriter
│     ├─ TagKit/        FLAC metadata (StreamInfo, Vorbis, Picture), ID3v2.3/2.4, chunks AIFF/WAV, TrackTags, FileNaming
│     ├─ FlacKit/       CRC, FrameHeaderParser, FrameScanner, PCMDigest (MD5), MP4 boxes, FMP4Flac, FlacAssembler, IntegrityVerifier
│     ├─ HiFiClient/    Modelos Tidal, DashManifest, HiFiClient
│     ├─ Harvester/     HarvestEngine (actor), SegmentFetcher, TagBuilder, HistoryStore, RekordboxXML
│     ├─ Cosmos/        AudioProbe, TagIO, LibraryItem, LibraryScanner, IndexStore, FolderWatcher, DuplicateDetector, Organizer
│     └─ AetherCore/    OutputDevice, PlaybackEngine, MeterTap, WaveformAnalyzer, DashFlacStream (si S2 pasa)
├─ AetherTests/ AetherUITests/
└─ docs/superpowers/plans/
```

Grafo de dependencias del paquete (sin ciclos):

```
ByteKit ← TagKit ← FlacKit
             ↑        ↑
          HiFiClient  │          (HiFiClient ← TagKit)
             ↑        │
             ├── Harvester  (HiFiClient, FlacKit, TagKit)
             ├── Cosmos     (TagKit, FlacKit)
             └── AetherCore (ByteKit, FlacKit, HiFiClient, TagKit)
TestSupport (solo pruebas) ← TagKit
```

Flujo de datos en la app:

```
HarvestEngine (actor) ──AsyncStream<HarvestEvent>──▶ HarvesterStore (@MainActor @Observable) ──▶ JobModel por fila ──▶ JobRow
LibraryScanner + FolderWatcher ──ScanResult──▶ CosmosStore ──▶ Table / TagInspector
PlaybackEngine (@MainActor, AVAudioEngine) ◀── PlayerModel ◀── TransportBar / comandos de menú / MPRemoteCommandCenter
AppModel (owner) inyecta los tres stores con .environment(...)
```

## 6. Pipeline de Harvester (núcleo de v1)

```
queued
 └▶ resolving   GET /track (calidad según política) ∥ GET /album (cacheado) ∥ GET portada 1280
                 · si política "Hi-Res ≤ 96 kHz" y sampleRate > 96000 → re-pedir LOSSLESS
                 · parse MPD → init URL, plantilla, timeline, total_samples esperado
                 · GET init → dfLa → STREAMINFO
                 · cabecera FLAC = STREAMINFO + VORBIS_COMMENT + PICTURE + PADDING(8 KiB)
 └▶ downloading for n in segmentos: GET (retry ×3, backoff 0.5/1/2 s; 403 → refrescar manifiesto y seguir en n)
                 · validar Σ tamaños trun == len(mdat) · append frames al .aether-part · progreso ≤10 Hz
 └▶ verifying   1. CRC-8 cabecera + CRC-16 de CADA frame (archivo mapeado, memchr)
                 2. Σ blocksizes == STREAMINFO.total_samples == Σ SegmentTimeline
                 3. Decodificar con AudioToolbox → MD5 del PCM canónico == STREAMINFO.md5 (de la fuente)
                 · fallo → borrar part, 1 reintento completo automático, luego failed
 └▶ verified    escribir AETHER_VERIFIED=md5:<hex>;<ISO8601> in-place (cabe en padding)
                 · rename atómico a nombre final · historial · rekordbox.xml · notificación si la app no está al frente
```

## 7. Sistema de diseño

**Dirección:** instrumento de laboratorio. Negro neutro, tipografía SF Pro para contenido y **SF Mono** para toda lectura técnica (sample rate, bit depth, MD5, bytes, velocidad). Un solo color de marca funcional: el verde fósforo de "verificado". Nada decorativo.

| Token | Valor | Uso |
|---|---|---|
| `canvas` | `#0B0C0E` | Fondo del contenido (detalle) |
| `surface` | `#121417` | Filas seleccionadas sin foco, pozos de artwork |
| `hairline` | blanco 8 % (14 % con *Increase Contrast*) | Separadores, pista de la barra de progreso |
| `textPrimary/Secondary/Tertiary` | `.primary` / `.secondary` / `.tertiary` | Jerarquía de texto (semánticos del sistema) |
| `signal` | `#6CEB9E` (más claro con *Increase Contrast*) | Verificado, bit-perfect |
| `fault` | `#FF6B5E` | Fallo de integridad o red |
| Acento | acento del sistema | Controles, progreso de transferencia (respeta HIG 9.3) |

- Tipografía: estilos semánticos (`.body`, `.callout`, `.caption`) — nunca tamaños fijos. Lecturas: `.system(.caption, design: .monospaced).monospacedDigit()`. Etiquetas de sección: `.caption2.weight(.semibold)`, mayúsculas, `tracking(0.6)`.
- Espaciado: rejilla de 4 pt; márgenes de 20 pt; controles compactos de macOS (22–28 pt).
- **Liquid Glass** solo en la capa de navegación y controles flotantes: sidebar y toolbar (automáticos del sistema), y la **cápsula de transporte de Aether Core** (`glassEffect(.regular, in: .capsule)` dentro de `GlassEffectContainer`). El contenido (tablas, inspector) es opaco. Nunca vidrio sobre vidrio. Botones dentro de la cápsula: `.borderless` con estado hover.
- **Barra de progreso limpia** (Harvester): línea de 2 pt a lo ancho de la fila. Primer pase = transferencia (acento). Segundo pase superpuesto = verificación (`signal`). Fallo = pista en `fault`. Solo se anima `scaleEffect(x:)` (transform, sin layout), lineal 120 ms. Lectura a la derecha en mono: `38.2 / 41.0 MB · 6.1 MB/s` → `VERIFICANDO · MD5 62 %` → `VERIFICADO · ee68…7a1f`.
- Movimiento (Emil Kowalski): nada animado en acciones de teclado; entradas/salidas ease-out ≤ 220 ms; desde `scale 0.96 + opacity 0`, nunca desde 0; progreso lineal; check de verificado una sola vez por pista (180 ms). *Reduce Motion* → solo opacidad. *Reduce Transparency* → la cápsula de transporte pasa a `surface` sólido.
- Accesibilidad: etiquetas en todos los botones de icono, orden de foco lógico, `accessibilityValue` con el progreso, *Bold Text* e *Increase Contrast* respetados.
- Ícono: Icon Composer (capas, Liquid Glass) — fuera del alcance de código; ver plan 07.

## 8. Mapa de navegación y comandos (HIG macOS)

Ventana principal: `NavigationSplitView` + `.inspector` + cápsula de transporte flotante abajo del detalle. Toolbar unificada.

Sidebar:
- **HARVESTER**: Buscar · Cola (badge = activos) · Historial
- **COSMOS**: Master (todo) · una entrada por carpeta de género (con conteo) · Por clasificar (badge) · Revisar ▸ Sin tags · Duplicados · Lossy (MP3/M4A)

Menús (además de los estándar App/File/Edit/View/Window/Help):

| Menú | Comando | Atajo |
|---|---|---|
| View | Ir a Buscar / Cola / Master | ⌘1 / ⌘2 / ⌘3 |
| View | Mostrar/ocultar inspector | ⌃⌘I (`InspectorCommands`) |
| View | Mostrar/ocultar sidebar | ⌃⌘S |
| Harvester | Descargar selección | ⌘D |
| Harvester | Descargar álbum | ⇧⌘D |
| Harvester | Reintentar fallidas | ⇧⌘R |
| Harvester | Cancelar seleccionada | ⌘. |
| Cosmos | Mostrar en Finder | ⇧⌘R |
| Cosmos | Mover a… | ⇧⌘M |
| Cosmos | Renombrar desde tags… | ⇧⌘N |
| Cosmos | Verificar integridad | ⌥⌘V |
| Cosmos | Guardar tags | ⌘S |
| Cosmos | Mover a la Papelera | ⌘⌫ |
| Cosmos | Quick Look | ⌘Y |
| Control | Reproducir/Pausa | Espacio |
| Control | Siguiente / Anterior | ⌘→ / ⌘← |
| Control | Avanzar / Retroceder 10 s | ⌥⌘→ / ⌥⌘← |
| Edit | Buscar | ⌘F |

Espacio = reproducir/pausa (convención de Música; para un DJ preescuchar es lo frecuente). Quick Look pasa a ⌘Y (convención de Finder). ⌘Z deshace movimientos, renombres y ediciones de tags.

## 9. Decisiones y supuestos (validar con Jean)

1. **Tope 96 kHz por defecto** (política `Hi-Res ≤ 96 kHz`): si Tidal ofrece >96 kHz, se baja LOSSLESS 16/44.1 en su lugar. Motivo: compatibilidad CDJ/rekordbox sin re-muestrear. Configurable a "Hi-Res máximo" o "Siempre 16/44.1". **Confirmar el modelo de CDJ/controlador.**
2. **rekordbox**: Harvester mantiene `~/Music/Aether/rekordbox.xml` (playlists `Harvester ▸ AAAA-MM-DD`). Jean lo apunta una vez en rekordbox › Preferencias › Avanzado › Base de datos › rekordbox xml. Aether **no** toca `master.db` de rekordbox.
3. **Mover archivos ya importados en rekordbox rompe sus rutas.** Cosmos muestra aviso y mantiene un diario de movimientos; el flujo recomendado es *Por clasificar → clasificar en Cosmos → importar en rekordbox*.
4. Tags escritos para rekordbox: TITLE, ARTIST (todos los MAIN, separados por ", "), ALBUM, ALBUMARTIST, GENRE (= carpeta destino si no es "Por clasificar"), DATE (año), LABEL **y** ORGANIZATION (sello, extraído del copyright), ISRC, TRACKNUMBER, DISCNUMBER, BPM/INITIALKEY solo si Tidal los trae, REPLAYGAIN_*, COMMENT vacío, portada 1280 JPEG tipo 3. MP3 se escribe en **ID3v2.3** (máxima compatibilidad); un tag v2.4 existente se conserva en v2.4.
5. Se **preservan** frames/bloques desconocidos (p. ej. GEOB de Serato, PRIV de Mixed In Key, SEEKTABLE, CUESHEET).
6. WAV/AIFF: edición vía chunk `id3 `/`ID3 `. **Validar en spike S3 que rekordbox lo lee**; si no, WAV queda solo-lectura en v1. M4A/MP4: solo lectura.
7. Preescucha de búsqueda en streaming depende del spike S2; si falla, la preescucha baja la pista a una caché (≤ 500 MB, LRU) y la reproduce local.
8. `/review-animations` no está instalado; su rol lo cubren `emil-design-eng` + la revisión del plan 07.

## 10. Hoja de ruta

| # | Plan | Entregable comprobable |
|---|---|---|
| 01 | `…-01-foundation.md` | Spikes S1–S4 resueltos · proyecto en Swift 6 · paquete `AetherKit` enlazado · ByteKit probado · shell de la app (sidebar, rutas, comandos, Settings, tokens) que compila y corre en oscuro |
| 02 | `…-02-tagkit.md` | Lectura/escritura FLAC (StreamInfo/Vorbis/Picture/Padding in-place), ID3v2.3/2.4, chunks AIFF/WAV, `TrackTags`, `FileNaming` — todo con pruebas de ida y vuelta |
| 03 | `…-03-flackit.md` | CRC-8/16, escáner de frames, MD5 PCM, demux fMP4→FLAC, ensamblador streaming, `IntegrityVerifier` |
| 04 | `…-04-harvester.md` | Cliente hifi-api, parser MPD, `HarvestEngine` con cola/reintentos/reanudación, UI de búsqueda/álbum/cola/historial, barra de progreso, rekordbox.xml, notificaciones |
| 05 | `…-05-cosmos.md` | Índice de Master con escaneo incremental y FSEvents, tabla, inspector de tags (lote), mover/renombrar con deshacer, duplicados, re-verificación, "ya en Master" en Harvester |
| 06 | `…-06-aether-core.md` | Motor AVAudioEngine bit-perfect, cápsula de transporte Liquid Glass, forma de onda, lectura de señal, teclas multimedia, preescucha |
| 07 | `…-07-quality.md` | Auditoría de presupuestos con Instruments, accesibilidad, revisión de animaciones, checklist HIG, build de release |

Dependencias: 01 → 02 → 03 → 04 → 05 → 06 → 07. 05 puede empezar en paralelo a 04 una vez terminado 03 (comparten solo TagKit/FlacKit).
