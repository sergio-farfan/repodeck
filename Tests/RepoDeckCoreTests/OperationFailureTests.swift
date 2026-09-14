import Testing
import RepoDeckKit
@testable import RepoDeckCore

@Suite("Operation failure guidance")
struct OperationFailureTests {
    @Test func authorSetupAndSSHAccessHaveDifferentRecoveryActions() {
        let identity = OperationFailure(message: "Author identity unknown")
        let ssh = OperationFailure(message: "Permission denied (publickey).")
        #expect(identity.actions.first == .configureIdentity)
        #expect(ssh.kind == .authentication)
        #expect(!ssh.actions.contains(.configureIdentity))
    }
    @Test(arguments: [
        ("Author identity unknown\n*** Please tell me who you are.", OperationFailure.Kind.identity),
        ("fatal: unable to auto-detect email address (got 'local@host')", .identity),
        ("remote: Invalid username or password.\nfatal: Authentication failed", .authentication),
        ("git@example.invalid: Permission denied (publickey).", .authentication),
        ("example.invalid: HTTP 403: Resource not accessible by integration", .authentication),
        ("fatal: unable to access 'https://example.invalid/': Could not resolve host: example.invalid", .network),
        (" ! [rejected] main -> main (fetch first)\nerror: failed to push some refs", .rejectedPush),
        ("fatal: The current branch topic has no upstream branch.", .upstream),
        ("error: Your local changes to the following files would be overwritten by merge:", .localChanges),
        ("Commit or stash local changes before this operation.", .localChanges),
        ("CONFLICT (content): Merge conflict in file.swift", .conflict),
        ("Rebase in progress. Resolve, continue, or abort that operation first.", .conflict),
        ("fatal: Unable to create '/example/.git/index.lock': File exists.", .locked),
        ("The configured application is unavailable. Choose an installed application in Settings.", .toolUnavailable),
        ("Git must point to an executable file using an absolute path.", .toolUnavailable),
        ("Install gh, then sign in to example.invalid and reconnect.", .toolUnavailable),
        ("Install glab, then sign in to example.invalid and reconnect.", .toolUnavailable),
        ("The operation couldn’t be completed. No such file or directory", .pathUnavailable),
        ("fatal: not a git repository (or any of the parent directories): .git", .pathUnavailable),
        ("error: insufficient permission for adding an object to repository database .git/objects\nPermission denied", .permissions),
        ("This diff contains text outside UTF-8. Use the whole-file action to preserve its original bytes.", .partialFile),
        ("The selected stash changed or is no longer available. Refresh the stash list and try again.", .staleState),
        ("repository has moved on since the snapshot", .staleState),
        ("The conflict changed on disk. Reload it before saving or marking it resolved.", .staleConflict),
        ("The selected conflict changed. Reload it before marking it resolved.", .staleConflict),
        ("This file is no longer an unresolved conflict. Review the refreshed changes before staging it.", .staleConflict),
        ("Binary or non-UTF-8 conflicts must be resolved in another tool.", .unsupportedConflict),
    ])
    func recognizesActionableDiagnostics(message: String, expected: OperationFailure.Kind) {
        #expect(OperationFailure(message: message).kind == expected)
    }

    @Test func fullDiagnosticSurvivesWhileSummaryRemainsBounded() {
        let output = String(repeating: "a very long unexpected diagnostic\n", count: 10_000)
        let command = "git -C /example/" + String(repeating: "long repository path ", count: 1_000) + " log --all"
        let failure = OperationFailure(GitError(command: command, exitCode: 128, stderr: output))
        #expect(failure.kind == .unknown)
        #expect(failure.details.hasPrefix(command + "\nExit code: 128\n\n"))
        #expect(failure.operation == command)
        #expect(failure.details.hasSuffix(output))
        #expect(failure.message.count < 300)
        #expect(!failure.message.contains(output))
    }

    @Test func emptyDiagnosticStillIdentifiesActualFailedCommand() {
        let failure = OperationFailure(GitError(command: "git log", exitCode: 1, stderr: ""))
        #expect(failure.details.contains("git log\nExit code: 1"))
        #expect(failure.details.contains("No diagnostic output"))
        #expect(!failure.title.lowercased().contains("commit failed"))
    }

    @Test func staleConflictNeverOffersRefreshThatCouldReplaceItsDraft() {
        let failure = OperationFailure(message: "The conflict changed on disk. Reload it before saving or marking it resolved.")
        #expect(failure.actions == [.showConflicts, .help])
        #expect(failure.message.contains("copy of your resolution draft"))
        #expect(failure.message.contains("Reload only when ready"))
    }

    @Test func uncertainResponseKeepsReconciliationInstructionsAboveTimeoutDetails() {
        let failure = OperationFailure(message: "The server outcome could not be confirmed. example.invalid timed out. Refresh before retrying; keep the same operation identifier.")
        #expect(failure.kind == .uncertainOutcome)
        #expect(failure.message.contains("operation identifier"))
        #expect(failure.message.contains("existing result"))
        #expect(!failure.actions.contains(.refresh))
    }

    @Test func timeoutTakesPrecedenceOverCapturedChildOutput() {
        let failure = OperationFailure(message: "timed out after 45s\nfatal: Authentication failed")
        #expect(failure.kind == .timedOut)
        #expect(failure.message.contains("does not prove"))
        #expect(failure.message.contains("server"))
    }

    @Test(arguments: [
        "fatal: pathspec 'conflict.txt' did not match any files",
        "fatal: could not open 'index.lock': No such file or directory",
        "fatal: repository '/tmp/authentication' does not exist",
        "error: failed to push some refs to 'example.invalid'",
        "remote: policy rejected this push",
        "error: pathspec 'whole-file' did not match any files",
        "fatal: pathspec 'Author identity unknown' did not match any files",
    ])
    func ambiguousDiagnosticsDoNotInventSpecificRemedies(message: String) {
        #expect(OperationFailure(message: message).kind == .unknown)
    }

    @Test func filenamesInCommandDoNotChangeGuidance() {
        let failure = OperationFailure(GitError(command: "git add -- 'Author identity unknown'", exitCode: 1,
                                               stderr: "Something unexpected happened."))
        #expect(failure.kind == .unknown)
    }

    @Test func authAndNetworkGuidanceRequireCheckingRemoteOutcomeBeforeResubmission() {
        for diagnostic in ["fatal: Authentication failed", "fatal: Could not resolve host: example.invalid"] {
            let failure = OperationFailure(message: diagnostic)
            #expect(failure.message.contains("server"))
            #expect(failure.message.contains("already"))
        }
    }
}
