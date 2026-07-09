# CLAUDE.md

Guidance for Claude Code sessions in this repo (RepoDeck — native SwiftUI macOS dashboard for the git status of all your local repositories).

## Build & Test

- `swift build` — debug build
- `swift test` — unit tests (`RepoDeckKitTests`) via the SPM harness in `Package.swift`; run plainly, no output-truncating pipes
- `swift run RepoDeck` — run from source
- `Scripts/bundle.sh --open` — build a Release `dist/RepoDeck.app` (ad-hoc signed) and open it
- `Scripts/make-dmg.sh [--release]` — package `dist/RepoDeck.app` into a styled, compressed DMG + `.sha256` in `dist/` (gitignored; a release asset is canonical). `--release` also publishes/updates the GitHub Release for the current version.

## Release Process

RepoDeck ships local releases (no CI).

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist`.
2. Add the new version's section to `CHANGELOG.md` (Keep a Changelog format).
3. Commit.
4. `Scripts/make-dmg.sh --release` — builds, signs (ad-hoc unless `SIGN_IDENTITY` is set), packages the DMG, and publishes the GitHub Release with checksummed assets and changelog-derived notes.
5. `git tag vX.Y.Z && git push origin main --tags`.

**Deviation from the family convention (documented):** alttab publishes releases via a `release.yml` GitHub Actions workflow on `macos-*` runners triggered by `v*` tags. RepoDeck does not have this workflow yet; to adopt it, copy alttab's `.github/workflows/release.yml` and wire `Scripts/make-dmg.sh` in as its packaging step.

## Notes

- Repo-local git identity is `sergio.farfan@gmail.com`.
- Commits are conventional (`feat:`, `fix:`, `docs:`, `chore:`, ...).
