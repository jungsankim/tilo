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
- **Audio solo & volume** — click a video to hear only that one; double-click to zoom it full-window; global volume control
- **Drag to swap** — drag a tile onto another to exchange their positions, with live preview
- **Flexible layout** — auto mosaic, fixed grid (2×2 / 3×3 / 4×4), or original-aspect; rotate any tile 90°
- **Session restore** — reopens your last set of videos on launch; Open Recent menu
- **A-B loop** (`R`), **subtitles** (`.srt`/`.smi` auto-discovery, including CP949-encoded Korean subs, plus embedded tracks), **playlist** that auto-collects sibling videos from the same folder
- **MKV/WebM support** — losslessly remuxed to MP4 on import via ffmpeg (if installed), cached, with codec-aware fallbacks (`hvc1` tagging for HEVC, AAC transcode for Vorbis/Opus/DTS audio)
- **Performance-minded** — decode resolution capped to tile size, isolated progress publishing, keyframe scrubbing. A dozen videos play smoothly
- Localized in English, 한국어, 日本語, 简体中文

## Install

Requires macOS 13+. To build from source (Swift 5.9+):

```sh
git clone https://github.com/jungsankim/tilo.git
cd tilo
./scripts/build-app.sh
open build/Tilo.app
```

Downloaded release builds are not notarized (no Apple Developer account). On first launch, right-click the app → **Open** → **Open**.

For MKV/WebM playback, install ffmpeg: `brew install ffmpeg`

## Keyboard shortcuts

| Key | Action |
|---|---|
| ⌘O | Open videos |
| Space | Play / pause all |
| ← / → | Seek backward / forward (interval configurable in Settings) |
| ⇧← / ⇧→ | Seek 30s backward / forward |
| , / . | Step previous / next frame |
| 0–9 | Jump to 0%–90% of the timeline |
| L | Toggle loop |
| R | A-B loop (set A → set B → clear) |
| M | Toggle mute all |
| S | Sync all videos to the global timeline |
| ⇧⌘S | Save snapshot of the mosaic |
| A | Fill screen / original aspect |
| C | Toggle subtitles |
| P | Toggle playlist |
| F | Toggle full screen |
| Esc | Exit zoom |
| ? | Show keyboard shortcuts |

## Architecture

| File | Role |
|---|---|
| `MosaicLayout.swift` | Binary-split-tree layout search (fill mode) |
| `GridLayout.swift` | Justified rows layout (original-aspect mode) |
| `PlayerManager.swift` | Playback state, playlist, audio routing, A-B loop |
| `Remuxer.swift` | ffmpeg-based MKV/WebM → MP4 remuxing with cache |
| `Subtitles.swift` | SRT/SMI parsing with encoding detection |
| `ContentView.swift` | Tiling, control bar, drag & drop |
| `VideoCell.swift` | Per-video tile: AVPlayerLayer, hover controls, subtitles |

## License

[MIT](LICENSE)
