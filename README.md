<p align="center">
  <img src="docs/icon.png" width="128" alt="Swarm icon">
</p>

<h1 align="center">Swarm</h1>

<p align="center">
  A light, native torrent app for macOS that explains what is happening in plain words,<br>
  lets you watch or listen while it downloads, and shares files with nearby Macs.
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-arm64-black">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white">
  <img alt="libtorrent 2.1" src="https://img.shields.io/badge/engine-libtorrent%202.1-555">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

No Python, no background service, no account. The engine is [libtorrent](https://libtorrent.org) 2.1 (the same engine
qBittorrent uses), bundled inside the app so nothing outside it can break it.

## Install

```sh
brew install --cask nurik-dz/tap/swarm
```

Or download `Swarm.zip` from [Releases](https://github.com/Nurik-dz/Swarm/releases/latest), unzip it and move
**Swarm.app** to Applications. Swarm is not notarized; if macOS blocks it, open
**System Settings → Privacy & Security** and choose **Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Swarm.app
```

## Features

### Adding
- Magnet links: paste (⌘V anywhere), drag in, click one in your browser, or use **+**. `.torrent` files: ⌘O, drag in or double-click.
- Choose files before anything downloads, with quick picks (Only Videos, Audio, Subtitles, Pictures…).
- **Suggestions** that understand release names: pick 4K or 1080p when episodes come in several sizes, a subtitle
  language, skip samples. Nothing changes until you apply it.
- A storage check blocks a download that would not fit.

### Knowing what is going on
- Plain-words status from the very first second: *"Asking 4 trackers and the DHT network…"*, *"Found 155 people sharing,
  connecting to 30…"*, and after 20 seconds the reason when nothing arrives.
- **Health**: whether the people connected have what you still need.
- **Rescue** card when something is wrong (trackers silent, nobody connected, pieces nobody offers, disk full) with one
  safe action and a log of what Swarm did on its own.
- Inspector with progress, files, peers (their app, speed, how much they have) and a piece map.
- Dock progress, a menu bar ring, notifications, Quick Look, and drag finished files straight into Finder.

### Play while downloading
- Play MP4, M4V, MOV, M4A, M4B and MP3 files while they download. Seeking ahead fetches that part first.
- A **Now Playing** bar with cover art, chapters, ±15/30 s skips, speed 0.75×–2×, and a scrubber that shows which parts are on disk.
- Subtitles from `.srt` / `.vtt` files in the torrent or tracks inside the video; your language is remembered.
- Media keys and Control Center.

### Files you already have
Drop a file or folder on the window: if it matches a torrent, Swarm checks it piece by piece and downloads only what is
missing or damaged. Nothing is moved or overwritten.

### Share your own files
**File → Share a File or Folder…** (or Finder → Services → **Share with Swarm**) makes a torrent, then gives you a magnet
link or a `.torrent` file. Optional trackers and private torrents.

### Nearby Macs
**File → Send to Nearby Mac…** (⇧⌘S) sends files to another Mac on the same network as a private, verified transfer that
survives interruptions. The receiver sees who is sending what, compares a four-digit code, and nothing is saved until
they accept. Receiving is off until turned on in **Settings → Network**.

### Settings
- Theme and window look (Liquid Glass, Frosted, Solid), download folder, sharing rule after download, notifications,
  menu bar, default app for magnet links and `.torrent` files.
- Download and upload limits, with a **schedule** for different limits at set times.
- Listening port with UPnP / NAT-PMP.
- Everything resumes after a quit.

## Build from source

Requires macOS 26 or later, the Xcode Command Line Tools (`xcode-select --install`) and libtorrent from Homebrew:

```sh
brew install libtorrent-rasterbar
git clone https://github.com/Nurik-dz/Swarm.git
cd Swarm
./build.sh            # builds build/Swarm.app with libtorrent and OpenSSL bundled inside
open build/Swarm.app
```

## Tests

Offline checks:

```sh
Tests/smart/build.sh          # release-name understanding
Tests/schedule/build.sh       # speed-limit schedule windows
Tests/lanprotocol/build.sh    # nearby-Mac messages
```

App-level tests build against the app sources with `Tests/run.sh <name> …` (see the header of `Tests/run.sh`). Set
`SWARM_STATE_DIR` to a scratch folder so your real torrents are never touched.

## How it is built

```
Views (SwiftUI) → AppModel / TorrentStore → TBSession (Objective-C++ bridge) → libtorrent
```

```
Sources/
  App/      entry point, window, menus, shared state
  Bridge/   TorrentBridge.h/.mm: the libtorrent wrapper
  Model/    torrents, health and rescue rules, smart picks, subtitles, settings, nearby-Mac protocol
  System/   streaming over torrent pieces, Bonjour, Dock progress, notifications, Quick Look
  Views/    SwiftUI screens
Tests/      offline and app-level tests
tools/      icon generator
```

## Good to know

- MKV, AVI and WebM cannot be played while downloading (the system player needs MP4-family files); they play once finished.
- Styled `.ass` / `.ssa` subtitles are not supported yet.

## License

[MIT](LICENSE) © 2026 Nurik-dz. Bundles [libtorrent](https://libtorrent.org) (BSD-3-Clause) and OpenSSL (Apache-2.0).
