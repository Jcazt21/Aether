# Aether v1 — Accesibilidad

| Comprobación | Resultado | Notas |
|---|---|---|
| Tab recorre sidebar → contenido → inspector → cápsula sin trampas | PASS | `NavigationSplitView` + `.inspector` + `TransportBar` en `safeAreaInset` siguen el orden de foco estándar de AppKit/SwiftUI. |
| VoiceOver lee fila de cola: título, estado y progreso ("Descargando 42 por ciento") | PASS | `JobRow` combina hijos con `.accessibilityElement(children: .combine)`, `.accessibilityLabel("\(job.title), \(job.artist)")` y `.accessibilityValue(job.accessibilityValue)`. |
| VoiceOver lee la cápsula: título, botones con nombre, posición ajustable (±10 s) | PASS | Botones con `.accessibilityLabel("Anterior" / "Reproducir" / "Pausa" / "Siguiente")`; `WaveformScrubber` expone `.accessibilityAdjustableAction` (±10 s). |
| Lecturas técnicas (SF Mono) se leen como texto, no como dígitos sueltos | PASS | `Readout` usa `Text` semántico con `.font(.readout)` (`monospacedDigit()`). |
| Increase Contrast: hairlines y verde/rojo más intensos | PASS | `Tokens.canvas(highContrast:)`, `Tokens.hairline(highContrast:)`, `Tokens.signal(highContrast:)` y `Tokens.fault(highContrast:)` elevan contraste con `colorSchemeContrast == .increased`. |
| Reduce Transparency: cápsula sólida | PASS | `TransportBar` conmuta a `Capsule().fill(Tokens.surface).overlay(Capsule().strokeBorder(Tokens.hairline))` y `.glassEffect(.identity, in: .capsule)` cuando `accessibilityReduceTransparency == true`. |
| Reduce Motion: solo fundidos | PASS | `RootView` y `StatusGlyph` conmutan a `.opacity` / `.easeOut(duration: 0.15)` y desactivan `.symbolEffect(.pulse)` cuando `accessibilityReduceMotion == true`. |
| Bold Text / tamaño de texto del sistema: sin truncados críticos | PASS | Toda la tipografía parte de estilos dinámicos (`.body`, `.callout`, `.caption`) sin tamaños fijos salvo `.readout` (11 pt monoespaciado técnico). |
| Todo atajo del menú funciona sin ratón (§8) | PASS | `⌘1`/`⌘2`/`⌘3`, `⌘D`, `⇧⌘R`, `⌘Y`, `⇧⌘M`, `⇧⌘N`, `⌥⌘V`, `⌘⌫`, `⌃⌘S`, `⌃⌘I`, `⌘→`/`⌘←`, `⌥⌘→`/`⌥⌘←`, `Espacio` (`onKeyPress`). |
