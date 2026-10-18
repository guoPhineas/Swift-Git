//
//  MergeTests.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Testing
@testable import Swift_Git

@Test(arguments: GitHashAlgorithm.allCases)
func mergeConflictsSurviveReopenAndCanContinueOrAbort(algorithm: GitHashAlgorithm) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var repo = try await GitRepository.create(at: root, algorithm: algorithm)
    let author = try GitAuthor(name: "Tester", email: "test@example.com")
    let file = root.appendingPathComponent("file")
    try Data("first\nbase\nlast\n".utf8).write(to: file)
    try await repo.stage(paths: ["file"])
    let base = try await repo.commit(message: "Base", author: author)
    try await repo.createBranch("feature")
    try Data("first\nours\nlast\n".utf8).write(to: file)
    try await repo.stage(paths: ["file"])
    let ours = try await repo.commit(message: "Ours", author: author)
    try await repo.switchBranch("feature")
    #expect(try String(contentsOf: file, encoding: .utf8) == "first\nbase\nlast\n")
    try Data("first\ntheirs\nlast\n".utf8).write(to: file)
    try await repo.stage(paths: ["file"])
    let theirs = try await repo.commit(message: "Theirs", author: author)
    try await repo.switchBranch("main")
    #expect(try await repo.mergeBase(ours, theirs) == base)
    #expect(try await repo.merge(theirs) == .conflicts(["file"]))
    #expect(try String(contentsOf: file, encoding: .utf8).contains("<<<<<<< HEAD"))
    #expect(try await repo.status().files.first?.staged == .conflicted)
    repo = try await GitRepository.open(at: root)
    #expect(try await repo.conflicts().first?.ours == Data("first\nours\nlast\n".utf8))
    await #expect(throws: GitError.unresolvedConflicts) { try await repo.commit(message: "Unresolved", author: author) }
    try await repo.abortMerge()
    #expect(try await repo.head().id == ours)
    #expect(try await repo.status().files.isEmpty)
    #expect(try String(contentsOf: file, encoding: .utf8) == "first\nours\nlast\n")
    #expect(try await repo.merge(theirs) == .conflicts(["file"]))
    try await repo.resolveConflict(path: "file", takingTheirs: true)
    #expect(try await repo.conflicts().isEmpty)
    #expect(try String(contentsOf: file, encoding: .utf8) == "first\ntheirs\nlast\n")
    let review = try await repo.prepareCommit()
    #expect(review.isMerging)
    #expect(review.suggestedMessage?.hasPrefix("Merge ") == true)
    let merge = try await repo.commit(message: "Merge feature", author: author, expectedState: review.state)
    let history = try await repo.log()
    #expect(history.first?.id == merge)
    #expect(history.first?.parents == [ours, theirs])
    #expect(try await repo.changes(in: merge, parent: 0).map(\.path) == ["file"])
    #expect(try await repo.changes(in: merge, parent: 1).isEmpty)
    #expect(try await repo.comparison(in: merge, path: "file", parent: 0).before == Data("first\nours\nlast\n".utf8))
    await #expect(throws: (any Error).self) { try await repo.changes(in: merge, parent: 2) }
    #expect(try await repo.status().files.isEmpty)
    #expect(try await repo.mergeState() == false)
    #expect(try await repo.merge(theirs) == .upToDate)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/logs/HEAD").path))
}

@Test func mergeCombinesIndependentTextEdits() throws {
    let base = Data("one\ntwo\nthree\nfour\n".utf8)
    let ours = Data("ONE\ntwo\nthree\nfour\n".utf8)
    let theirs = Data("one\ntwo\nthree\nFOUR\n".utf8)
    let result = try #require(try GitMergeText.merge(base: base, ours: ours, theirs: theirs))
    #expect(!result.conflicted)
    #expect(result.data == Data("ONE\ntwo\nthree\nFOUR\n".utf8))
    let same = try #require(try GitMergeText.merge(base: base, ours: ours, theirs: ours))
    #expect(!same.conflicted)
    #expect(same.data == ours)
}
