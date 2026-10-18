//
//  CommitPreparationTests.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/18.
//

import Foundation
import Testing
@testable import Swift_Git

@Test(arguments: GitHashAlgorithm.allCases)
func commitReviewRejectsChangedIndexBranchAndMerge(algorithm: GitHashAlgorithm) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await GitRepository.create(at: root, algorithm: algorithm)
    let author = try GitAuthor(name: "Tester", email: "test@example.com")
    let file = root.appendingPathComponent("file")
    try Data("base\n".utf8).write(to: file)
    try await repository.stage(paths: ["file"])
    let initial = try await repository.prepareCommit()
    #expect(initial.status.head.id == nil)
    #expect(initial.status.head.branch == "main")
    #expect(initial.status.files.first?.staged == .added)
    _ = try await repository.commit(message: "Initial", author: author, expectedState: initial.state)

    try Data("reviewed\n".utf8).write(to: file)
    try await repository.stage(paths: ["file"])
    let reviewed = try await repository.prepareCommit()
    // Working-tree changes after review must stay out of the index-only commit.
    try Data("unstaged\n".utf8).write(to: file)
    let id = try await repository.commit(message: "Reviewed", author: author, expectedState: reviewed.state)
    #expect(try await repository.comparison(in: id, path: "file").after == Data("reviewed\n".utf8))
    #expect(try await repository.status().files.first?.unstaged == .modified)
    try await repository.stage(paths: ["file"])
    let stale = try await repository.prepareCommit()
    try Data("another staged file\n".utf8).write(to: root.appendingPathComponent("another"))
    try await repository.stage(paths: ["another"])
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    await #expect(throws: GitError.commitStateChanged) {
        try await repository.commit(message: "Stale review", author: author, expectedState: stale.state)
    }
    #expect(try await repository.head().id == id)
    #expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index)
    let fresh = try await repository.prepareCommit()
    _ = try await repository.commit(message: "Refreshed", author: author, expectedState: fresh.state)
    try await repository.createBranch("other")
    let oldBranch = try await repository.prepareCommit()
    try await repository.switchBranch("other")
    #expect(try await repository.head().id == oldBranch.status.head.id)
    await #expect(throws: GitError.commitStateChanged) {
        try await repository.commit(message: "Wrong branch", author: author, expectedState: oldBranch.state)
    }
    #expect(try await repository.head().branch == "other")
    let beforeMerge = try await repository.prepareCommit()
    let mergeHead = root.appendingPathComponent(".git/MERGE_HEAD")
    try Data("\(id.hex)\n".utf8).write(to: mergeHead)
    await #expect(throws: GitError.commitStateChanged) {
        try await repository.commit(message: "Changed merge", author: author, expectedState: beforeMerge.state)
    }
    try FileManager.default.removeItem(at: mergeHead)
    #expect(try await repository.status().files.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/HEAD.lock").path))
}

@Test(arguments: GitHashAlgorithm.allCases)
func reviewedMergeCanCommitWithoutChangedFiles(algorithm: GitHashAlgorithm) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await GitRepository.create(at: root, algorithm: algorithm)
    let author = try GitAuthor(name: "Tester", email: "test@example.com")
    let file = root.appendingPathComponent("file")
    try Data("base\n".utf8).write(to: file)
    try await repository.stage(paths: ["file"])
    _ = try await repository.commit(message: "Base", author: author)
    try await repository.createBranch("feature")
    var tips = [GitObjectID]()
    for branch in ["main", "feature"] {
        try await repository.switchBranch(branch)
        try Data("\(branch)\n".utf8).write(to: file)
        try await repository.stage(paths: ["file"])
        _ = try await repository.commit(message: "Change \(branch)", author: author)
        try Data("base\n".utf8).write(to: file)
        try await repository.stage(paths: ["file"])
        tips.append(try await repository.commit(message: "Restore \(branch)", author: author))
    }
    try await repository.switchBranch("main")
    #expect(try await repository.merge(tips[1]) == .readyToCommit)
    let review = try await repository.prepareCommit()
    #expect(review.isMerging)
    #expect(review.status.files.isEmpty)
    let merge = try await repository.commit(message: "Join histories", author: author, expectedState: review.state)
    #expect(try await repository.log().first?.parents == tips)
    #expect(try await repository.head().id == merge)
    #expect(try await repository.mergeState() == false)
}
