# Testing RepoDeck

## Automated checks

```sh
swift build
swift test
for test_script in Tests/ReleaseScripts/test-*.sh; do "$test_script"; done
Scripts/bundle.sh
```

The last command produces and verifies a universal app; it does not launch or publish it. Do not claim Developer ID signing or notarization was validated unless those paths were actually exercised with the corresponding identity and notarization profile. CI is defined in `.github/workflows/ci.yml` and uses Xcode 26.3 on macOS 15, testing natively on both Apple silicon (`macos-15`) and Intel (`macos-15-intel`). These labels follow GitHub's [runner image inventory](https://github.com/actions/runner-images#available-images); update them deliberately if availability changes.

Keep tests isolated from shared process state: Swift Testing runs unrelated tests concurrently in the same process. Use per-test temporary directories/configuration and injected services. A `.serialized` suite does not serialize itself against unrelated suites.

Subprocess timeout tests measure monotonic execution from successful spawn through reaping inside the runner, excluding process-slot admission and test-task resumption. A watchdog may legitimately stop a process before it writes a readiness marker. Cancellation fixtures synchronize with a started descendant before cancelling; readiness waits also observe command completion so launch errors and early exits are reported directly. Keep execution and cleanup bounds strict without counting unrelated test jobs' queue time against them.

Release workflow validation reuses this native ARM/Intel matrix at one resolved commit and requires both jobs to pass before packaging. Offline release tests use disposable local repositories and fake packaging/GitHub tools to cover stable versus prerelease flags, existing-release refusal, and tags moving after validation; they do not upload, sign, or build the app.

## Manual acceptance matrix

This matrix guides manual validation; it is not a record that the checks have passed. Record completed and outstanding checks so the maintainer can make an explicit publication decision with those limitations. Use temporary repositories and non-production hosting projects. For stable 1.10.1, the maintainer authorized publication with the outstanding checks recorded below.

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

Record the build commit, macOS/toolchain, scenarios exercised, failures, and outstanding checks in the release notes. Automated fixture tests alone do not validate real credential helpers, accessibility behavior, or Gatekeeper.

## Version 1.11.0 stable release — 2026-09-14

[Version 1.11.0](https://github.com/sergio-farfan/repodeck/releases/tag/v1.11.0) was published as stable/latest at `2026-09-14T07:34:29Z`, using annotated tag `v1.11.0` at `201cc67ce43839f7a6582f62a0390322e5165337`, version 1.11.0/build 14. The implementation and release documentation were committed and pushed to main before tagging.

[Main CI](https://github.com/sergio-farfan/repodeck/actions/runs/34817368090) and the [release workflow](https://github.com/sergio-farfan/repodeck/actions/runs/34817711162) both passed **389 tests across 28 suites on each native Mac architecture**, plus builds, shell syntax checks, resource fixtures, and offline release regressions. The release workflow verified the same existing local/remote tag and source commit before each validation stage and packaging. It built the universal installer with Xcode 26.3 / Swift 6.2.4 using the standard ad-hoc signature. CI reported that Finder layout was applied; its visual appearance was not separately inspected locally.

The draft's three assets were downloaded to a fresh directory before publication. The checksum and disk-image integrity checks passed, and both DMG names were identical. Read-only mounting confirmed app version/build, macOS 15 minimum, arm64/x86_64 slices, strict ad-hoc signature verification, the app icon, and the Applications link. After publication, the unauthenticated evergreen download was fetched and matched the same SHA-256: `ed352820b0a7573613ac9b4362986190771c9c7cccf30dbb94bf3499e069999c`. No existing release tag or asset was moved or replaced.

The distribution is unnotarized. Clean-machine installation/first launch, the full keyboard/VoiceOver/appearance matrix, and live hosting-write permissions remain outstanding manual checks; the development evidence below describes the narrower scenarios actually exercised. These limits are also stated in the published release notes.

## Git identity setup — development validation, 2026-09-14

The working changes passed **379 tests across 28 suites**, a debug build, and a universal arm64/x86_64 build with Xcode 26.6 / Swift 6.3.3. The refreshed development bundle passed strict ad-hoc signature verification. New regressions cover scoped identity reads/writes, repository overrides, strict UTF-8/input handling, preservation of unrelated configuration, partial saves, cancellation, stale repository/configuration/tool checks, late responses, scope-specific drafts, and identity read failures. Global-write tests use wrapper executables that direct Git to fixture-owned configuration files; they do not modify the developer's global settings.

Native checks in an isolated test app on macOS 27 verified opening the setup from the sidebar, saving a repository identity, saving a separate default while retaining and explaining the repository override, updating the footer, following Details & Help → Configure Git Identity, and cancelling an edited form without saving it. The form remained scrollable with its Save/Cancel controls visible. No real repository identity or SSH configuration was changed during validation.

Manual follow-up: verify the Repository Settings entry, an incomplete identity, inaccessible configuration with retry, linked-worktree overrides, and keyboard/VoiceOver behavior on supported macOS versions. The full distribution and accessibility matrix remains separate from these checks.

### Commit author resolution follow-up

The follow-up passed **389 tests across 28 suites**. Ten new regressions cover Git-resolved authors versus editable defaults, author-specific configuration and inherited environment values, matching the author recorded by an ordinary commit, missing/invalid authors without blocking configuration repair, invalid overrides remaining after a verified save, cancellation, strict output parsing, and read-only preservation. All configuration writes use isolated fixtures. After the final Help wording change, its five content/search tests passed again.

Native checks in the isolated app verified displaying an author override while retaining different editable defaults, showing a selectable diagnostic for an invalid override, and preserving that warning after successfully saving the defaults. Scrolling exposed the full explanation and Reload control while Save/Done remained visible. A final screenshot check at a 220-point sidebar width verified the compact unavailable explanation and Configure Author/Retry controls without truncation or overlap. The final universal arm64/x86_64 development build passed strict ad-hoc signature verification. These checks do not certify the full accessibility or supported-macOS matrix above.

## Error messages and offline Help — development validation, 2026-09-13

Before the subsequent diff-pane replacement, the working changes based on `9e3e697` passed the full suite: **354 tests across 27 suites**. After UI/content refinements, the 26 Help, error-guidance, and application-state tests passed again; the nine error-guidance tests also passed after bounding diagnostic classification. Debug and universal release-configuration builds passed with Xcode 26.6 / Swift 6.3.3. That universal development app contains both arm64 and x86_64 and passes ad-hoc signature verification. It is not a published release.

Native UI checks used a separate test application with an isolated temporary repository and preferences on macOS 27. Checks covered:

- A 100-line diagnostic: bounded inline title/operation/explanation, accessible recovery controls, and scrollable full technical details.
- Success and mixed failed/skipped bulk summaries, readable per-repository outcomes, expandable reasons, and disabled navigation for a repository no longer in the app.
- The summary and error were readable together without sidebar/titlebar overlap in the checked state. Moving the native diff inspector to the outer navigation split removed the observed toolbar-material overlap, but the later crash below showed that this placement was not a complete fix.
- Light/dark appearance, an 800-point-wide window, and the 18-point font setting. Sync controls reflow and sidebar labels retain usable width.
- Help → RepoDeck Help, search for `403`, related-topic navigation and Back, and contextual Help clearing an earlier query. On this macOS version, ⌘? opens the system Help menu/search; selecting RepoDeck Help opens the offline guide.

Full VoiceOver/Full Keyboard Access, Increase Contrast, exact 800×500 layout, native Intel execution, macOS 15, and a clean-machine installation were not revalidated in this pass. These UI checks do not validate live hosting credentials or remote write permissions.

### Diff presentation follow-up

A crash was subsequently reported on macOS 27. An isolated native reproduction triggered the same AppKit constraint-update loop when opening **View Diff**, with `_postWindowNeedsUpdateConstraints` in the exception stack. The native inspector has been replaced with an `HSplitView` in the detail column below the bulk summary. Its first workspace child remains mounted when the diff opens or closes, and an explicit geometry constraint keeps both panes inside the available detail area. The window minimum grows while a diff is visible to leave room for the widest supported sidebar.

After this replacement, all 354 tests across 27 suites passed again. An isolated native test on macOS 27 completed 40 cycles of file-diff opening/closing, switching between two disposable repositories, resizing, scan-indicator transitions, error/bulk-summary presentation, and command-pane visibility changes; each cycle verified the commit draft remained intact. A focused unified-log check found no constraint-loop warnings during the run. These transitions exercised injected presentation state, not live remote bulk operations. The previously crashing View Diff action and Close control were also exercised directly. After the final minimum-width adjustment, the 1100-point diff layout and Help menu/search were checked again, and a universal arm64/x86_64 development bundle was rebuilt and its ad-hoc signature verified. Native divider dragging and the fully expanded sidebar still need manual validation. Full manual coverage below remains separate from this bounded regression run.

Use disposable repositories and record the macOS version, build, window size, and result for each check:

- Open and close file and commit diffs repeatedly, including an error or empty diff, and drag the divider between the workspace and diff pane.
- Switch repositories while a diff is open, then return. Verify that each worktree retains its own commit draft, conflict draft, selected workspace, and diff selection.
- Resize with the sidebar visible, both with and without a diff, down to the supported minimum size for each layout. Check normal and enlarged fonts for readable controls and stable pane widths.
- Start a folder scan and disposable-repository bulk operations while a diff is open. Check toolbar progress changes, completion summaries, and sidebar visibility for layout loops or overlap.
- Display a long error and a bulk summary together. Open and dismiss Details & Help and Results, use safe corrective actions, then open, search, and close the Help window. Verify that messages and controls remain readable and that navigation preserves drafts.

## Local beta validation — 2026-09-13

The development changes were validated on macOS 27.0 with Xcode 26.6 / Swift 6.3.3. CI declares Xcode 26.3 / Swift 6.2 and separate native Apple silicon and Intel runners. The supported deployment minimum remains macOS 15; a clean-machine macOS 15 check was not performed.

- The app and libraries build; the universal app contains both arm64 and x86_64 slices and passes ad-hoc signature verification.
- The final run passed **335 tests across 25 suites on each architecture**: Apple silicon and the compiled Intel test bundle under Rosetta. Xcode's installed SwiftPM helper was ARM-only, so the Intel run used a temporary x86_64 loader calling the standard `Testing.__swiftPMEntryPoint` on the unchanged test bundle. Native Intel CI avoids that local toolchain workaround.
- Every shell script passed syntax checks, and offline release preflight regressions passed. No release was created or uploaded during this development validation.
- Visual inspection exercised the dashboard, linked sibling-worktree discovery, and history graph in disposable repositories. After the UI automation connection recovered, native accessibility inspection and screenshots verified basic navigation, the compact Workspace menu, and the history graph at a 900×582 window size. The full keyboard/VoiceOver matrix, appearance settings, and editor/terminal combinations are not certified by this run.
- No live hosting writes or clean-machine downloaded-installer verification were performed. Developer ID signing and notarization were not exercised because they are outside the standard distribution. Hosting tests use isolated transport responses and local Git remotes.

Native GitHub CI also passed **335 tests across 25 suites on each architecture**, along with builds, shell checks, release-script regressions, and a universal app build, for the merged feature source at `cd99330f9be56881b0f94f89501916b3c95d6b62`: [validation run](https://github.com/sergio-farfan/repodeck/actions/runs/34795082178). Version 1.10.0 (build 12) was prepared as a beta draft; its tagged-source and installer verification results are recorded below. That draft remains unpublished and is superseded by stable 1.10.1.

See the test runner's reported total rather than a fixed README count as cases are added. The results above describe the development validation at that time; they do not certify the outstanding manual scenarios.

## Version 1.10.0 draft installer — 2026-09-13

The beta draft uses annotated tag `v1.10.0` at `3fe106c3cca1eb2ab5e0a357ebcb3612a083038d`, version 1.10.0/build 12. [CI for that exact commit](https://github.com/sergio-farfan/repodeck/actions/runs/34797497419) passed 335 tests across 25 suites on each native Mac architecture, plus builds and packaging checks. The installer was built locally with Xcode 26.6/Swift 6.3.3 on macOS 27.0 after clean-source and local/remote tag checks.

The three assets were downloaded from the GitHub draft to a fresh directory. The SHA-256 sidecar passed, both DMG names matched the local image byte for byte, and the downloaded image passed integrity verification. Read-only mounting confirmed version/build, both architecture slices, the strict ad-hoc signature, and the Applications link. These checks do not certify installation or offline launch on clean Macs. Finder's custom layout was denied or timed out and still needs visual acceptance. The applicable manual matrix above remains pending; Developer ID signing and notarization are optional and do not block this distribution. The draft has not been publicly published.

A live GitHub read-only smoke check in the tagged development app authenticated the configured account and displayed the public RepoDeck repository's fork PR list and details. It rejected an outdated test-merge check context with a visible refresh explanation. No hosting submissions or account changes were made; this does not replace the hosting permissions/protection matrix.

An earlier [feature-merge run](https://github.com/sergio-farfan/repodeck/actions/runs/34796996128) failed the short-timeout fixture's readiness expectation. A watchdog may correctly stop a child before it writes a readiness marker. The successful tagged-source run is separate evidence, not a reclassification of that earlier failure; follow-up test changes must retain strict execution/cleanup bounds and report early completion accurately.

## Version 1.10.1 follow-up validation — 2026-09-13

The timeout-diagnostics follow-up passed 338 tests across 25 suites locally, including timeout-before-readiness, launch-error, and early-exit regressions. The new resource fixture compiles the actual icon locator and runs copied executables from an unrelated directory, covering app resources, nested bundles, executable-adjacent SwiftPM bundles, and missing resources without a fatal accessor. All seven resource scenarios passed, along with the app build, universal bundle verification, shell syntax checks, and offline release regressions.

Native inspection of the rebuilt app verified live GitHub review navigation and the bounded review-list layout. Full minimum-window, large-text, and VoiceOver acceptance remains pending. The icon report in #1 concerned older packaging; the 1.10.0 universal bundle included its nested resource bundle. Version 1.10.1 makes missing icon resources nonfatal and fixes the plain-executable fallback, without claiming a reproduced launch failure in the 1.10.0 universal installer.

### Stable publication and validation limits

[Version 1.10.1](https://github.com/sergio-farfan/repodeck/releases/tag/v1.10.1) was published as the latest stable release on September 13, 2026, at 21:45 MDT (`2026-09-14T03:45:19Z`), at tagged source `0c4d47afc26e05aaa0362516287a73ef86098b5e`. [Native CI for that commit](https://github.com/sergio-farfan/repodeck/actions/runs/34799832600) passed **338 tests across 25 suites on each architecture**, using Xcode 26.3 / Swift 6.2.4 on Apple silicon and Intel.

The existing three assets were reused from the verified draft. Local and downloaded installer checks confirmed checksum and image integrity, both architecture slices, and the ad-hoc app signature. After publication, the public evergreen `RepoDeck.dmg` download was fetched without authentication; its SHA-256 was `a3098d16dbaf76debf4c298adc1590cef0d366502a2bac8ec5a1599f417093bc`, matching the verified installer, and the image was byte-identical to the local build. The release is unnotarized, following the project's standard distribution; no Developer ID membership or notarization is required. The version 1.10.0 tag and assets remain unchanged in an unpublished, superseded draft.

The maintainer explicitly chose stable publication with clean-machine installation and first launch, the full keyboard/VoiceOver/appearance matrix, and live GitHub/GitLab write permissions and protection checks still outstanding. Those are validation limits, not checks that passed. The earlier read-only GitHub smoke checks and automated fixtures do not establish those results.
