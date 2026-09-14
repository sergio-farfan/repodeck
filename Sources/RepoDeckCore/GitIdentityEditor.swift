import Foundation
import Observation
import RepoDeckKit

/// Edits one explicitly selected configuration scope for an immutable repository.
@MainActor @Observable
public final class GitIdentityEditor {
    public let repo: RepoViewModel
    public var name = "" {
        didSet {
            editRevision += 1
            if !isSaving { notice = nil }
        }
    }
    public var email = "" {
        didSet {
            editRevision += 1
            if !isSaving { notice = nil }
        }
    }
    public private(set) var scope: GitIdentityScope = .repository
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var error: String?
    public private(set) var notice: String?
    public private(set) var hasLoaded = false
    public private(set) var effectiveIdentity: GitIdentity?
    public private(set) var effectiveIdentityError: String?

    public var canSave: Bool {
        hasLoaded && !isLoading && !isSaving && !repo.isBusy && !repo.isRunningCommand
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (name.trimmingCharacters(in: .whitespacesAndNewlines) != baseline?.name
                || email.trimmingCharacters(in: .whitespacesAndNewlines) != baseline?.email)
    }

    @ObservationIgnored private let io: GitIdentityEditorIO
    @ObservationIgnored private var editRevision = 0
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var drafts: [GitIdentityScope: Draft] = [:]
    @ObservationIgnored private var baseline: GitIdentity?
    @ObservationIgnored private var expectedIdentity: RepositoryOperationIdentity?
    @ObservationIgnored private var loadedGitPath: String?

    private struct Draft {
        let name: String
        let email: String
        let baseline: GitIdentity?
    }

    public convenience init(repo: RepoViewModel) {
        self.init(repo: repo, io: .live)
    }

    init(repo: RepoViewModel, io: GitIdentityEditorIO) {
        self.repo = repo
        self.io = io
    }

    /// Switching scope does not repurpose the other scope's draft or an in-flight save.
    public func selectScope(_ selected: GitIdentityScope) async {
        guard !isSaving, selected != scope else { return }
        drafts[scope] = Draft(name: name, email: email, baseline: baseline)
        loadGeneration += 1
        scope = selected
        let saved = drafts[selected]
        name = saved?.name ?? ""
        email = saved?.email ?? ""
        baseline = saved?.baseline
        hasLoaded = false
        expectedIdentity = nil
        loadedGitPath = nil
        effectiveIdentity = nil
        effectiveIdentityError = nil
        notice = nil
        await load()
    }

    /// Reads scope and effective values independently. A failed read is never an empty identity.
    public func load() async {
        guard !isSaving else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let selected = scope
        let gitPath = repo.client.gitPath
        let client = GitClient(gitPath: gitPath)
        let revision = editRevision
        let draftWasEdited = name != (baseline?.name ?? "") || email != (baseline?.email ?? "")
        isLoading = true
        hasLoaded = false
        error = nil
        notice = nil
        effectiveIdentity = nil
        effectiveIdentityError = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let context = try await RepositoryContext.resolve(in: repo.repo.path, gitPath: gitPath)
            let status = try await client.status(in: repo.repo.path)
            let expected = RepositoryOperationIdentity(context: context, branch: status.branch, oid: status.oid,
                operationFiles: RepositoryOperationState.fingerprint(in: context))
            let configured = try await io.readScope(client, selected, repo.repo.path)
            // Prefill editable user.* settings from their defaults, never from
            // an author override or a name/email Git inferred from the machine.
            let defaults = selected == .repository ? try await io.readDefaults(client, repo.repo.path) : configured
            let author = try await readAuthor(using: client)
            try Task.checkCancellation()
            guard generation == loadGeneration, selected == scope else { return }
            guard gitPath == repo.client.gitPath else { throw Self.failure("The Git executable changed. Reload commit author settings before saving.") }
            if revision == editRevision, !draftWasEdited {
                name = configured.name ?? defaults.name ?? ""
                email = configured.email ?? defaults.email ?? ""
            }
            baseline = configured
            effectiveIdentity = author.identity
            effectiveIdentityError = author.error
            expectedIdentity = expected
            loadedGitPath = gitPath
            hasLoaded = true
        } catch {
            guard generation == loadGeneration, selected == scope else { return }
            self.error = error is CancellationError ? "Loading commit author settings was cancelled. Reload before saving." : error.localizedDescription
        }
    }

    /// A successful result means both fields were written and read back at the chosen scope.
    /// The effective identity may still differ because Git has another overriding configuration.
    @discardableResult
    public func save() async -> Bool {
        guard !isSaving else { return false }
        guard hasLoaded, !isLoading, let expectedIdentity, let loadedGitPath, let baseline else {
            error = "Load commit author settings successfully before saving."
            return false
        }
        let submittedName = name
        let submittedEmail = email
        let value = GitIdentity(name: submittedName.trimmingCharacters(in: .whitespacesAndNewlines),
                                email: submittedEmail.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let nameValue = value.name, !nameValue.isEmpty, let emailValue = value.email, !emailValue.isEmpty else {
            error = "Enter both an author name and an email address."
            return false
        }
        guard loadedGitPath == repo.client.gitPath else {
            hasLoaded = false
            error = "The Git executable changed. Reload commit author settings before saving."
            return false
        }
        let selected = scope
        let client = GitClient(gitPath: loadedGitPath)
        isSaving = true
        error = nil
        notice = nil
        defer { isSaving = false }
        var acquiredGlobal = false
        var verifiedEffective: GitIdentity?
        var verifiedAuthorError: String?
        let result: OperationResult
        do {
            // Every identity editor takes the global key before a repository key;
            // no operation takes these keys in the reverse order.
            if selected == .globalDefault {
                try await RepositoryMutationCoordinator.shared.acquire("global-git-identity")
                acquiredGlobal = true
            }
            try Task.checkCancellation()
            result = await repo.performAction(allowInProgress: true, expectedIdentity: expectedIdentity) {
                guard self.repo.client.gitPath == loadedGitPath else {
                    throw Self.failure("The Git executable changed. Reload commit author settings before saving.")
                }
                let before = try await self.io.readScope(client, selected, self.repo.repo.path)
                guard before == baseline else {
                    throw Self.failure("The commit author settings changed since this form was loaded. Reload settings and review your draft before saving.")
                }
                guard self.repo.client.gitPath == loadedGitPath else {
                    throw Self.failure("The Git executable changed. Reload commit author settings before saving.")
                }
                try await self.io.write(client, submittedName, submittedEmail, selected, self.repo.repo.path)
                do {
                    let actual = try await self.io.readScope(client, selected, self.repo.repo.path)
                    guard actual == value else {
                        throw Self.failure("The saved commit author defaults did not match the selected scope when read back.")
                    }
                    let author = try await self.readAuthor(using: client)
                    verifiedEffective = author.identity
                    verifiedAuthorError = author.error
                } catch {
                    throw Self.failure("Commit author settings may have been saved, but verification failed. Inspect the current settings before saving again.\n\n\(error.localizedDescription)")
                }
            }
        } catch {
            result = .failed(error is CancellationError ? "Saving commit author settings was cancelled. Inspect the current settings before trying again." : error.localizedDescription)
        }
        if acquiredGlobal { await RepositoryMutationCoordinator.shared.release("global-git-identity") }
        // Refresh even after a partially completed write or a failed verification.
        if result != .succeeded {
            self.baseline = try? await io.readScope(client, selected, repo.repo.path)
            let author = try? await readAuthor(using: client)
            effectiveIdentity = author?.identity
            effectiveIdentityError = author?.error
            hasLoaded = false
        }
        await repo.refreshIdentity()
        switch result {
        case .succeeded:
            self.baseline = value
            effectiveIdentity = verifiedEffective
            effectiveIdentityError = verifiedAuthorError
            if name == submittedName { name = nameValue }
            if email == submittedEmail { email = emailValue }
            notice = selected == .repository ? "Saved the commit author defaults for this repository." : "Saved your Git commit author defaults."
            if verifiedAuthorError != nil {
                notice? += " Git still cannot resolve the author for new commits. Review the explanation below before committing."
            } else if verifiedEffective != value {
                notice? += " Git resolves a different author for this repository. Another Git setting or environment value can override these values, and Git may normalize author text. Review the author below."
            }
            if name != nameValue || email != emailValue {
                notice? += " Your newer edits are still in the form and have not been saved."
            }
            return true
        case .failed(let reason):
            error = reason + "\nReload commit author settings before saving again. Your draft is retained."
            return false
        case .skipped(let reason):
            error = "Commit author settings were not saved: \(reason). Reload commit author settings before saving again. Your draft is retained."
            return false
        }
    }

    /// Author resolution is independent of editable configuration. An unset or
    /// invalid author must not prevent the user from opening the repair form.
    private func readAuthor(using client: GitClient) async throws -> (identity: GitIdentity?, error: String?) {
        do {
            return (try await io.readEffective(client, repo.repo.path), nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private static func failure(_ message: String) -> GitError {
        GitError(command: "Commit author settings", exitCode: -1, stderr: message)
    }
}

/// The live path always goes through RepoViewModel's repository mutation coordinator.
struct GitIdentityEditorIO: Sendable {
    var readScope: @Sendable (GitClient, GitIdentityScope, URL) async throws -> GitIdentity
    var readDefaults: @Sendable (GitClient, URL) async throws -> GitIdentity
    var readEffective: @Sendable (GitClient, URL) async throws -> GitIdentity
    var write: @Sendable (GitClient, String, String, GitIdentityScope, URL) async throws -> Void

    static let live = GitIdentityEditorIO(
        readScope: { try await $0.configuredIdentity(in: $2, scope: $1) },
        readDefaults: { try await $0.configuredIdentity(in: $1) },
        readEffective: { try await $0.effectiveCommitAuthor(in: $1) },
        write: { try await $0.setConfiguredIdentity(name: $1, email: $2, scope: $3, in: $4) }
    )
}
