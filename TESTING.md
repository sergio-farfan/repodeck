# Testing RepoDeck

## Automated checks

```sh
swift build
swift test
for test_script in Tests/ReleaseScripts/test-*.sh; do "$test_script"; done
Scripts/bundle.sh
```

The last command produces and verifies a universal development app; it does not launch or publish it. Do not claim a signed or notarized release was validated unless those paths were actually exercised with a Developer ID and notarization profile. CI is defined in `.github/workflows/ci.yml` and uses Xcode 26.3 on macOS 15, testing natively on both Apple silicon (`macos-15`) and Intel (`macos-15-intel`). These labels follow GitHub's [runner image inventory](https://github.com/actions/runner-images#available-images); update them deliberately if availability changes.

Keep tests isolated from shared process state: Swift Testing runs unrelated tests concurrently in the same process. Use per-test temporary directories/configuration and injected services. A `.serialized` suite does not serialize itself against unrelated suites.

Subprocess timeout tests measure monotonic execution from successful spawn through reaping inside the runner, excluding process-slot admission and test-task resumption. A watchdog may legitimately stop a process before it writes a readiness marker. Cancellation fixtures synchronize with a started descendant before cancelling; readiness waits also observe command completion so launch errors and early exits are reported directly. Keep execution and cleanup bounds strict without counting unrelated test jobs' queue time against them.

Release workflow validation reuses this native ARM/Intel matrix at one resolved commit and requires both jobs to pass before packaging. Offline release tests use disposable local repositories and fake packaging/GitHub tools to cover stable versus prerelease flags, existing-release refusal, and tags moving after validation; they do not upload, sign, or build the app.

## Manual acceptance matrix

These are required checks to perform before a public release, not a record that they have already passed. Use temporary repositories and non-production hosting projects.

The standard release is ad-hoc signed and unnotarized. Developer ID signing and notarization are not release gates. Their validation applies only if the maintainer later opts into that distribution and advertises those capabilities.

| Area | Setup and checks |
| --- | --- |
| Repository state | Fresh/unborn repository, detached HEAD, staged/unstaged rename, Unicode/tab/newline filenames, executable files, symlinks, large/truncated status, linked worktrees and submodules. Verify displayed state against Git. |
| Mutations | Stage/unstage file and hunk, commit, pull/push/fetch, stash apply/pop/drop, and undo. Confirm staged partial work is preserved, stale selections are rejected, operations do not overlap, and conflicts retain all recoverable work. |
| Cancellation | Run a command with children, stop while running, stop while six slots are occupied, switch repositories, and close its pane/window. Confirm jobs do not continue mutating repositories after cancellation. |
| Keyboard and VoiceOver | Turn on Full Keyboard Access and VoiceOver. Select repositories, search, inspect diffs, stage/unstage, commit, open settings, resize panes, and dismiss dialogs. Every actionable control must have a meaningful name and visible focus. |
| Appearance | Light/dark, Increase Contrast, Reduce Motion, enlarged UI/monospace fonts, long repository/branch names, and smallest supported window. Status must remain understandable without color. |
| Editors and terminals | Verify the selected installed editor/terminal opens the selected path, including spaces and quotes. A missing configured tool must offer a useful recovery path. |
| Hosting | With test credentials, verify GitHub and GitLab where configured; verify unsupported hosts display useful guidance; multi-account/host setups, forks with duplicate branch names, non-default remotes, no open PR, permission errors, offline launch and reconnect. Check links open the correct project's PR/MR. |
| Distribution | Verify the checksum and ad-hoc app signature, then install and launch the download on clean Apple silicon and Intel Macs running supported macOS. Check the documented app-specific Privacy & Security approval and offline launch. Only for an optionally notarized release, also verify Developer ID signatures and stapled tickets. |

Record the build commit, macOS/toolchain, scenarios exercised, and failures in the release draft. Automated fixture tests alone do not validate real credential helpers, accessibility behavior, or Gatekeeper.

## Local beta validation — 2026-09-13

The development changes were validated on macOS 27.0 with Xcode 26.6 / Swift 6.3.3. CI declares Xcode 26.3 / Swift 6.2 and separate native Apple silicon and Intel runners. The supported deployment minimum remains macOS 15; a clean-machine macOS 15 check is still required before release.

- The app and libraries build; the universal app contains both arm64 and x86_64 slices and passes ad-hoc signature verification.
- The final run passed **335 tests across 25 suites on each architecture**: Apple silicon and the compiled Intel test bundle under Rosetta. Xcode's installed SwiftPM helper was ARM-only, so the Intel run used a temporary x86_64 loader calling the standard `Testing.__swiftPMEntryPoint` on the unchanged test bundle. Native Intel CI avoids that local toolchain workaround.
- Every shell script passed syntax checks, and offline release preflight regressions passed. No release was created or uploaded during this development validation.
- Visual inspection exercised the dashboard, linked sibling-worktree discovery, and history graph in disposable repositories. After the UI automation connection recovered, native accessibility inspection and screenshots verified basic navigation, the compact Workspace menu, and the history graph at a 900×582 window size. The full keyboard/VoiceOver matrix, appearance settings, and editor/terminal combinations are not certified by this run.
- No live hosting writes or clean-machine downloaded-installer verification were performed; those remain release gates above. Developer ID signing and notarization were not exercised because they are outside the standard distribution. Hosting tests use isolated transport responses and local Git remotes.

Native GitHub CI also passed **335 tests across 25 suites on each architecture**, along with builds, shell checks, release-script regressions, and a universal app build, for the merged feature source at `cd99330f9be56881b0f94f89501916b3c95d6b62`: [validation run](https://github.com/sergio-farfan/repodeck/actions/runs/34795082178). Version 1.10.0 (build 12) is being prepared as a beta draft; its release notes record the final tagged commit, packaging toolchain, and installer verification results.

See the test runner's reported total rather than a fixed README count as cases are added. The broader workflows remain a development beta until the manual gates pass.

## Version 1.10.0 draft installer — 2026-09-13

The beta draft uses annotated tag `v1.10.0` at `3fe106c3cca1eb2ab5e0a357ebcb3612a083038d`, version 1.10.0/build 12. [CI for that exact commit](https://github.com/sergio-farfan/repodeck/actions/runs/34797497419) passed 335 tests across 25 suites on each native Mac architecture, plus builds and packaging checks. The installer was built locally with Xcode 26.6/Swift 6.3.3 on macOS 27.0 after clean-source and local/remote tag checks.

The three assets were downloaded from the GitHub draft to a fresh directory. The SHA-256 sidecar passed, both DMG names matched the local image byte for byte, and the downloaded image passed integrity verification. Read-only mounting confirmed version/build, both architecture slices, the strict ad-hoc signature, and the Applications link. These checks do not certify installation or offline launch on clean Macs. Finder's custom layout was denied or timed out and still needs visual acceptance. The applicable manual matrix above remains pending; Developer ID signing and notarization are optional and do not block this distribution. The draft has not been publicly published.

A live GitHub read-only smoke check in the tagged development app authenticated the configured account and displayed the public RepoDeck repository's fork PR list and details. It rejected an outdated test-merge check context with a visible refresh explanation. No hosting submissions or account changes were made; this does not replace the hosting permissions/protection matrix.

An earlier [feature-merge run](https://github.com/sergio-farfan/repodeck/actions/runs/34796996128) failed the short-timeout fixture's readiness expectation. A watchdog may correctly stop a child before it writes a readiness marker. The successful tagged-source run is separate evidence, not a reclassification of that earlier failure; follow-up test changes must retain strict execution/cleanup bounds and report early completion accurately.

## Version 1.10.1 follow-up validation — 2026-09-13

The timeout-diagnostics follow-up passed 338 tests across 25 suites locally, including timeout-before-readiness, launch-error, and early-exit regressions. The new resource fixture compiles the actual icon locator and runs copied executables from an unrelated directory, covering app resources, nested bundles, executable-adjacent SwiftPM bundles, and missing resources without a fatal accessor. All seven resource scenarios passed, along with the app build, universal bundle verification, shell syntax checks, and offline release regressions.

Native inspection of the rebuilt app verified live GitHub review navigation and the bounded review-list layout. Full minimum-window, large-text, and VoiceOver acceptance remains pending. The icon report in #1 concerned older packaging; the 1.10.0 universal bundle included its nested resource bundle. Version 1.10.1 makes missing icon resources nonfatal and fixes the plain-executable fallback, without claiming a reproduced launch failure in the 1.10.0 universal installer.

The version 1.10.0 tag and assets remain unchanged. The 1.10.1 draft notes record the final source commit, native CI, and downloaded-installer evidence when prepared; public publication remains subject to the manual matrix above.
