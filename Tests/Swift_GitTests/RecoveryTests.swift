//
//  RecoveryTests.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Testing
@testable import Swift_Git

#if os(macOS)
@Test func interruptedCheckoutRecoversOnlyItsOwnDeadProcessLocks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try await GitRepository.create(at: root)
    let author = try GitAuthor(name: "Tester", email: "test@example.com")
    let original = Data("original\n".utf8), replacement = Data("replacement\n".utf8)
    try original.write(to: root.appendingPathComponent("file"))
    try await repo.stage(paths: ["file"])
    let oldCommit = try await repo.commit(message: "Original", author: author)
    let oldEntries = try await repo.indexEntries()
    let oldIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let blob = try await repo.writeObject(.init(kind: .blob, body: replacement))
    let entry = GitIndexEntry(path: "file", mode: .regular, id: blob, size: replacement.count)
    let tree = try await repo.writeTree([entry], base: "", depth: 0)
    let newCommit = try await repo.writeObject(.init(kind: .commit, body: Data("tree \(tree.hex)\nparent \(oldCommit.hex)\nauthor Tester <test@example.com> 1700000000 +0000\ncommitter Tester <test@example.com> 1700000000 +0000\n\nNew\n".utf8)))
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run(); child.waitUntilExit()
    let locks = try ["mobgit-operation", "HEAD", "index", "refs/heads/main"].map { try GitFileLock(root.appendingPathComponent(".git/" + $0)) }
    defer { withExtendedLifetime(locks) {} }
    let newIndex = try GitIndex.encode([entry], algorithm: .sha1)
    let journal = GitTransactionJournal(oldFiles: oldEntries.map(GitTransactionJournal.Entry.init), newFiles: [.init(entry)], oldMetadata: [
        .init(path: "index", value: oldIndex), .init(path: "refs/heads/main", value: Data("\(oldCommit.hex)\n".utf8)),
    ], newMetadata: [.init(path: "index", value: newIndex), .init(path: "refs/heads/main", value: Data("\(newCommit.hex)\n".utf8))],
        owner: child.processIdentifier, locks: locks.map(\.identity))
    try JSONEncoder().encode(journal).write(to: root.appendingPathComponent(".git/mobgit-transaction.json"))
    try replacement.write(to: root.appendingPathComponent("file"))
    try newIndex.write(to: root.appendingPathComponent(".git/index"))
    try Data("\(newCommit.hex)\n".utf8).write(to: root.appendingPathComponent(".git/refs/heads/main"))
    let recovered = try await GitRepository.open(at: root)
    #expect(try await recovered.head().id == oldCommit)
    #expect(try await recovered.status().files.isEmpty)
    #expect(try Data(contentsOf: root.appendingPathComponent("file")) == original)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/mobgit-transaction.json").path))
}
#endif
