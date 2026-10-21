# Aether

App nativa de macOS para descargar, organizar y reproducir música sin pérdida (FLAC), pensada para DJs.

Aether se compone de tres módulos:

| Módulo | Qué hace |
|---|---|
| **Harvester** | Busca pistas y álbumes, los descarga (DASH → FLAC nativo, sin ffmpeg), verifica la integridad bit a bit (MD5 contra `STREAMINFO`), escribe los tags y mantiene cola e historial. Acepta enlaces de playlists de Spotify y puede exportar un XML para rekordbox. |
| **Cosmos** | Explorador de tu biblioteca local: escanea carpetas, edita tags, detecta pistas sin etiquetas, duplicados y archivos lossy, y organiza archivos. |
| **Lyra** | Reproductor con salida bit-perfect, cambio de frecuencia de muestreo del dispositivo y vista de la cadena de señal. |

Documentación técnica del proyecto en [`docs/`](docs): [rendimiento](docs/performance.md), [accesibilidad](docs/accessibility.md), [spikes técnicos](docs/spikes.md), [release](docs/release.md).

---

## Requisitos

| Requisito | Versión |
|---|---|
| macOS | **27.0** o superior (`MACOSX_DEPLOYMENT_TARGET = 27.0`) |
| Xcode | Una versión con Swift 6.2 y el SDK de macOS 27 (el paquete usa `swift-tools-version: 6.2`) |
| Servidor **hifi-api** | Una instancia accesible por HTTP (ver más abajo) |

Aether **no tiene dependencias externas**: no hay paquetes de terceros en SwiftPM ni CocoaPods. Todo el código está en el proyecto y en el paquete local [`Packages/AetherKit`](Packages/AetherKit).

## Instalación

```bash
git clone https://github.com/Jcazt21/Aether.git Aether
cd Aether
open Aether.xcodeproj
```

1. En Xcode, selecciona el esquema **Aether** y el destino **My Mac**.
2. En *Signing & Capabilities* elige tu propio **Team** (el proyecto usa firma automática).
3. Compila y ejecuta con `⌘R`.

Desde la terminal:

```bash
xcodebuild -project Aether.xcodeproj -scheme Aether -configuration Release -destination 'platform=macOS' build
```

> La app no usa App Sandbox (`ENABLE_APP_SANDBOX = NO`). El `Info.plist` solo permite conexiones de red local (`NSAllowsLocalNetworking`), pensado para un hifi-api en `127.0.0.1` o en tu LAN. Si tu servidor está en otro host o usa HTTPS, revisa `Config/Aether-Info.plist`.

## Configurar hifi-api

Aether **no incluye** ningún servidor ni credenciales. Para buscar y descargar necesita un servicio **hifi-api** propio que haga de intermediario con el catálogo. La app solo guarda la **URL base** de ese servicio.

1. Despliega o ejecuta tu instancia de hifi-api (sigue las instrucciones de la implementación que uses). Por defecto Aether espera encontrarla en `http://127.0.0.1:8000`.
2. Abre **Ajustes** en Aether e introduce la URL en el campo **URL de hifi-api**.
3. Pulsa el botón de comprobación: Aether hace un `GET` a la URL base y espera un `200 OK`.

La URL se guarda en `UserDefaults` en tu Mac; no se escribe en el repositorio.

### Contrato que Aether espera del servidor

Esto es lo que el cliente (`Packages/AetherKit/Sources/HiFiClient`) llama. Si tu instancia no responde así, Aether no funcionará.

| Petición | Uso | Respuesta esperada |
|---|---|---|
| `GET /` | Comprobar conexión | HTTP `200` |
| `GET /search/?s=<texto>&limit=&offset=` | Buscar pistas | `{"data": { página de pistas }}` |
| `GET /search/?al=<texto>&limit=` | Buscar álbumes | `{"data": {"albums": { página de álbumes }}}` |
| `GET /album/?id=<id>&limit=500` | Detalle de álbum con sus pistas | `{"data": { álbum + "items": [...] }}` |
| `GET /track/?id=<id>&quality=<calidad>` | Información de reproducción | `{"data": { "manifest": <base64>, "manifestMimeType", "audioQuality", "bitDepth", "sampleRate", ... }}` |

- `quality` es `HI_RES_LOSSLESS` o `LOSSLESS`.
- `manifest` debe ser un manifiesto **DASH** (MPD) con `SegmentTemplate`; Aether descarga los segmentos y reconstruye el FLAC.
- Las carátulas se piden aparte a `https://resources.tidal.com/images/…` (configurable en `HiFiClient.init`, parámetro `imageBaseURL`).
- Todas las respuestas deben ser HTTP `200`; cualquier otro código se trata como error.

### Seguridad y uso responsable

- **No subas a git** URLs privadas, tokens ni credenciales de tu servidor. El `.gitignore` ya excluye `.env`, claves, certificados, música descargada y datos locales.
- Tu servidor hifi-api puede requerir su propia autenticación o configuración; documéntala fuera de este repositorio.
- Descarga solo contenido que tengas derecho a obtener y respeta los términos de servicio del catálogo que uses. Esta aplicación no concede ningún derecho sobre el contenido.

## Primer uso

1. **Ajustes → carpeta máster:** elige dónde vive tu biblioteca. Harvester descarga a una subcarpeta de destino y Cosmos escanea esta carpeta.
2. **Harvester → Buscar:** busca por pista o álbum, o pega un enlace de playlist de Spotify para importarla; selecciona y encola.
3. **Cola e historial:** sigue el progreso de cada descarga, reintenta las fallidas y limpia las terminadas.
4. **Cosmos:** revisa pistas **sin tags**, **duplicados** y **lossy**, y edita los tags en bloque.
5. **Lyra:** reproduce desde Cosmos; activa bit-perfect en Ajustes si quieres que el dispositivo siga la frecuencia de la pista.

La cola de descargas y el historial se guardan en el directorio de datos de la app y se restauran al abrirla.

## Desarrollo

Estructura:

```
Aether/                 App SwiftUI (shell, Harvester, Cosmos, reproductor, ajustes, sistema de diseño)
AetherTests/            Tests unitarios de la app (Swift Testing)
AetherUITests/          Tests de interfaz y auditoría de accesibilidad
Packages/AetherKit/     Paquete local con la lógica sin UI:
  ByteKit               Lectura/escritura binaria
  TagKit                Tags FLAC, ID3, WAV; nombres de archivo
  FlacKit               DASH/fMP4 → FLAC, verificación de integridad
  HiFiClient            Cliente HTTP de hifi-api y modelos
  Harvester             Motor de descargas, cola, historial, XML de rekordbox
  Cosmos                Escáner de biblioteca, índice, organizador
  AetherCore            Motor de reproducción, medidores, dispositivos de salida
Config/                 Info.plist y opciones de exportación
Spikes/                 Experimentos técnicos (la salida en Spikes/out/ no se versiona)
docs/                   Auditorías y revisiones
```

La app compila con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` y concurrencia accesible; el código de `AetherKit` usa `ExistentialAny` e `InternalImportsByDefault`.

### Tests

```bash
# Paquete AetherKit
swift test --package-path Packages/AetherKit

# Tests unitarios de la app
xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' -only-testing:AetherTests test -quiet
```

Los tests de interfaz (`AetherUITests`) se ejecutan desde Xcode con el esquema **Aether**.

### Distribución

`Config/ExportOptions.plist` está preparado para exportar con **Developer ID** (`method = developer-id`). Para distribuir fuera de tu Mac necesitas tu propia cuenta de desarrollador, firmar y notarizar con `notarytool`.

## Licencia

Sin licencia definida. Añade un archivo `LICENSE` antes de publicar el repositorio.
