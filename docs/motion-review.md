# Aether v1 — Revisión de movimiento

| Elemento | Frecuencia | Animación | Duración/curva | ¿Correcta? |
|---|---|---|---|---|
| Relleno de transferencia (HairlineProgress) | continua | scaleEffect x | 120 ms lineal (`Tokens.Motion.progress`) | ✓ |
| Relleno de verificación | continua | scaleEffect x | 120 ms lineal (`Tokens.Motion.progress`) | ✓ |
| Cambio de fase de fila | por pista | color/opacidad | 180 ms ease-out (`Tokens.Motion.state`) | ✓ |
| Glifo de estado | por pista | symbolEffect replace | sistema (`.contentTransition(.symbolEffect(.replace))`) | ✓ |
| Aparición de la cápsula | ocasional | opacity + offset 8 pt (entrada) / opacity (salida) | 220 ms ease-out (`Tokens.Motion.enter`) / 120 ms ease-out (salida) | ✓ |
| Play/Pausa (Espacio) | cientos/día | ninguna | — | ✓ |
| Cambio de ruta ⌘1/⌘2/⌘3 | cientos/día | ninguna | — | ✓ |
| Medidores | 30 Hz solo con popover | directo (sin interpolación) | — | ✓ |

## Hallazgos

| Before | After | Why |
| --- | --- | --- |
| `TransportBar` usaba una transición simétrica `.opacity.combined(with: .offset(y: 8))` (220 ms tanto al entrar como al salir). | `.transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)), removal: .opacity.animation(.easeOut(duration: 0.12))))` en `RootView.swift`. | Las salidas deben ser más rápidas y discretas que las entradas (120 ms solo opacidad vs 220 ms opacidad + 8 pt de desplazamiento) para que la interfaz no se sienta lenta al terminar la cola. |
