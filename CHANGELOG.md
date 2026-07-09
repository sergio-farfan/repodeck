# Changelog

All notable changes to RepoDeck will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-07-08

### Added

- DMG installer with a styled disk image: Finder icon-view layout, background artwork, and an `/Applications` drag target (`Scripts/make-dmg.sh`).
- GitHub Release distribution: checksummed (`.sha256`) `.dmg`, published via `gh release create`/`upload`.
- Installation docs.
- dev.to article source.

### Changed

- App icon redesigned as a purple commit graph on black.

## [1.1.0] - 2026-07-08

### Added

- App icon.
- Theme system (System/Light/Dark, accent color, fonts, size) with a Settings window (⌘,).
- Draggable Changes/History splitter.
- History search by message, author, path, and content.

### Fixed

- Settings-window theming.
- Stale search errors.

## [1.0.0] - 2026-07-08

### Added

- Multi-repo dashboard.
- Folder tracking with recursive repo discovery.
- Live FSEvents status.
- Stage, commit, and sync (fetch/pull/push).
- Bulk Fetch All / Pull All.
- Sidebar filter and pinning.
- History list.

[1.2.0]: https://github.com/sergio-farfan/repodeck/releases/tag/v1.2.0
[1.1.0]: https://github.com/sergio-farfan/repodeck/releases/tag/v1.1.0
[1.0.0]: https://github.com/sergio-farfan/repodeck/releases/tag/v1.0.0
