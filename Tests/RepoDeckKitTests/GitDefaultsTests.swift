import Foundation
import Testing
@testable import RepoDeckKit

@Test func gitPathIsSystemGit() {
    #expect(GitDefaults.gitPath == "/usr/bin/git")
}

@Test func gitBinaryExistsAndIsExecutable() {
    #expect(FileManager.default.isExecutableFile(atPath: GitDefaults.gitPath))
}
