<p align="center">
  <img src="assets/icon.png" width="96" height="96" alt="Lokii Icon">
</p>

<h1 align="center">Lokii</h1>

<p align="center">
  <b>Ultra-fast, lightweight native macOS instant file search tool — like Everything for Mac</b>
</p>

<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/lang-English-blue?style=flat-square" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/lang-简体中文-lightgrey?style=flat-square" alt="简体中文"></a>
</p>

<p align="center">
  <a href="https://github.com/huangy7/lokii/releases/latest"><b>Download for macOS (Apple Silicon & Intel)</b></a>
</p>

<p align="center">
  <a href="https://github.com/huangy7/lokii/releases/latest"><img src="https://img.shields.io/github/v/release/huangy7/lokii?style=flat-square&label=latest" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/huangy7/lokii?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform">
  <a href="https://github.com/huangy7/lokii/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/huangy7/lokii/ci.yml?branch=main&style=flat-square&label=CI" alt="CI"></a>
  <a href="https://github.com/huangy7/lokii/releases"><img src="https://img.shields.io/github/downloads/huangy7/lokii/total?style=flat-square&color=success" alt="Downloads"></a>
  <img src="https://komarev.com/ghpvc/?username=huangy7-lokii&label=Views&color=0071e3&style=flat-square" alt="Views">
</p>

<p align="center">
  <img src="assets/screenshot-main.png" alt="Lokii instant search window" width="880">
</p>

Lokii is a native macOS instant file search tool engineered for developer-grade speed and desktop ergonomics — bringing the beloved, lightning-fast "Everything" file search experience to macOS. Powered by a high-performance in-memory index engine in Rust (`lokii-core`) bridged to a native Swift/AppKit user interface via UniFFI, Lokii delivers sub-millisecond query latency across hundreds of thousands of files with real-time FSEvents filesystem synchronization.

## Features

| Feature | Description |
| :--- | :--- |
| **Instant As-You-Type Search** | Sub-millisecond response latency across 500,000+ files with low memory footprint (< 100MB). |
| **Multi-Mode Query Engine** | Intelligent mode detection supporting substring, wildcard (`*`, `?`), regular expression (`^...$`), and fuzzy matching. |
| **Real-Time FSEvents Stream** | Multi-channel FSEvents event stream with dirty-queue debouncing to keep the index in sync without high CPU overhead. |
| **Native AppKit Density** | High-density virtualized table view, native macOS file icons, zebra striping, and spring-damped micro-interactions. |
| **Keyboard-First Workflow** | Global shortcut toggle (`⌘⇧Space`), arrow navigation, `Enter` to open, `⌘C` to copy path, `⌘↩` to hand the selection to LaunchBar, `⇧↩` to run a Keyboard Maestro macro on it, `⌘F` to refocus the search field, and `Esc` to hide. |
| **Persistent Binary Cache** | Bitcode-serialized index cache that survives system restarts for instant hot-start readiness. |
| **Native Settings & FDA** | Native Preferences window with custom search roots, exclusion rules, theme switching (Light/Dark/System), and interactive Full Disk Access setup. |

## Privacy

Lokii runs 100% locally on your Mac. There are no user accounts, no telemetry, no tracking, and zero outbound network connections. Your filenames, directory structures, and search queries never leave your device.

## Architecture

```
lokii-core/       Rust library — in-memory inverted index, parallel scanner, FSEvents watcher, bitcode cache
Lokii/            macOS Swift/AppKit application — virtualized table, settings, tray integration
scripts/          Build and packaging automation (UniFFI bindings generation, DMG creation)
```

## Build from Source

### Prerequisites

- macOS 13.0+
- Rust stable (2021 edition)
- Xcode 15+ (Swift 5.9+)

### Compiling and Running

```bash
# 1. Clone the repository
git clone https://github.com/huangy7/lokii.git
cd lokii

# 2. Build the app (generates UniFFI bindings & compiles Swift app)
make

# 3. Launch debug app
cd Lokii && .build/debug/Lokii
```

### Packaging DMG

To create a distributable `.app` and `.dmg`:

```bash
# Universal binary (Intel + Apple Silicon) — recommended for distribution
make package ARCH=universal

# Single-architecture build for Apple Silicon (arm64)
make package ARCH=arm64

# Single-architecture build for Intel (x86_64)
make package ARCH=x86_64
```

Output disk images will be generated in `output/Lokii-<arch>.dmg`
(e.g. `output/Lokii-universal.dmg`).

The `universal` build compiles both Rust targets
(`aarch64-apple-darwin` and `x86_64-apple-darwin`), `lipo`-merges the static
core library and the `lokii` CLI, and asks SwiftPM for a fat `Lokii`
executable — so a single `.app` runs natively on both Intel and Apple
Silicon. It requires the x86_64 Rust target:

```bash
rustup target add x86_64-apple-darwin
```

## Command-Line Interface

The same Rust core that powers the app also ships as a script-friendly CLI.
It is bundled **inside the app** at `Lokii.app/Contents/Resources/bin/lokii`,
and on first launch the app quietly symlinks it into your `PATH` (preferring
`/usr/local/bin`, falling back to `~/.local/bin`), so `lokii` works straight
from your terminal after installing the app — no extra setup required.
(Should neither location be writable, the link is skipped silently; add a
writable directory such as `~/.local/bin` to your `PATH` in that case.)

It reuses the app's configuration (`~/.config/lokii/config.toml`) and its
persistent index cache (`~/.config/lokii/index.cache`), so once the app has
built an index the CLI answers instantly without re-scanning your disk.

During development you can build the binary standalone with `make cli`:

```bash
make cli
# binary: target/$(uname -m)-apple-darwin/release/lokii

lokii report                # substring search (fuzzy fallback when empty)
lokii '*.rs'                # wildcard
lokii 'regex:^main'         # regular expression
lokii -m fuzzy config       # force fuzzy matching
lokii -l 10 report          # cap results
lokii -e pdf report         # only .pdf results
lokii -f report             # files only (-D for directories only)
lokii -j report             # JSON Lines output
lokii -0 report | xargs -0 open   # NUL-separated, pipe-safe
lokii -d ~/Projects -m fuzzy cfg  # scan a specific root on the fly
lokii --rebuild             # (re)build the shared index cache
vim "$(lokii -l 1 'todo.md')"
```

Every match is printed as an absolute path on its own line (stdout), so it
composes cleanly with shell scripts. Diagnostics and progress go to stderr.
Run `lokii --help` for the full flag reference.

## Contributors

<p align="center">
  <a href="https://github.com/huangy7/lokii/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=huangy7/lokii&max=100" alt="Contributors" />
  </a>
</p>

## License

Released under the [MIT](LICENSE) License.

---

<p align="center">
  Developed and maintained by <a href="https://github.com/huangy7">huangy7</a>
</p>
