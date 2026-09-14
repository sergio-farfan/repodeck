import Foundation
import RepoDeckKit

/// Navigation and inspection only. Recovery never retries a write or changes Git state.
public enum FailureRecoveryAction: String, CaseIterable, Sendable {
    case showChanges, showConflicts, showBranches, configureIdentity, openSettings, openTerminal, refresh, help

    public var label: String {
        switch self {
        case .showChanges: "Show Changes"
        case .showConflicts: "Show Conflicts"
        case .showBranches: "Show Branches"
        case .configureIdentity: "Configure Commit Author"
        case .openSettings: "Open Settings"
        case .openTerminal: "Open Terminal"
        case .refresh: "Refresh Status"
        case .help: "Open Help"
        }
    }
}

/// A bounded explanation above the original diagnostic. Matching provides guidance,
/// not proof of repository state; callers must still validate every later operation.
public struct OperationFailure: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case identity, authentication, network, rejectedPush, upstream, localChanges
        case conflict, staleConflict, staleState, partialFile, locked, timedOut
        case uncertainOutcome, toolUnavailable, pathUnavailable, permissions, unsupportedConflict, unknown
    }

    public let kind: Kind
    public let operation: String
    public let title: String
    public let message: String
    public let details: String
    public let actions: [FailureRecoveryAction]

    public init(_ error: GitError) {
        self.init(message: error.stderr, command: error.command, exitCode: error.exitCode)
    }

    public init(message: String, command: String = "Repository operation") {
        self.init(message: message, command: command, exitCode: nil)
    }

    private init(message: String, command: String, exitCode: Int32?) {
        operation = command
        let code = exitCode.map { "\nExit code: \($0)" } ?? ""
        details = command + code + "\n\n" + (message.isEmpty ? "No diagnostic output was provided." : message)
        // The compact UI never incorporates arbitrary command output. Preserve it
        // in details, including localized/unknown messages that cannot be classified.
        // Large subprocess output must not make every SwiftUI redraw scan
        // megabytes repeatedly. Unrecognized output still has full details.
        let diagnostic = String(message.prefix(16_384)).lowercased()
        func contains(_ phrases: String...) -> Bool {
            phrases.contains { diagnostic.contains($0) }
        }

        if contains("the server outcome could not be confirmed") {
            kind = .uncertainOutcome
        } else if contains("the conflict changed on disk", "this conflict changed on disk",
                           "the selected conflict changed", "this file is no longer conflicted",
                           "this file is no longer an unresolved conflict") {
            kind = .staleConflict
        } else if contains("conflicts must be resolved in another tool", "resolve it in another tool",
                           "this conflict cannot be edited here", "this conflict is too large to edit here") {
            kind = .unsupportedConflict
        } else if diagnostic.split(separator: "\n").contains(where: {
            ["author identity unknown", "committer identity unknown"].contains($0.trimmingCharacters(in: .whitespaces))
        }) || contains("unable to auto-detect email address",
                           "please tell me who you are", "no name was given and auto-detection is disabled",
                           "no email was given and auto-detection is disabled") {
            kind = .identity
        } else if contains("timed out", "operation timedout") {
            kind = .timedOut
        } else if contains("authentication failed", "bad credentials", "permission denied (publickey",
                           "could not read username for", "could not read password for", "http 401",
                           "http 403", "authentication token", "not logged into any", "gh auth login",
                           "glab auth login", "hosting account changed or signed out") {
            kind = .authentication
        } else if contains("could not resolve host:", "could not resolve hostname", "failed to connect to",
                           "network is unreachable", "connection refused", "connection reset by peer",
                           "the internet connection appears to be offline", "ssl certificate problem:") {
            kind = .network
        } else if diagnostic.contains("[rejected]") && contains("non-fast-forward", "fetch first") {
            kind = .rejectedPush
        } else if contains("has no upstream branch", "there is no tracking information for the current branch",
                           "no configured push destination") {
            kind = .upstream
        } else if contains("your local changes to the following files would be overwritten",
                           "untracked working tree files would be overwritten", "commit or stash local changes",
                           "cannot pull with rebase: you have unstaged changes", "your index contains uncommitted changes") {
            kind = .localChanges
        } else if contains("resolve, continue, or abort that operation first", "continue or abort that operation first",
                           "continue or abort this git operation from your terminal", "you have unmerged files",
                           "resolve and stage every conflicted file", "conflict markers remain in this file",
                           "automatic merge failed", "fix conflicts and then commit the result",
                           "you need to resolve your current index first", "merging is not possible because you have unmerged files")
                    || diagnostic.split(separator: "\n").contains(where: { $0.hasPrefix("conflict (") }) {
            kind = .conflict
        } else if contains("whole-file action", "missing new file mode", "missing old file mode", "diff too large to display") {
            kind = .partialFile
        } else if contains("repository has moved on since the snapshot", "the repository or current branch changed",
                           "this diff changed on disk", "the selected stash changed or is no longer available",
                           "this branch changed since it was selected", "this worktree changed",
                           "the review's head commit changed", "the git remote changed", "the selected remote changed",
                           "the destination changed. preview the action again") {
            kind = .staleState
        } else if contains("another git process seems to be running")
                    || (contains("unable to create") && contains(".lock'") && contains("file exists")) {
            kind = .locked
        } else if contains("the configured application is unavailable", "choose an installed macos application",
                           "must point to an executable file using an absolute path", "choose a git executable",
                           "macos could not find an application", "invalid active developer path",
                           "xcrun: error:")
                    || diagnostic.hasPrefix("install gh, then sign in")
                    || diagnostic.hasPrefix("install glab, then sign in")
                    || (contains("command not found", "executable not found") && contains("git", "gh", "glab")) {
            kind = .toolUnavailable
        } else if contains("the file or folder no longer exists", "not a git repository (or any of the parent directories)")
                    || (contains("the operation couldn’t be completed.", "the operation couldn't be completed.")
                        && contains("no such file or directory")) {
            kind = .pathUnavailable
        } else if contains("permission denied", "read-only file system") {
            kind = .permissions
        } else {
            kind = .unknown
        }

        switch kind {
        case .identity:
            title = "Git needs a commit author"
            self.message = "Configure your default author name and email, then check the author Git will use before reviewing your staged changes and committing again. SSH keys and your hosting account provide access separately."
            actions = [.configureIdentity, .openTerminal, .help]
        case .authentication:
            title = "Check your account and access"
            self.message = "Check the destination host, active account, credentials, and repository permissions in Terminal. For reviews, reconnect afterward. Before repeating a submission, check whether it already reached the server."
            actions = [.openTerminal, .openSettings, .help]
        case .network:
            title = "The remote could not be reached"
            self.message = "Check your connection, VPN, remote address, and certificate configuration. Before repeating a push or review submission, inspect the server to check whether it already succeeded."
            actions = [.openTerminal, .help]
        case .rejectedPush:
            title = "The remote branch has other commits"
            self.message = "Inspect your changes and the remote history, then choose how to integrate the remote commits before pushing again. A force push can overwrite someone else's work."
            actions = [.showBranches, .showChanges, .help]
        case .upstream:
            title = "Choose a tracking branch"
            self.message = "Open Branches to inspect the current branch and set its upstream. Confirm the intended remote and branch before pulling or pushing."
            actions = [.showBranches, .help]
        case .localChanges:
            title = "Local changes need attention"
            self.message = "Review your staged, unstaged, and untracked files. Commit or stash the work you want to keep before trying this operation again."
            actions = [.showChanges, .help]
        case .conflict:
            title = "Finish the operation in progress"
            self.message = "Open Conflicts to review the current operation. Save each resolution, mark the files resolved, and Continue when ready. Review the consequences before choosing Abort."
            actions = [.showConflicts, .openTerminal, .help]
        case .staleConflict:
            title = "The conflict changed outside this editor"
            self.message = "Keep a copy of your resolution draft. In Conflicts, compare the current file and use Reload only when ready to replace the draft. Review the new content before saving or marking it resolved."
            actions = [.showConflicts, .help]
        case .staleState:
            title = "The reviewed repository state changed"
            self.message = "Refresh the current state, then select and review the item again. An older selection or undo snapshot must not be applied to a different branch, commit, or worktree."
            actions = [.refresh, .help]
        case .partialFile:
            title = "Use a whole-file operation"
            self.message = "RepoDeck cannot safely apply this partial diff. Review the complete file and use Stage or Unstage for the whole file in Changes, or inspect it in an external tool."
            actions = [.showChanges, .openTerminal, .help]
        case .locked:
            title = "Another Git operation may be running"
            self.message = "Wait for other Git tools to finish, then refresh the status. If a lock remains, inspect it in Terminal and confirm no Git process is using it before taking further action."
            actions = [.refresh, .openTerminal, .help]
        case .timedOut:
            title = "The operation timed out"
            self.message = "Inspect the repository and, for a remote action, the server before repeating it. A timeout does not prove that an operation was rolled back or that the server rejected it."
            actions = [.refresh, .openTerminal, .help]
        case .uncertainOutcome:
            title = "The server outcome is not yet known"
            self.message = "Refresh Reviews and inspect the server for the existing result. Keep the current draft and operation identifier so RepoDeck can reconcile the earlier submission before a retry."
            actions = [.help, .openTerminal]
        case .toolUnavailable:
            title = "Check the configured tool"
            self.message = "Open Settings and select an installed Git or hosting executable, editor, or terminal. Check repository overrides too. If macOS developer tools are missing, install or repair them first."
            actions = [.openSettings, .help]
        case .pathUnavailable:
            title = "A required path is unavailable"
            self.message = "Check that the repository folder still exists and its volume is connected. Also verify the configured executable in Settings. If the repository moved, add its new folder to RepoDeck."
            actions = [.openSettings, .help]
        case .permissions:
            title = "Access was denied"
            self.message = "Check the path in Details and verify your access to the file, folder, or remote. For local files, inspect macOS permissions and whether the volume is read-only."
            actions = [.openTerminal, .help]
        case .unsupportedConflict:
            title = "Resolve this conflict in another tool"
            self.message = "Use your editor or Terminal to resolve this file while preserving its encoding and file type. Return to Conflicts and reload the current file before marking it resolved."
            actions = [.showConflicts, .openTerminal, .help]
        case .unknown:
            title = "The operation needs attention"
            self.message = "Read Details for the failed operation and its diagnostic output. Inspect the current repository state before trying again; a failure does not necessarily undo earlier steps."
            actions = [.refresh, .openTerminal, .help]
        }
    }
}
