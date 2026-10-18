//
//  StatusHistoryTests.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Testing
@testable import Swift_Git

@Test(arguments: GitHashAlgorithm.allCases)
func stagingAndCommitsUseLocalGitData(algorithm: GitHashAlgorithm) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var repository = try await GitRepository.create(at: root, algorithm: algorithm)
    let author = try GitAuthor(name: "Phineas Guo", email: "test@example.com")
    #expect(try await repository.log().isEmpty)
    #expect(try await repository.status().files.isEmpty)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: false)
    let file = root.appendingPathComponent("Sources/file.swift")
    try Data("first\n".utf8).write(to: file)
    #expect(try await repository.status().files.first?.unstaged == .untracked)
    try await repository.stage(paths: ["Sources/file.swift"])
    try Data("second\n".utf8).write(to: file)
    let status = try await repository.status()
    #expect(status.files.first?.staged == .added)
    #expect(status.files.first?.unstaged == .modified)
    #expect(try await repository.comparison(path: "Sources/file.swift", staged: true).after == Data("first\n".utf8))
    let first = try await repository.commit(message: "Initial commit", author: author)
    repository = try await GitRepository.open(at: root)
    #expect(try await repository.log().map(\.id) == [first])
    #expect(try await repository.status().files.first?.staged == nil)
    #expect(try await repository.status().files.first?.unstaged == .modified)
    try await repository.stage(paths: ["Sources/file.swift"])
    try await repository.unstage(paths: ["Sources/file.swift"])
    #expect(try await repository.comparison(path: "Sources/file.swift", staged: false).before == Data("first\n".utf8))
    try await repository.stage(paths: ["Sources/file.swift"])
    let second = try await repository.commit(message: "Update\n\nMore details", author: author)
    #expect(try await repository.status().files.isEmpty)
    #expect(try await repository.log().map(\.id) == [second, first])
    #expect(try await repository.changes(in: first).first?.kind == .added)
    #expect(try await repository.changes(in: second).first?.kind == .modified)
    let historical = try await repository.comparison(in: second, path: "Sources/file.swift")
    #expect(historical.before == Data("first\n".utf8))
    #expect(historical.after == Data("second\n".utf8))
    await #expect(throws: GitError.nothingToCommit) { try await repository.commit(message: "Empty", author: author) }
    try FileManager.default.removeItem(at: file)
    #expect(try await repository.status().files.first?.unstaged == .deleted)
    try await repository.stage(paths: ["Sources/file.swift"])
    let deleted = try await repository.commit(message: "Delete", author: author)
    #expect(try await repository.changes(in: deleted).first?.kind == .deleted)
    #expect(try await repository.comparison(in: deleted, path: "Sources/file.swift").after == nil)
    #expect(try await repository.status().files.isEmpty)
    #if os(macOS)
    #expect(try statusGit(["status", "--porcelain"], at: root).isEmpty)
    _ = try statusGit(["fsck", "--strict"], at: root)
    #expect(String(decoding: try statusGit(["show", "\(first.hex):Sources/file.swift"], at: root), as: UTF8.self) == "first\n")
    #expect(String(decoding: try statusGit(["rev-list", "--count", "HEAD"], at: root), as: UTF8.self) == "3\n")
    #endif
}

@Test func ignoreRulesLocksAndSymlinksAreRespected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await GitRepository.create(at: root)
    let author = try GitAuthor(name: "Tester", email: "test@example.com")
    try Data("tracked".utf8).write(to: root.appendingPathComponent("tracked.log"))
    try await repository.stage(paths: ["tracked.log"])
    _ = try await repository.commit(message: "Track log", author: author)
    try Data("*.log\n!keep.log\nbuild/\n**/cache/**\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
    try Data("ignored".utf8).write(to: root.appendingPathComponent("ignored.log"))
    try Data("keep".utf8).write(to: root.appendingPathComponent("keep.log"))
    try Data("changed".utf8).write(to: root.appendingPathComponent("tracked.log"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: false)
    try Data("ignored".utf8).write(to: root.appendingPathComponent("build/file"))
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside-link").path, withDestinationPath: "/etc/passwd")
    let files = try await repository.status().files
    #expect(Set(files.map(\.path)) == [".gitignore", "keep.log", "tracked.log", "outside-link"])
    #expect(files.first { $0.path == "tracked.log" }?.unstaged == .modified)
    try await repository.stage(paths: ["outside-link"])
    #expect(try await repository.comparison(path: "outside-link", staged: true).after == Data("/etc/passwd".utf8))
    try Data().write(to: root.appendingPathComponent(".git/index.lock"))
    let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    await #expect(throws: GitError.repositoryBusy) { try await repository.stage(paths: ["keep.log"]) }
    #expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == before)
    try FileManager.default.removeItem(at: root.appendingPathComponent(".git/index.lock"))
    await #expect(throws: (any Error).self) { try await repository.stage(paths: [".git/config"]) }
    #if os(macOS)
    let native = String(decoding: try statusGit(["status", "--porcelain", "--untracked-files=all"], at: root), as: UTF8.self)
    #expect(native.contains(" M tracked.log"))
    #expect(!native.contains("ignored.log"))
    #expect(!native.contains("build/file"))
    #endif
}

@Test func indexCorruptionAndConflictsNeverOverwriteMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await GitRepository.create(at: root)
    try Data("file".utf8).write(to: root.appendingPathComponent("file"))
    try await repository.stage(paths: ["file"])
    let indexURL = root.appendingPathComponent(".git/index")
    var data = try Data(contentsOf: indexURL)
    data[data.count - 1] ^= 1
    try data.write(to: indexURL)
    await #expect(throws: GitError.objectHashMismatch) { try await repository.stage(paths: ["file"]) }
    #expect(try Data(contentsOf: indexURL) == data)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    #expect(throws: GitError.invalidIdentity) { try GitAuthor(name: "bad\nauthor", email: "x@y") }
}

#if os(macOS)
@Test(arguments: GitHashAlgorithm.allCases)
func historyWalksMergeParentsAndPackedReferences(algorithm: GitHashAlgorithm) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await GitRepository.create(at: root, algorithm: algorithm)
    let author = try GitAuthor(name: "Tester", email: "test@example.com")
    try Data("main".utf8).write(to: root.appendingPathComponent("main"))
    try await repository.stage(paths: ["main"])
    let base = try await repository.commit(message: "Base", author: author)
    _ = try statusGit(["checkout", "-b", "feature"], at: root)
    try Data("feature".utf8).write(to: root.appendingPathComponent("feature"))
    try await repository.stage(paths: ["feature"])
    let feature = try await repository.commit(message: "Feature", author: author)
    _ = try statusGit(["checkout", "main"], at: root)
    try Data("other".utf8).write(to: root.appendingPathComponent("other"))
    try await repository.stage(paths: ["other"])
    let other = try await repository.commit(message: "Other", author: author)
    _ = try statusGit(["-c", "user.name=Tester", "-c", "user.email=test@example.com", "merge", "--no-ff", "feature", "-m", "Merge feature"], at: root)
    _ = try statusGit(["pack-refs", "--all"], at: root)
    let reopened = try await GitRepository.open(at: root)
    let commits = try await reopened.log()
    #expect(commits.count == 4)
    #expect(commits.first?.parents.count == 2)
    #expect(Set(commits.map(\.id)).isSuperset(of: [base, feature, other]))
    #expect(try await reopened.status().files.isEmpty)
    _ = try statusGit(["checkout", "--detach"], at: root)
    try Data("detached".utf8).write(to: root.appendingPathComponent("other"))
    try await reopened.stage(paths: ["other"])
    let detached = try await reopened.commit(message: "Detached", author: author)
    #expect(try await reopened.head().branch == nil)
    #expect(try await reopened.head().id == detached)
    _ = try statusGit(["fsck", "--strict"], at: root)
}

private func statusGit(_ arguments: [String], at root: URL) throws -> Data {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    task.arguments = ["-C", root.path] + arguments
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["LC_ALL"] = "C"
    task.environment = environment
    let output = Pipe()
    let errors = Pipe()
    task.standardOutput = output
    task.standardError = errors
    task.standardInput = FileHandle.nullDevice
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw GitError.malformedObject(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
    return data
}
#endif
