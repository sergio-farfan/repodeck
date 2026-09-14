# Repository guidance

RepoDeck is a native SwiftUI macOS Git client. Read [AGENTS.md](AGENTS.md) for repository-level agent guidance and [CONTRIBUTING.md](CONTRIBUTING.md) for contribution checks.

## Build and test

- `swift build` — debug build of the app and libraries.
- `swift test` — run the full test suite plainly; do not truncate its output with pipes.
- Run each `Tests/ReleaseScripts/test-*.sh` script — offline release guard and draft-packaging regressions.
- `swift run RepoDeck` — run from source.
- `Scripts/bundle.sh --open` — build a universal development app and open it.
- `Scripts/make-dmg.sh` — package an installer without publishing.

The declared baseline is Swift 6.2+, macOS 15+. CI uses Xcode 26.3. See [architecture](docs/architecture.md) and [testing](TESTING.md) before changing subprocess ownership or repository state coordination.

## Releases

RepoDeck's standard distribution is a GitHub release with an **ad-hoc signed, unnotarized** app. Sergio is not enrolled in the Apple Developer Program. Developer ID signing and notarization are optional future capabilities, not release prerequisites; do not require enrollment or credentials to publish this distribution. Keep the signing status explicit and document the app-specific first-launch approval in macOS Privacy & Security.

Follow [docs/releasing.md](docs/releasing.md). A release requires a clean checkout and an existing local/remote `vX.Y.Z` tag equal to HEAD. `--release` creates a draft only and refuses existing releases; it never replaces assets or creates a tag implicitly. Add `--prerelease` for a beta draft excluded from latest. The release workflow validates the same source commit on both Mac architectures before packaging. Signing/notarization use explicitly supplied keychain identities and profiles. Publication and credential provisioning require a separate explicit maintainer request.

Do not alter global Git identity. Use the contributor's configured identity for commits and isolated test identities inside fixtures. Prefer focused conventional commit subjects.

Use Sergio Farfan's existing Git identity for new agent-assisted work. Never add AI author headers, AI authorship notices, or AI `Co-authored-by` trailers to files or commits.

The documented maintainer Git identity is Sergio Farfan <sergio.farfan@gmail.com>.
