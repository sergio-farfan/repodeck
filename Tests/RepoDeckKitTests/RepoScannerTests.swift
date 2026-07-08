import Foundation
import Testing
@testable import RepoDeckKit

/// Creates a fresh temp directory under `FileManager.default.temporaryDirectory` for a test run.
/// Caller is responsible for removing it (typically via `defer`).
private func makeTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RepoScannerTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Marks `dir` as a git repo by creating a `.git` directory inside it (contents are irrelevant to the scanner).
private func makeGitDir(at dir: URL) {
    try! FileManager.default.createDirectory(
        at: dir.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
}

@Test func flatReposFoundAndSorted() {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let a = root.appendingPathComponent("a", isDirectory: true)
    let b = root.appendingPathComponent("b", isDirectory: true)
    let c = root.appendingPathComponent("c", isDirectory: true)
    try! FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
    makeGitDir(at: a)
    makeGitDir(at: b)
    // c has no .git

    let results = RepoScanner().scan(root: root)

    #expect(results.map(\.name) == ["a", "b"])
}

@Test func nestedRepoIsExcluded() {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let outer = root.appendingPathComponent("outer", isDirectory: true)
    let inner = outer.appendingPathComponent("inner", isDirectory: true)
    try! FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    makeGitDir(at: outer)
    makeGitDir(at: inner)

    let results = RepoScanner().scan(root: root)

    #expect(results.map(\.name) == ["outer"])
}

@Test func prunedDirectoryDecoyIsNotFound() {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let fake = root.appendingPathComponent("node_modules", isDirectory: true)
        .appendingPathComponent("fake", isDirectory: true)
    try! FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
    makeGitDir(at: fake)

    let results = RepoScanner().scan(root: root)

    #expect(results.isEmpty)
}

@Test func hiddenDirectoryIsSkipped() {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let repo = root.appendingPathComponent(".hidden", isDirectory: true)
        .appendingPathComponent("repo", isDirectory: true)
    try! FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    makeGitDir(at: repo)

    let results = RepoScanner().scan(root: root)

    #expect(results.isEmpty)
}

@Test func gitFileWorktreeLinkIsFound() {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let wt = root.appendingPathComponent("wt", isDirectory: true)
    try! FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
    let gitFile = wt.appendingPathComponent(".git")
    try! "gitdir: /somewhere".write(to: gitFile, atomically: true, encoding: .utf8)

    let results = RepoScanner().scan(root: root)

    #expect(results.map(\.name) == ["wt"])
}

@Test func rootItselfIsARepo() {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    makeGitDir(at: root)
    // A nested repo that should never be reached because scanning stops at root.
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try! FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    makeGitDir(at: nested)

    let results = RepoScanner().scan(root: root)

    #expect(results.count == 1)
    #expect(results.first?.path == root)
}

@Test func depthLimitExcludesTooDeepRepoButIncludesExactDepth() {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // maxDepth 2: root (depth 0) -> level1 (depth 1) -> level2 (depth 2, at limit, found)
    let level1 = root.appendingPathComponent("level1", isDirectory: true)
    let level2 = level1.appendingPathComponent("level2", isDirectory: true)
    try! FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)
    makeGitDir(at: level2)

    let atLimitResults = RepoScanner(maxDepth: 2).scan(root: root)
    #expect(atLimitResults.map(\.name) == ["level2"])

    // Now push the repo one level deeper than maxDepth allows.
    let tooDeepRoot = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tooDeepRoot) }
    let deepLevel1 = tooDeepRoot.appendingPathComponent("level1", isDirectory: true)
    let deepLevel2 = deepLevel1.appendingPathComponent("level2", isDirectory: true)
    let deepLevel3 = deepLevel2.appendingPathComponent("level3", isDirectory: true)
    try! FileManager.default.createDirectory(at: deepLevel3, withIntermediateDirectories: true)
    makeGitDir(at: deepLevel3)

    let tooDeepResults = RepoScanner(maxDepth: 2).scan(root: tooDeepRoot)
    #expect(tooDeepResults.isEmpty)
}

@Test func symlinkCycleIsNotFollowed() {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let real = root.appendingPathComponent("real", isDirectory: true)
    let sub = real.appendingPathComponent("sub", isDirectory: true)
    try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    makeGitDir(at: sub)

    let link = root.appendingPathComponent("link", isDirectory: true)
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let results = RepoScanner().scan(root: root)

    #expect(results.map(\.name) == ["sub"])
}

@Test func sortIsCaseInsensitive() {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let zeta = root.appendingPathComponent("Zeta", isDirectory: true)
    let alpha = root.appendingPathComponent("alpha", isDirectory: true)
    try! FileManager.default.createDirectory(at: zeta, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    makeGitDir(at: zeta)
    makeGitDir(at: alpha)

    let results = RepoScanner().scan(root: root)

    #expect(results.map(\.name) == ["alpha", "Zeta"])
}
