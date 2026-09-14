# Contributing to RepoDeck

RepoDeck is a native macOS Git dashboard. Contributions should preserve local Git behavior, make repository mutations explicit, and keep common workflows understandable from the keyboard and with assistive technology.

## Build and test

Use macOS 15 or newer and Swift 6.2 or newer. CI uses Xcode 26.3 on a macOS 15 runner. Select a full Xcode installation when building the universal application.

```sh
swift build
swift test
for script in Scripts/*.sh Tests/ReleaseScripts/*.sh; do
    bash -n "$script"
done
for test_script in Tests/ReleaseScripts/test-*.sh; do
    "$test_script"
done
swift run RepoDeck
```

Run the test suite directly so failures and diagnostics remain visible. The packaging regression tests use disposable local Git repositories and do not publish anything. See [TESTING.md](TESTING.md) for the manual test matrix and [architecture](docs/architecture.md) for the boundaries between the app, state, and Git engine.

## Changes and pull requests

- Start from a focused issue or describe a concrete developer workflow in the pull request. Keep unrelated changes separate.
- Add regression coverage for bugs affecting repository state, subprocess lifetime, persistence, parsing, or async ordering. Exercise real temporary repositories where Git behavior matters.
- Keep Git arguments in arrays and paths literal. Avoid shell interpolation for repository/file actions. Do not add automatic Git mutations to discovery, status, or hosting refreshes.
- Propagate cancellation; do not replace errors with clean/empty state when users could lose information. Bound subprocess output and background concurrency.
- Preserve command names, keyboard conventions, accessible descriptions, and system appearance settings. Check UI changes with Full Keyboard Access and VoiceOver.
- Use conventional commit subjects (`fix:`, `feat:`, `docs:`, `test:`, `chore:`). A PR description should explain the changed behavior and actual validation, including any checks not performed.

Do not include credentials, private repository contents, or personal configuration in fixtures. Do not edit a contributor's global Git settings. Releases are a separate maintainer action documented in [releasing](docs/releasing.md).
