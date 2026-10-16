//
//  CloneTests.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Testing
@testable import Swift_Git

@Test func sha1CollisionIsRejected() throws {
    let url = try #require(Bundle.module.url(forResource: "sha-mbles-1", withExtension: "bin", subdirectory: "Fixtures"))
    var hash = GitChecksum(.sha1)
    hash.update(try Data(contentsOf: url))
    #expect(throws: GitError.sha1Collision) { try hash.finalize() }
}

@Test(arguments: ["http://example.com/repo.git", "git@example.com:repo.git", "https://user:secret@example.com/repo", "https://example.com/repo?token=x", "https://example.com/repo#main", "https://example.com"])
func invalidCloneURLs(input: String) {
    #expect(throws: GitError.invalidRemoteURL) { try GitRemoteURL(input) }
}

@Test func deltaInstructionsAreBounded() throws {
    #expect(try GitDelta.apply(Data([3, 4, 0x90, 3, 1, 88]), to: Data("abc".utf8), limit: 4) == Data("abcX".utf8))
    for bytes: [UInt8] in [[3, 4, 0], [3, 1, 0x90, 3], [3, 4, 0x91, 2, 3], [3, 2, 2, 65], [3, 4, 0x90, 3]] {
        #expect(throws: (any Error).self) { try GitDelta.apply(Data(bytes), to: Data("abc".utf8), limit: 4) }
    }
    #expect(throws: GitError.sizeLimitExceeded(2)) { try GitDelta.apply(Data([3, 4]), to: Data("abc".utf8), limit: 2) }
}

@Test func treeParsingStopsAtEntryBudget() throws {
    let blob = GitObject(kind: .blob, body: Data()).id(using: .sha1)
    let entries = try ["a", "b", "c"].map { try GitTreeEntry(mode: .regular, name: Data($0.utf8), objectID: blob) }
    let object = try GitTree(entries: entries).object(using: .sha1)
    #expect(throws: GitError.resourceLimitExceeded("tree entry count", 2)) {
        try GitTree(object: object, algorithm: .sha1, maximumEntries: 2)
    }
}

@Test(arguments: GitHashAlgorithm.allCases)
func packResolvesForwardAndOffsetDeltas(algorithm: GitHashAlgorithm) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await GitRepository.create(at: root, algorithm: algorithm)
    let base = GitObject(kind: .blob, body: Data("abc".utf8))
    let target = GitObject(kind: .blob, body: Data("abcX".utf8))
    let delta = Data([3, 4, 0x90, 3, 1, 88])
    var pack = Data("PACK".utf8)
    pack.appendNetwork(2)
    pack.appendNetwork(3)
    pack.append(0x70 | UInt8(delta.count))
    pack.append(contentsOf: base.id(using: algorithm).bytes)
    pack.append(try GitZlib.compress(delta))
    let baseOffset = pack.count
    pack.append(0x30 | UInt8(base.body.count))
    pack.append(try GitZlib.compress(base.body))
    let offset = pack.count
    pack.append(0x60 | UInt8(delta.count))
    pack.append(UInt8(offset - baseOffset))
    pack.append(try GitZlib.compress(delta))
    var checksum = GitChecksum(algorithm)
    checksum.update(pack)
    pack.append(contentsOf: try checksum.finalize().bytes)
    let url = root.appendingPathComponent("test.pack")
    try pack.write(to: url)
    let ids = try await GitPack.unpack(url, into: repository, options: .init(), progress: nil)
    #expect(ids == [base.id(using: algorithm), target.id(using: algorithm)])
    #expect(try await repository.readObject(target.id(using: algorithm)) == target)
    var limits = GitCloneOptions()
    limits.maximumObjects = 1
    await #expect(throws: GitError.resourceLimitExceeded("object count", 1)) { try await GitPack.unpack(url, into: repository, options: limits, progress: nil) }
    limits = GitCloneOptions()
    limits.maximumExpandedBytes = 3
    await #expect(throws: GitError.sizeLimitExceeded(3)) { try await GitPack.unpack(url, into: repository, options: limits, progress: nil) }
    pack[pack.count - 1] ^= 1
    try pack.write(to: url)
    await #expect(throws: GitError.objectHashMismatch) { try await GitPack.unpack(url, into: repository, options: .init(), progress: nil) }
}

@Test func packRejectsMistypedObjectReferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await GitRepository.create(at: root)
    let blob = GitObject(kind: .blob, body: Data("not a commit".utf8))
    let tree = GitObject(kind: .tree, body: Data())
    let commit = GitObject(kind: .commit, body: Data("tree \(tree.id(using: .sha1).hex)\nparent \(blob.id(using: .sha1).hex)\n\nmessage\n".utf8))
    var pack = Data("PACK".utf8)
    pack.appendNetwork(2)
    pack.appendNetwork(3)
    for (type, object) in [(UInt8(3), blob), (UInt8(2), tree), (UInt8(1), commit)] {
        var remaining = object.body.count >> 4
        var first = (type << 4) | UInt8(object.body.count & 15)
        if remaining > 0 { first |= 128 }
        pack.append(first)
        while remaining > 0 {
            var byte = UInt8(remaining & 127)
            remaining >>= 7
            if remaining > 0 { byte |= 128 }
            pack.append(byte)
        }
        pack.append(try GitZlib.compress(object.body))
    }
    var checksum = GitChecksum(.sha1)
    checksum.update(pack)
    pack.append(contentsOf: try checksum.finalize().bytes)
    let url = root.appendingPathComponent("bad.pack")
    try pack.write(to: url)
    await #expect(throws: GitError.malformedObject("missing or mistyped referenced object")) {
        try await GitPack.unpack(url, into: repository, options: .init(), progress: nil)
    }
}

@Test func emptyCloneAndFailureCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = try GitRemoteURL("https://example.com/repository.git")
    let zero = String(repeating: "0", count: 40)
    let advertisement = try advertisement("\(zero) capabilities^{}\0side-band-64k symref=HEAD:refs/heads/trunk\n")
    let target = root.appendingPathComponent("empty")
    let repository = try await GitRepository.clone(from: remote, to: target, transport: FixtureTransport(advertisement: advertisement, response: Data()))
    #expect(repository.initialBranch == "trunk")
    #expect(try String(contentsOf: target.appendingPathComponent(".git/HEAD"), encoding: .utf8) == "ref: refs/heads/trunk\n")
    let id = GitObject(kind: .blob, body: Data()).id(using: .sha1)
    let badAdvertisement = try selfAdvertisement(id)
    let failureTarget = root.appendingPathComponent("failed")
    await #expect(throws: (any Error).self) {
        try await GitRepository.clone(from: remote, to: failureTarget, transport: FixtureTransport(advertisement: badAdvertisement, response: Data("broken".utf8)))
    }
    #expect(!FileManager.default.fileExists(atPath: failureTarget.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["empty"])
    await #expect(throws: GitError.repositoryAlreadyExists) {
        try await GitRepository.clone(from: remote, to: target, transport: FixtureTransport(advertisement: advertisement, response: Data()))
    }
}

@Test func checkoutRejectsMetadataPathsAndCaseCollisions() async throws {
    for names in [[".git"], [".GIT"], ["README", "readme"]] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.create(at: root)
        let blob = try await repository.writeObject(GitObject(kind: .blob, body: Data("safe".utf8)))
        let entries = try names.map { try GitTreeEntry(mode: .regular, name: Data($0.utf8), objectID: blob) }
        let tree = try await repository.writeObject(GitTree(entries: entries).object(using: .sha1))
        let commit = try await repository.writeObject(GitObject(kind: .commit, body: Data("tree \(tree.hex)\n\nmessage\n".utf8)))
        await #expect(throws: (any Error).self) { try await GitCheckout.populate(repository, commit: commit, options: .init(), progress: nil) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/config").path))
    }
}

private func advertisement(_ reference: String) throws -> Data {
    var bytes = try GitPacket.encode(Data("# service=git-upload-pack\n".utf8))
    bytes.append(Data("0000".utf8))
    bytes.append(try GitPacket.encode(Data(reference.utf8)))
    bytes.append(Data("0000".utf8))
    return bytes
}

private func selfAdvertisement(_ id: GitObjectID) throws -> Data {
    try advertisement("\(id.hex) HEAD\0side-band-64k symref=HEAD:refs/heads/main\n")
}

private struct FixtureTransport: GitHTTPTransport {
    let advertisement: Data
    let response: Data
    func discover(_ url: URL) async throws -> Data { advertisement }
    func fetch(_ url: URL, request: Data, to file: URL, limit: Int, progress: GitCloneProgressHandler?) async throws {
        try response.write(to: file)
    }
}

@Test func cancellingCloneRemovesUnpublishedWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = try GitRemoteURL("https://example.com/repository.git")
    let id = GitObject(kind: .blob, body: Data()).id(using: .sha1)
    let (started, signal) = AsyncStream<Void>.makeStream()
    let transport = CancellationTransport(advertisement: try selfAdvertisement(id), started: signal)
    let task = Task { try await GitRepository.clone(from: remote, to: root.appendingPathComponent("clone"), transport: transport) }
    for await _ in started { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

private struct CancellationTransport: GitHTTPTransport {
    let advertisement: Data
    let started: AsyncStream<Void>.Continuation
    func discover(_ url: URL) async throws -> Data { advertisement }
    func fetch(_ url: URL, request: Data, to file: URL, limit: Int, progress: GitCloneProgressHandler?) async throws {
        started.yield(())
        started.finish()
        try await Task.sleep(for: .seconds(10))
    }
}

#if os(macOS)
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFT_GIT_NETWORK_TESTS"] == "1"),
      arguments: ["https://github.com/octocat/Hello-World.git", "https://github.com/octocat/Hello-World"])
func publicHTTPSClone(url: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = try GitRemoteURL(url)
    let repository = try await GitRepository.clone(from: remote, to: root)
    #expect(repository.initialBranch == "master")
    #expect(try Data(contentsOf: root.appendingPathComponent("README")).count > 0)
    let reopened = try await GitRepository.open(at: root)
    #expect(try await reopened.status().files.isEmpty)
    let actualHistory = try await reopened.log().map { $0.id.hex }
    let nativeHistory = String(decoding: try nativeGit(["rev-list", "HEAD"], at: root), as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(Set(actualHistory) == Set(nativeHistory))
    #expect(try nativeGit(["status", "--porcelain"], at: root).isEmpty)
    _ = try nativeGit(["fsck", "--strict"], at: root)
}

@Test(arguments: GitHashAlgorithm.allCases)
func cloneInteroperatesWithOfficialUploadPack(algorithm: GitHashAlgorithm) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    _ = try nativeGit(["init", "-b", "main", "--object-format=\(algorithm.rawValue)", source.path], at: root)
    _ = try nativeGit(["config", "user.name", "Clone Test"], at: source)
    _ = try nativeGit(["config", "user.email", "clone@example.com"], at: source)
    try Data("# Clone fixture\n".utf8).write(to: source.appendingPathComponent("README.md"))
    try Data([0, 255, 1, 128]).write(to: source.appendingPathComponent("binary"))
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source.appendingPathComponent("run.sh"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("run.sh").path)
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("readme-link").path, withDestinationPath: "README.md")
    for revision in 0..<8 {
        try Data((String(repeating: "shared content\n", count: 2_000) + "revision \(revision)\n").utf8).write(to: source.appendingPathComponent("history.txt"))
        _ = try nativeGit(["add", "."], at: source)
        _ = try nativeGit(["commit", "-m", "Revision \(revision)"], at: source)
    }
    let gitlinkTarget = String(decoding: try nativeGit(["rev-parse", "HEAD"], at: source), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try nativeGit(["update-index", "--add", "--cacheinfo", "160000,\(gitlinkTarget),module"], at: source)
    _ = try nativeGit(["commit", "-m", "Add uninitialized gitlink"], at: source)
    _ = try nativeGit(["branch", "feature", "HEAD~1"], at: source)
    _ = try nativeGit(["tag", "-a", "v1", "-m", "Version 1"], at: source)
    let target = root.appendingPathComponent("clone")
    let remote = try GitRemoteURL("https://example.com/fixture.git")
    let repository = try await GitRepository.clone(from: remote, to: target, transport: NativeTransport(source: source))
    #expect(repository.hashAlgorithm == algorithm)
    #expect(repository.initialBranch == "main")
    let reopened = try await GitRepository.open(at: target)
    #expect(try await reopened.status().files.isEmpty)
    #expect(try await reopened.log().count == 9)
    #expect(try await reopened.log(limit: 2).count == 2)
    #expect(try nativeGit(["rev-parse", "HEAD"], at: target) == nativeGit(["rev-parse", "HEAD"], at: source))
    #expect(try nativeGit(["status", "--porcelain"], at: target).isEmpty)
    #expect(try nativeGit(["config", "remote.origin.url"], at: target) == Data("https://example.com/fixture.git\n".utf8))
    #expect(try nativeGit(["rev-parse", "origin/feature"], at: target) == nativeGit(["rev-parse", "feature"], at: source))
    #expect(try nativeGit(["rev-parse", "v1"], at: target) == nativeGit(["rev-parse", "v1"], at: source))
    _ = try nativeGit(["fsck", "--strict"], at: target)
    #expect(try Data(contentsOf: target.appendingPathComponent("binary")) == Data([0, 255, 1, 128]))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("readme-link").path) == "README.md")
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent("module").path).isEmpty)
}

private struct NativeTransport: GitHTTPTransport {
    let source: URL
    func discover(_ url: URL) async throws -> Data {
        var bytes = try GitPacket.encode(Data("# service=git-upload-pack\n".utf8))
        bytes.append(Data("0000".utf8))
        bytes.append(try nativeGit(["upload-pack", "--stateless-rpc", "--advertise-refs", source.path], at: source))
        return bytes
    }
    func fetch(_ url: URL, request: Data, to file: URL, limit: Int, progress: GitCloneProgressHandler?) async throws {
        try nativeGit(["upload-pack", "--stateless-rpc", source.path], at: source, input: request).write(to: file)
    }
}

private func nativeGit(_ arguments: [String], at directory: URL, input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_AUTHOR_DATE"] = "1700000000 +0000"
    environment["GIT_COMMITTER_DATE"] = "1700000000 +0000"
    environment["LC_ALL"] = "C"
    process.environment = environment
    let output = Pipe()
    // upload-pack progress can exceed a pipe buffer; keep stderr separate on disk.
    let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("git-test-stderr-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let errors = try FileHandle(forWritingTo: errorURL)
    defer { try? errors.close(); try? FileManager.default.removeItem(at: errorURL) }
    process.standardOutput = output
    process.standardError = errors
    let stdin = Pipe()
    process.standardInput = stdin
    try process.run()
    if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
    try stdin.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitError.invalidProtocol(String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
    }
    return data
}
#endif
