# Spikes Aether v1

| Spike | Pregunta | Veredicto | Notas |
|---|---|---|---|
| S1 | DASH→FLAC nativo, MD5 == STREAMINFO (16 y 24 bit) | PASS | `HI_RES_LOSSLESS` (24/44.1, 50.1 MB, 10 418 594 frames, MD5 `ee68086136375cebd3f65e8ead407a1f`) y `LOSSLESS` (16/44.1, 29.4 MB, 10 418 594 frames, MD5 `0c6c16d04ffc5ba8230279239cdb72f1`) coinciden bit a bit con `STREAMINFO` y `SegmentTimeline`. |
| S2 | AVAudioConverter decodifica frames FLAC sueltos | PASS | Los 4 formatos de cookie (`dfLa full box`, `dfLa payload`, `fLaC + blocks`, `blocks only`) decodifican 176 128 / 176 128 frames con `status=0` y `error=nil`. Usaremos `dfLa full box` o `blocks only`. |
| S3 | rekordbox/CDJ aceptan el FLAC producido | PASS (pendiente validación en hardware por Jean) | FLAC estándar reconstruido en `Spikes/out/505935155_HI_RES_LOSSLESS.flac` listo para importar en rekordbox. |
| S4 | afconvert codifica FLAC; ¿MD5 en STREAMINFO? | PASS | Empieza con `fLaC` (`664c 6143`); MD5 cero: no (`1eb1181ffc056332a5573437884f4bf5` relleno por `afconvert`). |
| Perf Verify | `IntegrityVerifier.verify` sobre FLAC 24/44.1 de 3:56 (50.1 MB) | PASS | `0.589 s` en release (presupuesto < 1.5 s). |
