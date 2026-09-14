import Foundation
import Testing
@testable import RepoDeckKit

@Suite struct GitClientSafetyTests {
    @discardableResult
    private func git(_ arguments: [String], in repo: URL) async throws -> ProcessResult {
        let result = try await TestGitRepository.run(arguments: ["-C", repo.path] + arguments)
        try #require(result.exitCode == 0, "git \(arguments) failed: \(result.stderr)")
        return result
    }

    private func withRepo(_ body: (URL, GitClient) async throws -> Void) async throws {
        try await TestGitRepository.withRepository(body)
    }

    private func write(_ text: String, _ path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func selectedPathsAreLiteralForStageUnstageAndDiff() async throws {
        try await withRepo { repo, client in
            let paths = ["literal[1].txt", "literal1.txt", ":(glob)*.txt", "other.txt"]
            for path in paths { try write("old\n", path, in: repo) }
            try await client.stageAll(in: repo)
            try await client.commit(message: "base", in: repo)
            for path in paths { try write("new\n", path, in: repo) }
            for selected in [paths[0], paths[2]] {
                let diff = try #require(try await client.diff(path: selected, staged: false, in: repo))
                #expect(diff.displayPath == selected)
                try await client.stage([selected], in: repo)
                let staged = try await client.status(in: repo).changes.filter { $0.area == .staged }
                #expect(staged.map(\.path) == [selected])
                try await client.unstage([selected], in: repo)
                #expect(try await client.status(in: repo).changes.allSatisfy { $0.area != .staged })
            }
            try await client.stageAll(in: repo)
            try await client.unstage([paths[0]], in: repo)
            let remaining = Set(try await client.status(in: repo).changes.filter { $0.area == .staged }.map(\.path))
            #expect(remaining == Set(paths.dropFirst()))
        }
    }

    @Test func unusualPathsRoundTripThroughHunkStageAndUnstage() async throws {
        try await withRepo { repo, client in
            let paths = ["space name.txt", "tab\tname.txt", "line\nname.txt", "quote\"name.txt", "back\\name.txt", "café\tname.txt", "a b/inside.txt"]
            for path in paths { try write("old\n", path, in: repo) }
            try await client.stageAll(in: repo)
            try await client.commit(message: "base", in: repo)
            for path in paths {
                try write("new\n", path, in: repo)
                let diff = try #require(try await client.diff(path: path, staged: false, in: repo))
                #expect(diff.displayPath == path)
                let hunk = try #require(diff.hunks.first)
                try await client.applyPatch(PatchBuilder.checkedPatch(for: hunk, in: diff, reverse: false), cached: true, reverse: false, in: repo)
                #expect(try await git(["show", ":" + path], in: repo).stdout == Data("new\n".utf8))
                let staged = try #require(try await client.diff(path: path, staged: true, in: repo))
                try await client.applyPatch(PatchBuilder.checkedPatch(for: staged.hunks[0], in: staged, reverse: true), cached: true, reverse: false, in: repo)
                #expect(try await git(["show", ":" + path], in: repo).stdout == Data("old\n".utf8))
            }
        }
    }

    @Test func latin1AdditionIsPreviewableButCannotCreateAnIndexPatch() async throws {
        try await withRepo { repo, client in
            let latin = Data([0x63, 0x61, 0x66, 0xe9, 0x0a])
            let original = latin + Data(String(repeating: "plain\n", count: 10).utf8)
            let path = repo.appendingPathComponent("latin1.txt")
            try original.write(to: path)
            try await client.stageAll(in: repo)
            try await client.commit(message: "base", in: repo)
            try (original + latin).write(to: path)
            let diff = try #require(try await client.diff(path: "latin1.txt", staged: false, in: repo))
            let hunk = try #require(diff.hunks.first)
            #expect(!diff.isLosslessUTF8)
            #expect(!diff.canApplyHunks)
            #expect(throws: GitError.self) { try PatchBuilder.checkedPatch(for: hunk, in: diff, reverse: false) }
            #expect(PatchBuilder.patch(for: hunk, in: diff, reverse: false).isEmpty)
            #expect(try await git(["show", ":latin1.txt"], in: repo).stdout == original)
            try await client.stage(["latin1.txt"], in: repo)
            #expect(try await git(["show", ":latin1.txt"], in: repo).stdout == original + latin)
        }
    }

    @Test func textconvAndForcedColorDoNotChangeStageableDiffs() async throws {
        try await withRepo { repo, client in
            try write("unchanged\n", "data.txt", in: repo)
            try write("data.txt diff=review\n", ".gitattributes", in: repo)
            try await client.stageAll(in: repo)
            try await client.commit(message: "base", in: repo)
            try await git(["config", "diff.review.textconv", "sed s/RAW:/CONVERTED:/g"], in: repo)
            try await git(["config", "color.ui", "always"], in: repo)
            try await git(["config", "color.diff", "always"], in: repo)
            try write("unchanged\nRAW:value\n", "data.txt", in: repo)
            let diff = try #require(try await client.diff(path: "data.txt", staged: false, in: repo))
            let patch = try PatchBuilder.checkedPatch(for: diff.hunks[0], in: diff, reverse: false)
            #expect(patch.contains("+RAW:value\n"))
            #expect(!patch.contains("CONVERTED:"))
            try await client.applyPatch(patch, cached: true, reverse: false, in: repo)
            #expect(try await git(["show", ":data.txt"], in: repo).stdout == Data("unchanged\nRAW:value\n".utf8))
            #expect(!(try await client.diffCommit("HEAD", in: repo)).isEmpty)
            try write("new\n", "new.txt", in: repo)
            #expect(try await client.diffUntracked(path: "new.txt", in: repo)?.hunks.count == 1)
        }
    }

    @Test func unstageExecutableDeletionPreservesModeAndSymlinksRequireWholeFileAction() async throws {
        try await withRepo { repo, client in
            try write("#!/bin/sh\necho hello\n", "script.sh", in: repo)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.appendingPathComponent("script.sh").path)
            try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("link").path, withDestinationPath: "target")
            try await client.stageAll(in: repo)
            try await client.commit(message: "base", in: repo)
            for path in ["script.sh", "link"] {
                try FileManager.default.removeItem(at: repo.appendingPathComponent(path))
                try await client.stage([path], in: repo)
            }
            let executable = try #require(try await client.diff(path: "script.sh", staged: true, in: repo))
            #expect(executable.oldMode == "100755")
            try await client.applyPatch(PatchBuilder.checkedPatch(for: executable.hunks[0], in: executable, reverse: true), cached: true, reverse: false, in: repo)
            #expect(try await git(["diff", "--cached", "--raw", "--", "script.sh"], in: repo).stdout.isEmpty)
            let symlink = try #require(try await client.diff(path: "link", staged: true, in: repo))
            #expect(symlink.oldMode == "120000")
            #expect(!symlink.canApplyHunks)
            #expect(throws: GitError.self) { try PatchBuilder.checkedPatch(for: symlink.hunks[0], in: symlink, reverse: true) }
            try await client.unstage(["link"], in: repo)
            let restored = String(decoding: try await git(["ls-files", "-s", "--", "link"], in: repo).stdout, as: UTF8.self)
            #expect(restored.hasPrefix("120000 "))
        }
    }

    @Test func unstageRenameRestoresBothIndexPaths() async throws {
        try await withRepo { repo, client in
            try write("base\n", "old.txt", in: repo)
            try await client.stageAll(in: repo)
            try await client.commit(message: "base", in: repo)
            try await git(["mv", "old.txt", "new.txt"], in: repo)
            let rename = try #require(try await client.status(in: repo).changes.first { $0.statusLetter == "R" })
            try await client.unstage(rename, in: repo)
            #expect(try await client.status(in: repo).changes.allSatisfy { $0.area != .staged })
            #expect(try Data(contentsOf: repo.appendingPathComponent("new.txt")) == Data("base\n".utf8))
        }
    }

    @Test func unbornRepositoryCanUnstageWithoutRemovingWorktreeFiles() async throws {
        try await withRepo { repo, client in
            try write("new\n", "first[1].txt", in: repo)
            try await client.stage(["first[1].txt"], in: repo)
            try await client.unstage(["first[1].txt"], in: repo)
            let status = try await client.status(in: repo)
            #expect(status.changes.count == 1)
            #expect(status.changes[0].area == .untracked)
            #expect(try Data(contentsOf: repo.appendingPathComponent("first[1].txt")) == Data("new\n".utf8))
        }
    }

    @Test func unbornUnstageKeepsLaterEditsAndOtherStagedPaths() async throws {
        try await withRepo { repo, client in
            let selected = "selected[1].txt"
            let other = "selected1.txt"
            try write("staged\n", selected, in: repo)
            try write("other\n", other, in: repo)
            try await client.stage([selected, other], in: repo)
            let latest = Data("later edit\r\n".utf8) + Data([0xff, 0x00])
            try latest.write(to: repo.appendingPathComponent(selected))

            try await client.unstage([selected], in: repo)

            #expect(try Data(contentsOf: repo.appendingPathComponent(selected)) == latest)
            #expect(try Data(contentsOf: repo.appendingPathComponent(other)) == Data("other\n".utf8))
            #expect(try await git(["ls-files", "-z"], in: repo).stdout == Data((other + "\0").utf8))
            #expect(try await git(["show", ":" + other], in: repo).stdout == Data("other\n".utf8))
        }
    }

    @Test func tinyStatusCapCanReturnNoChangesButMustReportTruncation() async throws {
        try await withRepo { repo, _ in
            try write("new\n", "new.txt", in: repo)
            var client = GitClient()
            client.statusOutputLimit = 16
            let status = try await client.status(in: repo)
            #expect(status.didHitLimit)
            #expect(status.changes.isEmpty)
        }
        let completeRecord = PorcelainParser.parse(Data("? file.txt\0".utf8), truncated: true)
        #expect(completeRecord.changes.map(\.path) == ["file.txt"])
        #expect(PorcelainParser.parse(Data(), truncated: true).didHitLimit)
    }
}
