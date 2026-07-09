<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/swift-6.1%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.1+">
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/github/v/release/sergio-farfan/repodeck?style=flat-square&label=version" alt="Version">
  <img src="https://img.shields.io/github/downloads/sergio-farfan/repodeck/total?style=flat-square&label=downloads" alt="Downloads">
</p>

# RepoDeck

**Native macOS dashboard for the git status of all your local repositories.**

<p align="center">
  <img src="docs/screenshot.png" alt="RepoDeck — multi-repo git status dashboard" width="800">
</p>

## Download

**[Download the latest RepoDeck.dmg →](https://github.com/sergio-farfan/repodeck/releases/latest)**

Open the `.dmg` and drag **RepoDeck** to **Applications**.

<!-- UNSIGNED-NOTE: remove this block once notarized builds ship. -->
> This build is ad-hoc signed (not notarized). On first launch, right-click **RepoDeck.app → Open**, or run `xattr -dr com.apple.quarantine /Applications/RepoDeck.app`.

Prefer to build it yourself? See [Build from source](#build-from-source).

## Features

- Folder tracking with recursive repo discovery
- Live FSEvents status
- Stage, commit, pull, push, fetch
- Bulk Fetch All / Pull All
- Sidebar filter + pinning
- History search by message, author, file path, or content (pickaxe)
- Resizable Changes/History split
- Themes (System/Light/Dark), custom accent color, fonts, and font size (⌘,)

## Build from source

Prerequisites: macOS 15+, Xcode 26 / Swift 6.1+ toolchain, git.

```bash
git clone git@github.com:sergio-farfan/repodeck.git
cd repodeck
swift build            # compile
swift test             # run the test suite (71 tests)
swift run RepoDeck     # run in dev mode
Scripts/bundle.sh --open   # build and launch the .app bundle (dist/RepoDeck.app)
Scripts/make-dmg.sh        # package the installer DMG (--release publishes a GitHub Release)
```

## Uninstall

```bash
rm -rf /Applications/RepoDeck.app
defaults delete com.sergiofarfan.repodeck
```

## Requirements

- macOS 15+
- git at `/usr/bin/git`

## License

[MIT](LICENSE) — Sergio Farfan (sergio.farfan@gmail.com)
