# Aether

A native macOS app for downloading, organizing and playing lossless music (FLAC), built for DJs.

Aether is made of three modules:

| Module | What it does |
|---|---|
| **Harvester** | Searches tracks and albums, downloads them (native DASH → FLAC, no ffmpeg), verifies integrity bit for bit (MD5 against `STREAMINFO`), writes tags and keeps a queue and history. Accepts Spotify playlist links and can export an XML for rekordbox. |
| **Cosmos** | Browser for your local library: scans folders, edits tags, detects untagged tracks, duplicates and lossy files, and organizes files. |
| **Lyra** | Player with bit-perfect output, device sample-rate switching and a signal-path view. |

Technical documentation lives in [`docs/`](docs): [performance](docs/performance.md), [accessibility](docs/accessibility.md), [technical spikes](docs/spikes.md), [release](docs/release.md).

---

## Requirements

| Requirement | Version |
|---|---|
| macOS | **27.0** or later (`MACOSX_DEPLOYMENT_TARGET = 27.0`) |
| Xcode | A version with Swift 6.2 and the macOS 27 SDK (the package uses `swift-tools-version: 6.2`) |
| **hifi-api** server | An instance reachable over HTTP (see below) |

Aether has **no external dependencies**: no third-party SwiftPM packages and no CocoaPods. All code lives in the project and in the local package [`Packages/AetherKit`](Packages/AetherKit).

## Installation

```bash
git clone https://github.com/Jcazt21/Aether.git Aether
cd Aether
open Aether.xcodeproj
```

1. In Xcode, select the **Aether** scheme and the **My Mac** destination.
2. Under *Signing & Capabilities*, choose your own **Team** (the project uses automatic signing).
3. Build and run with `⌘R`.

From the terminal:

```bash
xcodebuild -project Aether.xcodeproj -scheme Aether -configuration Release -destination 'platform=macOS' build
```

> The app does not use App Sandbox (`ENABLE_APP_SANDBOX = NO`). `Info.plist` only allows local-network connections (`NSAllowsLocalNetworking`), intended for a hifi-api on `127.0.0.1` or on your LAN. If your server is on another host or uses HTTPS, review `Config/Aether-Info.plist`.

## Setting up hifi-api

Aether **does not ship** any server or credentials. To search and download, it needs your own **hifi-api** service acting as an intermediary to the catalog. The app only stores that service's **base URL**.

1. Deploy or run your own hifi-api instance (follow the instructions of the implementation you use). By default Aether expects it at `http://127.0.0.1:8000`.
2. Open **Settings** in Aether and enter the URL in the **hifi-api URL** field.
3. Press the check button: Aether sends a `GET` to the base URL and expects `200 OK`.

The URL is stored in `UserDefaults` on your Mac; it is never written to the repository.

### Contract Aether expects from the server

This is what the client (`Packages/AetherKit/Sources/HiFiClient`) calls. If your instance does not respond this way, Aether will not work.

| Request | Purpose | Expected response |
|---|---|---|
| `GET /` | Connection check | HTTP `200` |
| `GET /search/?s=<text>&limit=&offset=` | Search tracks | `{"data": { page of tracks }}` |
| `GET /search/?al=<text>&limit=` | Search albums | `{"data": {"albums": { page of albums }}}` |
| `GET /album/?id=<id>&limit=500` | Album detail with its tracks | `{"data": { album + "items": [...] }}` |
| `GET /track/?id=<id>&quality=<quality>` | Playback info | `{"data": { "manifest": <base64>, "manifestMimeType", "audioQuality", "bitDepth", "sampleRate", ... }}` |

- `quality` is `HI_RES_LOSSLESS` or `LOSSLESS`.
- `manifest` must be a **DASH** manifest (MPD) with a `SegmentTemplate`; Aether downloads the segments and rebuilds the FLAC.
- Cover art is requested separately from `https://resources.tidal.com/images/…` (configurable via the `imageBaseURL` parameter of `HiFiClient.init`).
- Every response must be HTTP `200`; any other status is treated as an error.

### Security and responsible use

- **Never commit** private URLs, tokens or credentials of your server. `.gitignore` already excludes `.env` files, keys, certificates, downloaded music and local data.
- Your hifi-api server may require its own authentication or configuration; document it outside this repository.
- Only download content you have the right to obtain, and respect the terms of service of the catalog you use. This application grants no rights over any content.

## First run

1. **Settings → Master Folder:** choose where your library lives. Harvester downloads into a destination subfolder and Cosmos scans this folder.
2. **Harvester → Search:** search by track or album, or paste a Spotify playlist link to import it; select and enqueue.
3. **Queue and history:** follow each download's progress, retry failed ones and clear finished ones.
4. **Cosmos:** review tracks that are **untagged** , **duplicates**  and **lossy**, and edit tags in bulk.
5. **Lyra:** play from Cosmos; enable bit-perfect in Settings if you want the output device to follow the track's sample rate.

The download queue and history are saved in the app's data directory and restored when the app opens.

## Development

Layout:

```
Aether/                 SwiftUI app (shell, Harvester, Cosmos, player, settings, design system)
AetherTests/            App unit tests (Swift Testing)
AetherUITests/          UI tests and accessibility audit
Packages/AetherKit/     Local package with the non-UI logic:
  ByteKit               Binary reading/writing
  TagKit                FLAC, ID3 and WAV tags; file naming
  FlacKit               DASH/fMP4 → FLAC, integrity verification
  HiFiClient            hifi-api HTTP client and models
  Harvester             Download engine, queue, history, rekordbox XML
  Cosmos                Library scanner, index, organizer
  AetherCore            Playback engine, meters, output devices
Config/                 Info.plist and export options
Spikes/                 Technical experiments (output in Spikes/out/ is not versioned)
docs/                   Audits and reviews
```

The app builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency; `AetherKit` uses `ExistentialAny` and `InternalImportsByDefault`.

### Tests

```bash
# AetherKit package
swift test --package-path Packages/AetherKit

# App unit tests
xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' -only-testing:AetherTests test -quiet
```

UI tests (`AetherUITests`) are run from Xcode with the **Aether** scheme.

### Distribution

`Config/ExportOptions.plist` is set up for **Developer ID** export (`method = developer-id`). To distribute outside your own Mac you need your own developer account, and you must sign and notarize with `notarytool`.

## License

No license defined. Add a `LICENSE` file before making the repository public.
