//
//  RemoteBranchTests.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Testing
@testable import Swift_Git

#if os(macOS)
@Test(arguments: GitHashAlgorithm.allCases)
func nativeFetchPushAndSafeBranchSwitch(algorithm: GitHashAlgorithm) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = root.appendingPathComponent("remote")
    _ = try runGit(["init", "--bare", "--object-format=\(algorithm.rawValue)", "-b", "main", remote.path], at: root)
    let url = try GitRemoteURL("https://example.com/repository.git")
    let directory = root.appendingPathComponent("local")
    let repository = try await GitRepository.clone(from: url, to: directory, transport: LocalTransport(root: remote))
    let author = try GitAuthor(name: "Tester", email: "test@example.com")
    try Data("first\n".utf8).write(to: directory.appendingPathComponent("file"))
    try await repository.stage(paths: ["file"])
    let first = try await repository.commit(message: "First", author: author)
    let pushed = try await repository.push(remote: "origin", transport: LocalTransport(root: remote))
    #expect(pushed.id == first)
    #expect(String(decoding: try runGit(["rev-parse", "main"], at: remote), as: UTF8.self) == first.hex + "\n")
    _ = try runGit(["fsck", "--strict"], at: remote)
    try await repository.createBranch("feature")
    try await repository.switchBranch("feature")
    try Data("feature\n".utf8).write(to: directory.appendingPathComponent("file"))
    try await repository.stage(paths: ["file"])
    _ = try await repository.commit(message: "Feature", author: author)
    try await repository.switchBranch("main")
    #expect(try String(contentsOf: directory.appendingPathComponent("file"), encoding: .utf8) == "first\n")
    #expect(try await repository.status().files.isEmpty)
    try await repository.setRemote(url: GitRemoteURL("https://example.com/renamed.git"))
    let reopened = try await GitRepository.open(at: directory)
    #expect(try await reopened.remotes().first?.url.url.absoluteString == "https://example.com/renamed.git")
    #expect(String(decoding: try runGit(["remote", "get-url", "origin"], at: directory), as: UTF8.self) == "https://example.com/renamed.git\n")
    let second = root.appendingPathComponent("second")
    let other = try await GitRepository.clone(from: url, to: second, transport: LocalTransport(root: remote))
    try Data("remote edit\n".utf8).write(to: second.appendingPathComponent("file"))
    try await other.stage(paths: ["file"])
    let advanced = try await other.commit(message: "Remote", author: author)
    _ = try await other.push(remote: "origin", transport: LocalTransport(root: remote))
    let fetched = try await repository.fetch(remote: "origin", transport: LocalTransport(root: remote))
    #expect(fetched.references["refs/heads/main"] == advanced)
    #expect(fetched.receivedObjects > 0)
    #expect(try await repository.head().id == first)
    #expect(try await repository.readObject(advanced).kind == .commit)
    let again = try await repository.fetch(remote: "origin", transport: LocalTransport(root: remote))
    #expect(again.receivedObjects == 0)
    try await repository.createBranch("tracking")
    try await repository.setUpstream(branch: "tracking", remote: "origin", remoteBranch: "main")
    try await repository.switchBranch("tracking")
    #expect(try await repository.pull(remote: "origin", transport: LocalTransport(root: remote)) == .fastForward(advanced))
    #expect(try await repository.head().id == advanced)
    #expect(String(decoding: try runGit(["rev-parse", "tracking@{upstream}"], at: directory), as: UTF8.self) == advanced.hex + "\n")
    await #expect(throws: GitError.repositoryBusy) {
        try await repository.pull(remote: "origin", transport: SwitchingTransport(base: .init(root: remote), repository: repository))
    }
    #expect(try await repository.head().branch == "feature")
    try await repository.switchBranch("feature")
    await #expect(throws: GitError.nonFastForward) { try await repository.push(remote: "origin", branch: "main", transport: LocalTransport(root: remote)) }
    try Data("dirty\n".utf8).write(to: directory.appendingPathComponent("file"))
    await #expect(throws: GitError.dirtyWorktree) { try await repository.switchBranch("main") }
    #expect(try String(contentsOf: directory.appendingPathComponent("file"), encoding: .utf8) == "dirty\n")
    #expect(try await repository.head().branch == "feature")
    _ = try runGit(["fsck", "--strict"], at: directory)
    _ = try runGit(["gc", "--prune=now"], at: directory)
    let packed = try await GitRepository.open(at: directory)
    #expect(try await packed.readObject(first).kind == .commit)
    #expect(try await packed.log().count >= 2)
    #expect(try await packed.status().files.first?.unstaged == .modified)
}

@Test func checkoutDoesNotOverwriteIgnoredFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await GitRepository.create(at: root)
    let author = try GitAuthor(name: "Tester", email: "test@example.com")
    try Data("hidden\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
    try await repository.stage(paths: [".gitignore"])
    _ = try await repository.commit(message: "Ignore", author: author)
    try await repository.createBranch("feature")
    try await repository.switchBranch("feature")
    // Track on the feature branch, then restore the ignore rule.
    try Data().write(to: root.appendingPathComponent(".gitignore"))
    try Data("tracked\n".utf8).write(to: root.appendingPathComponent("hidden"))
    try await repository.stage(paths: [".gitignore", "hidden"])
    _ = try await repository.commit(message: "Track", author: author)
    try await repository.switchBranch("main")
    try Data("private ignored data\n".utf8).write(to: root.appendingPathComponent("hidden"))
    #expect(try await repository.status().files.isEmpty)
    await #expect(throws: GitError.dirtyWorktree) { try await repository.switchBranch("feature") }
    #expect(try String(contentsOf: root.appendingPathComponent("hidden"), encoding: .utf8) == "private ignored data\n")
    #expect(try await repository.head().branch == "main")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/mobgit-transaction.json").path))
}

@Test(arguments: GitHashAlgorithm.allCases, [false, true])
func protocolV2CloneAndFetch(algorithm: GitHashAlgorithm, servicePreamble: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = root.appendingPathComponent("remote")
    _ = try runGit(["init", "--bare", "-b", "trunk", "--object-format=\(algorithm.rawValue)", remote.path], at: root)
    let transport = LocalTransport(root: remote, v2: true, servicePreamble: servicePreamble)
    let url = try GitRemoteURL("https://example.com/repo.git")
    let directory = root.appendingPathComponent("clone")
    let repository = try await GitRepository.clone(from: url, to: directory, transport: transport)
    #expect(try await repository.head().branch == "trunk")
    let author = try GitAuthor(name: "Tester", email: "test@example.com")
    try Data("v2\n".utf8).write(to: directory.appendingPathComponent("file"))
    try await repository.stage(paths: ["file"])
    let first = try await repository.commit(message: "V2", author: author)
    _ = try await repository.push(remote: "origin", transport: transport)
    let second = root.appendingPathComponent("second")
    let clone = try await GitRepository.clone(from: url, to: second, transport: transport)
    #expect(try await clone.head().id == first)
    #expect(try await clone.status().files.isEmpty)
    try Data("v2 update\n".utf8).write(to: directory.appendingPathComponent("file"))
    try await repository.stage(paths: ["file"])
    let next = try await repository.commit(message: "Update", author: author)
    _ = try await repository.push(remote: "origin", transport: transport)
    let fetched = try await clone.fetch(remote: "origin", transport: transport)
    #expect(fetched.references["refs/heads/trunk"] == next)
    #expect(fetched.receivedObjects > 0)
    _ = try runGit(["fsck", "--strict"], at: second)
}

private struct LocalTransport: GitHTTPTransport {
    let root: URL
    var v2 = false
    var servicePreamble = true
    func discover(_ url: URL) async throws -> Data {
        let service = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "git-upload-pack"
        let command = service == "git-receive-pack" ? "receive-pack" : "upload-pack"
        if v2 && command == "upload-pack" {
            let body = try runGit([command, "--stateless-rpc", "--advertise-refs", root.path], at: root, v2: true)
            if !servicePreamble { return body }
            var prefix = try GitPacket.encode(Data("# service=\(service)\n".utf8))
            prefix.append(Data("0000".utf8)); prefix.append(body); return prefix
        }
        var data = try GitPacket.encode(Data("# service=\(service)\n".utf8))
        data.append(Data("0000".utf8))
        data.append(try runGit([command, "--stateless-rpc", "--advertise-refs", root.path], at: root))
        return data
    }
    func fetch(_ url: URL, request: Data, to file: URL, limit: Int, progress: GitCloneProgressHandler?) async throws {
        try runGit(["upload-pack", "--stateless-rpc", root.path], at: root, input: request, v2: v2).write(to: file)
    }
    func send(_ url: URL, requestFile: URL, limit: Int) async throws -> Data {
        try runGit(["receive-pack", "--stateless-rpc", root.path], at: root, input: Data(contentsOf: requestFile))
    }
}

private struct SwitchingTransport: GitHTTPTransport {
    let base: LocalTransport
    let repository: GitRepository
    func discover(_ url: URL) async throws -> Data {
        try await repository.switchBranch("feature")
        return try await base.discover(url)
    }
    func fetch(_ url: URL, request: Data, to file: URL, limit: Int, progress: GitCloneProgressHandler?) async throws {
        try await base.fetch(url, request: request, to: file, limit: limit, progress: progress)
    }
}

private func runGit(_ arguments: [String], at root: URL, input: Data? = nil, v2: Bool = false) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    if v2 { env["GIT_PROTOCOL"] = "version=2" }
    process.environment = env
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let error = output.appendingPathExtension("error"), stdin = output.appendingPathExtension("input")
    defer { for url in [output, error, stdin] { try? FileManager.default.removeItem(at: url) } }
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: error.path, contents: nil)
    try (input ?? Data()).write(to: stdin)
    let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: error), source = try FileHandle(forReadingFrom: stdin)
    defer { try? out.close(); try? err.close(); try? source.close() }
    process.standardOutput = out; process.standardError = err; process.standardInput = source
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw GitError.invalidProtocol(String(decoding: try Data(contentsOf: error), as: UTF8.self)) }
    return try Data(contentsOf: output)
}
#endif
