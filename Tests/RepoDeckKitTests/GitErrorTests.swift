import Testing
@testable import RepoDeckKit

/// Unit tests for `GitError.isNonFastForwardPushRejection` against canned
/// stderr in git's `LC_ALL=C` (untranslated) form — the only form the app
/// ever sees, because `ProcessRunner` forces `LC_ALL=C` on every child.
@Suite struct GitErrorTests {
    private func pushError(stderr: String) -> GitError {
        GitError(command: "git -C /tmp/repo push", exitCode: 1, stderr: stderr)
    }

    @Test func fetchFirstRejectionIsClassified() {
        let stderr = """
        To /tmp/remote.git
         ! [rejected]        main -> main (fetch first)
        error: failed to push some refs to '/tmp/remote.git'
        hint: Updates were rejected because the remote contains work that you do not
        hint: have locally.
        """
        #expect(pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func nonFastForwardRejectionIsClassified() {
        let stderr = """
        To /tmp/remote.git
         ! [rejected]        main -> main (non-fast-forward)
        error: failed to push some refs to '/tmp/remote.git'
        """
        #expect(pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func authFailureIsNotClassified() {
        let stderr = "fatal: could not read Username for 'https://example.com': terminal prompts disabled"
        #expect(!pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func missingUpstreamIsNotClassified() {
        let stderr = """
        fatal: The current branch main has no upstream branch.
        To push the current branch and set the remote as upstream, use

            git push --set-upstream origin main
        """
        #expect(!pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func staleInfoForceWithLeaseIsNotClassified() {
        let stderr = """
        To /tmp/remote.git
         ! [rejected]        main -> main (stale info)
        error: failed to push some refs to '/tmp/remote.git'
        """
        #expect(!pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func emptyStderrIsNotClassified() {
        #expect(!pushError(stderr: "").isNonFastForwardPushRejection)
    }
}
