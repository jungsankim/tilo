# Tilo

A macOS multi-video player that plays several videos simultaneously, automatically tiling them into an optimal mosaic layout.

[한국어 README](README.ko.md)

![Tilo playing six videos in a gapless mosaic layout](docs/screenshot-main.jpg)

<details>
<summary>Original-aspect mode (no cropping, letterboxed)</summary>

![Tilo in original-aspect mode](docs/screenshot-aspect.jpg)
</details>

## Features

- **Mosaic layout** — searches binary split trees (mixing horizontal/vertical cuts) to cover the screen with zero gaps while cropping every video uniformly and minimally. An original-aspect justified mode is one keystroke away (`A`)
- **Synchronized playback** — play, pause, and seek all videos together on a unified timeline; per-video seek bars on hover
- **Per-video looping** — finished videos restart on their own so the wall stays alive
- **Built for comparison** — nudge any single video's timing to align it with the others, step every video frame-by-frame (`,` / `.`), and save a clean snapshot of the whole mosaic (`⇧⌘S`)
- **Audio solo & volume** — use a tile's headphones button to hear only that video; double-click to zoom it full-window; global volume control
- **Drag to swap** — drag a tile onto another to exchange their positions, with live preview
- **Flexible layout** — auto mosaic, fixed grid (2×2 / 3×3 / 4×4), or original-aspect; rotate any tile 90°
- **Session restore** — reopens your last set of videos on launch; Open Recent menu
- **Tilo projects (`.tilo`)** — save and restore the media set, playlist, tile swaps, offsets, rotation, zoom/pan, volume, layout, A-B loop, and playhead. Moved media can be reconnected from a folder
- **Selected-video inspector** — click a tile and adjust media details, volume/solo, timing offset, rotation, and zoom from one sidebar
- **Audio & subtitle track selection** — choose alternate-language audio, sidecar subtitles, or embedded subtitles per video. Selections are saved in Tilo projects, and mosaic export uses the chosen audio track
- **Mosaic video export** — renders the current layout, crop/aspect mode, rotation, zoom/pan, timing offsets, looping, and relative timeline to a 1080p H.264 MP4. Mixes currently audible tracks with progress and cancellation
- **A-B loop** (`R`), **subtitles** (`.srt`/`.smi` auto-discovery, including CP949-encoded Korean subs, plus embedded tracks) with 50–200% sizing, **playlist** that auto-collects sibling videos and can replace a selected mosaic tile while preserving its slot, settings, and playhead
- **Instant control hiding** — click the down arrow or press `H` to hide the bottom controls even while paused; move the pointer to reveal them. Auto-hide delay is configurable
- **Broad file compatibility** — recognizes MP4/MOV/M4V/AVI/MKV/WebM/WMV/FLV/MPEG/VOB/TS/MTS/M2TS/OGV/3GP/MXF and more. Tilo first opens the original with AVFoundation. With experimental direct playback enabled, files AVFoundation rejects are opened as-is with libmpv; only a libmpv failure falls back to cached lossless MP4 remuxing or H.264/AAC conversion through ffmpeg
- **Performance-minded** — decode resolution capped to tile size, isolated progress publishing, keyframe scrubbing. A dozen videos play smoothly
- Localized in English, 한국어, 日本語, 简体中文

## Install

Requires macOS 13+. To build from source (Swift 5.9+):

```sh
brew install mpv ffmpeg
git clone https://github.com/jungsankim/tilo.git
cd tilo
./scripts/build-app.sh
open build/Tilo.app
```

Downloaded release builds are not notarized (no Apple Developer account). On first launch, right-click the app → **Open** → **Open**.

The current source build links against Homebrew's libmpv, so `mpv` is required even if **Settings → Play unsupported originals directly** is turned off. `ffmpeg` provides the compatibility-conversion fallback and mosaic export. Direct playback can be disabled in Settings; Tilo then goes from AVFoundation straight to compatibility conversion.

> **Experimental packaging note:** `build-app.sh` creates a developer build that dynamically links the installed Homebrew libmpv; it does not yet produce a self-contained distributable app. A target Mac therefore needs a compatible Homebrew mpv installation. Before redistributing, bundle and sign compatible libraries and review the licenses of the complete dependency chain, which may include GPL components.

## Keyboard shortcuts

| Key | Action |
|---|---|
| ⌘N | New project |
| ⌘O | Open videos |
| ⇧⌘O | Open a Tilo project |
| ⌘S | Save project |
| ⇧⌘S | Save project as |
| Space | Play / pause all |
| ← / → | Seek backward / forward (interval configurable in Settings) |
| ⇧← / ⇧→ | Seek 30s backward / forward |
| , / . | Step previous / next frame |
| 0–9 | Jump to 0%–90% of the timeline |
| L | Toggle loop |
| R | A-B loop (set A → set B → clear) |
| M | Toggle mute all |
| S | Sync all videos to the global timeline |
| ⌥⌘S | Save snapshot of the mosaic |
| ⇧⌘E | Export mosaic video |
| A | Fill screen / original aspect |
| C | Toggle subtitles |
| P | Toggle sidebar |
| H | Hide / show bottom controls |
| F | Toggle full screen |
| Esc | Exit zoom |
| ? | Show keyboard shortcuts |

## Architecture

| File | Role |
|---|---|
| `MosaicLayout.swift` | Binary-split-tree layout search (fill mode) |
| `GridLayout.swift` | Justified rows layout (original-aspect mode) |
| `PlayerManager.swift` | Playback state, playlist, audio routing, A-B loop |
| `MPVPlaybackEngine.swift` | Experimental direct-playback backend and per-video libmpv core |
| `MPVOpenGLView.swift` / `MpvBridge` | libmpv Render API surface for macOS |
| `TiloProject.swift` | Versioned `.tilo` project model, validation, and serialization |
| `MediaTracks.swift` | Audio/subtitle choices and stable project selection references |
| `Remuxer.swift` | ffmpeg-based MKV/WebM → MP4 remuxing with cache |
| `Subtitles.swift` | SRT/SMI parsing with encoding detection |
| `ContentView.swift` | Tiling, control bar, drag & drop |
| `VideoCell.swift` | Per-video tile: AVPlayerLayer, hover controls, subtitles |
| `SidebarView.swift` | Playlist and selected-video inspector sidebar |
| `MosaicExporter.swift` | Renders the current layout and playback settings to H.264/AAC MP4 |

## License

[MIT](LICENSE)
