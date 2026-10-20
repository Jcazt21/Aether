# Aether 1.0 — Release

- [x] `swift test --package-path Packages/AetherKit` verde (ByteKit, TagKit, FlacKit, HiFiClient, Harvester, Cosmos, AetherCore)
- [x] `xcodebuild … test` verde (`AetherTests` unit suites + `AetherUITests` compilado con auditoría `performAccessibilityAudit`)
- [x] `docs/performance.md`: todos ✓ (Reposo, 3 descargas Hi-Res, Verificación 24/44.1 < 1.5 s, Escaneo frío/caliente con `readSkippingPictures`, Reproducción local < 3 %, Tags FLAC in-place)
- [x] `docs/accessibility.md`, `docs/motion-review.md`, `docs/hig-review.md` completos
- [x] Spikes S1–S4 documentados en `docs/spikes.md`; S3 decidió WAV editable (`WavTags`, chunk `ID3 `)
- [x] Descarga real verificada lista en `Spikes/out/505935155_HI_RES_LOSSLESS.flac` (24/44.1, 10 418 594 frames, MD5 `ee68086136375cebd3f65e8ead407a1f`) para importar en rekordbox y reproducir en el CDJ
- [x] Archive Release 1.0 (build 1) generado y firmado localmente (Automatic Signing; `Config/ExportOptions.plist` preparado para Developer ID / `notarytool`)
