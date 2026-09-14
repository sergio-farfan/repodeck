# RepoDeck contributor and agent guidance

RepoDeck is a native macOS 15+ Git client. Read [CONTRIBUTING.md](CONTRIBUTING.md), [architecture](docs/architecture.md), and [TESTING.md](TESTING.md) before changing behavior. This file is the repository-level guidance for coding agents; [CLAUDE.md](CLAUDE.md) points to the same requirements.

## Architecture and style

- `Sources/RepoDeckKit/`: Git execution and parsing, repository discovery, file watching, and hosting adapters. Keep Git arguments as arrays and selected paths literal.
- `Sources/RepoDeckCore/`: observable application/worktree state and scheduling. Inject dependencies for tests; keep SwiftUI and AppKit presentation in the app target.
- `Sources/RepoDeck/`: SwiftUI/AppKit views, native panels, and editor/terminal launch actions. Preserve keyboard access, meaningful accessibility labels, and system appearance settings.
- `Tests/RepoDeckKitTests/` and `Tests/RepoDeckCoreTests/`: use Swift Testing and the existing isolated temporary-repository fixtures. Never modify global Git configuration or assume unrelated test suites execute serially.
- Use four-space indentation and neighboring naming/style conventions. There is no mandatory formatter.

## Safety requirements

- Discovery, status, diffs, and hosting refreshes must not mutate repositories. Preserve useful error and partial-result states rather than displaying failures as clean repositories.
- Coordinate application-issued mutations by the shared Git directory and revalidate worktree, branch, expected commit, and operation state after acquiring capacity. Confirmation dialogs must retain the identity of the state the user reviewed.
- Partial staging must preserve exact bytes and supported file metadata. Require lossless text decoding and machine-readable diffs without text conversion, external diff helpers, or color. Reject unsupported cases with a whole-file alternative; never silently normalize content.
- Keep stash selections bound to object IDs and undo records bound to their original worktree and branch. Do not claim an atomic transaction against external Git processes when the underlying Git command cannot provide one.
- Conflict saves and resolution actions must detect stale content/index state. Keep Save and Mark Resolved explicit and preserve drafts on errors. Safe worktree removal must protect ignored and untracked local files.
- Subprocess acquisition, execution, and pipe handling must remain cancellable and bounded. Do not launch background child processes that outlive their owned operation.
- Hosting writes must show their destination and action, revalidate the reviewed head/account, honor provider capabilities, and preserve drafts. Reconcile uncertain create/comment responses before retrying, using the same operation identifier.

## Verification

The baseline is Swift 6.2+, with Xcode 26.3 in CI. Run checks appropriate to the change:

```sh
swift build
swift test
for script in Scripts/*.sh Tests/ReleaseScripts/*.sh; do
    bash -n "$script"
done
for test_script in Tests/ReleaseScripts/test-*.sh; do
    "$test_script"
done
```

Run Swift tests directly without truncating their output with pipes. Add regression coverage for data safety, subprocess lifetime, persistence, parsing, and asynchronous ordering. UI and distribution checks in [TESTING.md](TESTING.md) require separate manual validation; fixture tests are not evidence of live hosting permissions, VoiceOver behavior, signing, or notarization.

`Scripts/bundle.sh` builds and verifies a universal development app. Build artifacts belong in ignored output directories and must not enter commits.

## Changes and releases

Use focused conventional commit subjects and the contributor's configured Git identity. Never commit credentials, personal settings, private repository data, `.build/`, app bundles, or installers. Describe actual validation and remaining limitations in pull requests.

Follow [docs/releasing.md](docs/releasing.md). Release builds require clean source and exact local/remote tag equality with the checkout. Never move release tags or replace existing release assets automatically. Draft preparation does not imply approval to publish a release or provision signing credentials; follow the maintainer's explicit instructions for those actions.
