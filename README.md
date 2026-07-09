# RepoDeck

Native macOS dashboard for the git status of all your local repositories.

<!-- ![RepoDeck screenshot](docs/screenshot.png) -->

## Features

- Folder tracking with recursive repo discovery
- Live FSEvents status
- Stage, commit, pull, push, fetch
- Bulk Fetch All / Pull All
- Sidebar filter + pinning
- History search by message, author, file path, or content (pickaxe)
- Resizable Changes/History split
- Themes (System/Light/Dark), custom accent color, fonts, and font size (⌘,)

## Requirements

- macOS 15+
- git at `/usr/bin/git`
- Xcode 26 / Swift 6.1+ toolchain to build

## Build & Run

```
swift build
swift test
swift run RepoDeck
Scripts/bundle.sh --open
```

## Status

v1.1.

## License

MIT
