//
//  RepositoryTests.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Testing
@testable import Swift_Git

@Test(arguments: GitHashAlgorithm.allCases)
func repositoryRoundTrip(algorithm: GitHashAlgorithm) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try await GitRepository.create(at: directory, algorithm: algorithm)
    let object = GitObject(kind: .blob, body: Data("Hello, Swift Git!\n你好\n".utf8))
    let id = try await repository.writeObject(object)
    #expect(try await repository.readObject(id) == object)
    #expect(try await repository.writeObject(object) == id)
    let reopened = try await GitRepository.open(at: directory)
    #expect(reopened.hashAlgorithm == algorithm)
    #expect(reopened.initialBranch == "main")
    #expect(try await reopened.readObject(id) == object)
    await #expect(throws: GitError.repositoryAlreadyExists) { try await GitRepository.create(at: directory) }

    // A correctly compressed but substituted object must not pass integrity validation.
    let path = directory.appendingPathComponent(".git/objects/\(id.hex.prefix(2))/\(id.hex.dropFirst(2))")
    try GitZlib.compress(GitObject(kind: .blob, body: Data("tampered".utf8)).encoded()).write(to: path)
    await #expect(throws: GitError.objectHashMismatch) { try await reopened.readObject(id) }
}

@Test func repositoryLimitsAndUnsupportedExtensions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try await GitRepository.create(at: directory, maximumObjectBytes: 2)
    await #expect(throws: GitError.sizeLimitExceeded(2)) {
        try await repository.writeObject(GitObject(kind: .blob, body: Data([1, 2, 3])))
    }
    let unknown = GitObject(kind: .blob, body: Data([9])).id(using: .sha1)
    await #expect(throws: GitError.objectNotFound(unknown)) { try await repository.readObject(unknown) }
    try Data("[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = reftable\n".utf8)
        .write(to: directory.appendingPathComponent(".git/config"))
    await #expect(throws: GitError.unsupportedFeature("extensions.refstorage")) { try await GitRepository.open(at: directory) }
}

#if os(macOS)
@Test(arguments: GitHashAlgorithm.allCases)
func officialGitInteroperability(algorithm: GitHashAlgorithm) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try await GitRepository.create(at: directory, algorithm: algorithm)
    let blob = GitObject(kind: .blob, body: Data("Written by Swift-Git\n".utf8))
    let blobID = try await repository.writeObject(blob)
    let tree = try GitTree(entries: [GitTreeEntry(mode: .regular, name: Data("README.md".utf8), objectID: blobID)])
    let treeID = try await repository.writeObject(tree.object(using: algorithm))
    let commit = GitObject(kind: .commit, body: Data("tree \(treeID.hex)\nauthor Phineas Guo <test@example.com> 1700000000 +0000\ncommitter Phineas Guo <test@example.com> 1700000000 +0000\n\nInitial commit\n".utf8))
    let commitID = try await repository.writeObject(commit)
    #expect(try git(["cat-file", "blob", blobID.hex], in: directory) == blob.body)
    #expect(try git(["hash-object", "README.md"], in: directory, createFile: blob.body) == Data("\(blobID.hex)\n".utf8))
    _ = try git(["update-ref", "refs/heads/main", commitID.hex], in: directory)
    _ = try git(["fsck", "--strict"], in: directory)
    _ = try git(["read-tree", "HEAD"], in: directory)
    let nativeID = try git(["hash-object", "-w", "--stdin"], in: directory)
    let id = try GitObjectID(hex: String(decoding: nativeID, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), algorithm: algorithm)
    #expect(try await repository.readObject(id) == GitObject(kind: .blob, body: Data()))
}

private func git(_ arguments: [String], in directory: URL, createFile: Data? = nil) throws -> Data {
    if let createFile { try createFile.write(to: directory.appendingPathComponent("README.md")) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["LC_ALL"] = "C"
    process.environment = environment
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitError.malformedObject(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    return data
}
#endif
