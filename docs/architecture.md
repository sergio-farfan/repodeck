# Architecture

RepoDeck is a Swift Package Manager application for macOS 15+. It uses the user's installed Git executable and optional hosting integrations, rather than maintaining its own Git implementation.

- **RepoDeckKit** contains repository discovery/context, Git operations and parsers, file watching, hosting adapters, and subprocess scheduling. Plain value types and pure parsers keep filesystem and network work separate from representation.
- **RepoDeckCore** contains observable application and repository state, refresh coordination, operation state, and background scheduling. It can be tested independently of SwiftUI views.
- **RepoDeck** contains SwiftUI/AppKit presentation, native panels and application launch actions, commands, and appearance settings.

## Messages and Help

`OperationFailure` maps recognized diagnostics to a short explanation and safe navigation or inspection actions. It retains the operation, exit code, and full original output for the scrollable details sheet. Unknown diagnostics remain available without guessing a specific remedy. Recovery buttons do not retry writes, delete lock files, or replace conflict drafts.

Bulk results retain repository identities and their success/failure/skipped outcomes independently of later status refreshes. The summary occupies a row in the detail column above an `HSplitView`. The workspace remains mounted as the split's first child while a resizable diff pane is added or removed as the second child. This keeps diff presentation within the detail area and preserves workspace view state when the pane opens or closes. Error output is bounded inline and accessible in full through Details & Help.

`HelpContent` provides compiled, searchable offline articles with stable topic identifiers. The native Help window, menu, and contextual links use those identifiers. Content and search tests check coverage, ranking, and valid related topics; window layout and assistive-technology behavior require manual checks.

## Commit author settings

`GitIdentityEditor` captures the destination repository and preserves form drafts across scope changes and failures. Git reads and writes stay in `RepoDeckKit`; the editor coordinates saves through repository mutation state and a shared guard for default-identity writes. The form requires an explicit Save, reads back the chosen scope, and reports the effective identity when local or worktree settings override a default. Git writes the two fields separately, so a later failure can leave a partial save; the error reports that limitation and does not attempt an unsafe rollback over external edits.

The sidebar reads `git var GIT_AUTHOR_IDENT` through the same Git client environment used for ordinary new commits. Git resolves author-specific configuration, inherited environment overrides, and fallback values; RepoDeck does not reconstruct that precedence from `user.name` and `user.email`. The result is a current default, not a guarantee for operations such as cherry-pick or rebase that preserve an existing author, or against external configuration changes before a later commit. Read failures remain visible and stale author details are not presented as current.

The setup form still edits `user.name` and `user.email` at the chosen scope. It prefills only those configured defaults, never copying an inferred or overridden author into settings. Failure to resolve a commit author does not block loading valid configuration for repair. Saved settings are verified independently of author resolution, so a remaining override or invalid author has an explicit explanation. External repository refreshes reread the author. Author-identity errors open the setup form; SSH and hosting authentication errors retain their separate recovery actions.

## Repository operations

Discovery first locates ordinary checkouts and bare metadata stores, then asks Git for its NUL-delimited worktree registry. It includes linked/nested checkouts outside the scanned folder, omits missing/prunable entries and bare stores from the editable list, and deduplicates canonical paths. Each checkout and its external metadata directories are watched.

Repository context distinguishes the worktree root, per-worktree Git directory, and shared common directory. Mutations are coordinated by repository resource; visible views do not launch competing operations themselves. Read paths preserve partial/failed states instead of presenting them as an empty clean repository. Git parses paths with NUL-delimited or Git-quoted representations and commands keep path operands separate from option parsing.

`RepoViewModel.performAction` checks the worktree/Git/common directory, branch, commit, and in-progress operation metadata again after acquiring shared capacity. Confirmation dialogs retain that preview identity. Partial staging checks the displayed diff against a fresh diff and accepts only lossless UTF-8 and supported file modes. Conflict saves validate index stages, content, and mode; Save and Mark Resolved are separate actions.

Safe worktree removal checks both normal Git status and all untracked files without ignore exclusions. Ignored local configuration and build artifacts must be backed up or removed deliberately before RepoDeck removes the worktree.

These are application-level safeguards, with Git's locks protecting individual Git writes. Other Git programs do not participate in RepoDeck's coordinator and can race a final precondition check. Stash apply uses an immutable object ID; drop refreshes and verifies the matching reflog selector, but Git's public CLI has no conditional individual-reflog-entry deletion. RepoDeck does not edit reflog files or claim an atomic transaction across independent Git processes. Undo covers the recorded sync commit in its original branch/worktree; it is not a backup of arbitrary untracked files.

Application tests inject preferences, scanner, clock, watcher events, Git executables, and review loaders. Workspace state belongs to each worktree rather than a mounted SwiftUI view. Refresh generations reject obsolete responses, and successful submissions clear only the exact draft that was submitted. Hosting adapters expose provider capabilities and preserve uncertain-operation identifiers across retries.

## Subprocess ownership

`ProcessRunner` is the shared subprocess boundary. It creates an owned POSIX process group before execution and drains nonblocking stdout/stderr while writing stdin. Cancellation removes queued work or stops a running group. Timeouts remain effective when descendants hold pipes open; SIGTERM escalates to SIGKILL after 500 ms. After the command's leader exits, remaining children are cleaned up. Streaming consumers that own resources use `startStreaming` and await `waitForCompletion()` before releasing them: cancellation can end event iteration before the process group exits. The command pane keeps its repository coordinator until that cleanup completes. This is a command runner, not a daemon supervisor or terminal emulator.

The process-wide limiter permits six jobs, with background work limited to four slots and interactive waiters served first. Captured output is limited to 16 MiB combined stdout/stderr by default; callers can request a smaller budget. Streaming delivery has a separate bounded queue, preserves UTF-8 across chunk boundaries, and reports overflow explicitly. Cancellation checks occur before queueing and before spawning. Child exit status remains compatible with the prior runner: normal status or terminating signal number.

## Testing boundaries

Unit tests cover parsers and state transitions. Integration tests create disposable local repositories and bare remotes. Network hosting tests use transport fixtures; real credentials and services are covered only by explicitly performed manual smoke tests. Packaging tests check release-source invariants without publishing. CI builds the app and runs tests with a declared toolchain; local builds are still useful for native accessibility and launch checks.
