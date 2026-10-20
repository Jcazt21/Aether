# Aether v1 — Presupuestos de recursos

Build: 1.0 (1) Release · Mac: Apple M5 · macOS 27.0.1 · Fecha: 2026-10-20

| Escenario | Presupuesto | Medido | ✓/✗ | Evidencia |
|---|---|---|---|---|
| Reposo | CPU ≈ 0 %, 0 timers, RSS < 120 MB | CPU 0.0 % · 0 timers (`TimelineView` pausado cuando `state != .playing`, `FSEvents` pasivo) · RSS 64 MB | ✓ | `WaveformScrubber.swift`, `SignalPopover.swift`, `FolderWatcher.swift` |
| 3 descargas Hi-Res | RSS < 220 MB, CPU < 35 %, sin hitches | Streaming por segmentos (`FlacAssembler` escribe a disco segmento a segmento; `ProgressThrottle` limita actualizaciones de UI a 10 Hz / ≥ 1 % por fila `JobRow`) · RSS < 140 MB · CPU < 12 % | ✓ | `FlacAssembler.swift`, `ProgressThrottle.swift`, `HarvesterQueueView.swift` |
| Verificación 24/44.1 4 min | < 1.5 s | `0.589 s` en Release sobre FLAC 24/44.1 de 3:56 (50.1 MB, 10 418 594 frames) | ✓ | `docs/spikes.md` (Perf Verify) |
| Escaneo frío / caliente | < 3 s / < 300 ms | Frío: `25 ms` (sin leer payloads `PICTURE` vía `FlacMetadataIO.readSkippingPictures`, < 64 KB E/S por pista) · Caliente: `< 5 ms` (`LibraryScanner` reutiliza entradas sin cambios por `fileSize` + `modified`) | ✓ | `FlacMetadataIO.readSkippingPictures`, `LibraryScannerTests`, `ProbeAndTagIOTests/itemReaderSkipsLargePicturePayloadDuringScan` |
| Reproducción local | CPU < 3 % | CPU < 1.5 % (`AVAudioEngine` directo `AVAudioFile → AVAudioPlayerNode → mainMixerNode` sin tap instalado cuando `SignalPopover` está cerrado; `TimelineView` a 15 Hz solo en `WaveformScrubber`) | ✓ | `PlaybackEngine.setMetering`, `WaveformScrubber.swift` |
| Tags FLAC con padding | in-place | `0 B` de copia de audio (`HeaderRegionRewriter` escribe in-place y conserva `inode` cuando cabe en el bloque `PADDING` de 8 KB) | ✓ | `HeaderRegionRewriterTests/sameLengthWritesInPlaceAndKeepsInode`, `FlacMetadataIOTests/writeInPlaceWhenPaddingSuffices` |
