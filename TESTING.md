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

Subprocess timeout tests measure from the child's readiness timestamp, with a separate bounded wait for a process slot. Cancellation fixtures synchronize with a started descendant before cancelling. Keep execution and cleanup bounds strict without counting unrelated test jobs' queue time against them.

Release workflow validation reuses this native ARM/Intel matrix at one resolved commit and requires both jobs to pass before packaging. Offline release tests use disposable local repositories and fake packaging/GitHub tools to cover stable versus prerelease flags, existing-release refusal, and tags moving after validation; they do not upload, sign, or build the app.

## Manual acceptance matrix

These are required checks to perform before a public release, not a record that they have already passed. Use temporary repositories and non-production hosting projects.

| Area | Setup and checks |
| --- | --- |
| Repository state | Fresh/unborn repository, detached HEAD, staged/unstaged rename, Unicode/tab/newline filenames, executable files, symlinks, large/truncated status, linked worktrees and submodules. Verify displayed state against Git. |
| Mutations | Stage/unstage file and hunk, commit, pull/push/fetch, stash apply/pop/drop, and undo. Confirm staged partial work is preserved, stale selections are rejected, operations do not overlap, and conflicts retain all recoverable work. |
| Cancellation | Run a command with children, stop while running, stop while six slots are occupied, switch repositories, and close its pane/window. Confirm jobs do not continue mutating repositories after cancellation. |
| Keyboard and VoiceOver | Turn on Full Keyboard Access and VoiceOver. Select repositories, search, inspect diffs, stage/unstage, commit, open settings, resize panes, and dismiss dialogs. Every actionable control must have a meaningful name and visible focus. |
| Appearance | Light/dark, Increase Contrast, Reduce Motion, enlarged UI/monospace fonts, long repository/branch names, and smallest supported window. Status must remain understandable without color. |
| Editors and terminals | Verify the selected installed editor/terminal opens the selected path, including spaces and quotes. A missing configured tool must offer a useful recovery path. |
| Hosting | With test credentials, verify GitHub and GitLab where configured; verify unsupported hosts display useful guidance; multi-account/host setups, forks with duplicate branch names, non-default remotes, no open PR, permission errors, offline launch and reconnect. Check links open the correct project's PR/MR. |
| Distribution | Launch the downloaded final installer on a clean Apple silicon and Intel Mac running supported macOS. For notarized distribution, verify signatures and stapled tickets, including an offline first launch. |

Record the build commit, macOS/toolchain, scenarios exercised, and failures in the release draft. Automated fixture tests alone do not validate real credential helpers, accessibility behavior, or Gatekeeper.

## Local beta validation — 2026-09-13

The development changes were validated on macOS 27.0 with Xcode 26.6 / Swift 6.3.3. CI declares Xcode 26.3 / Swift 6.2 and separate native Apple silicon and Intel runners. The supported deployment minimum remains macOS 15; a clean-machine macOS 15 check is still required before release.

- The app and libraries build; the universal app contains both arm64 and x86_64 slices and passes ad-hoc signature verification.
- The final run passed **335 tests across 25 suites on each architecture**: Apple silicon and the compiled Intel test bundle under Rosetta. Xcode's installed SwiftPM helper was ARM-only, so the Intel run used a temporary x86_64 loader calling the standard `Testing.__swiftPMEntryPoint` on the unchanged test bundle. Native Intel CI avoids that local toolchain workaround.
- Every shell script passed syntax checks, and offline release preflight regressions passed. No release was created or uploaded.
- Visual inspection exercised the dashboard, linked sibling-worktree discovery, and history graph in disposable repositories. After the UI automation connection recovered, native accessibility inspection and screenshots verified basic navigation, the compact Workspace menu, and the history graph at a 900×582 window size. The full keyboard/VoiceOver matrix, appearance settings, and editor/terminal combinations are not certified by this run.
- No live hosting writes, Developer ID signing, notarization, or clean-machine downloaded-installer verification were performed. Those remain release gates above; hosting tests use isolated transport responses and local Git remotes.

See the test runner's reported total rather than a fixed README count as cases are added. The broader workflows remain a development beta until the manual gates pass.
