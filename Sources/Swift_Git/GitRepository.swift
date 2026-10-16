//
//  GitRepository.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Darwin
import Foundation

/// A local, loose-object repository session. No process execution or Git C implementation.
/// Actor methods contain no suspension points while mutating the repository.
public actor GitRepository {
    public nonisolated let workingDirectory: URL
    public nonisolated let hashAlgorithm: GitHashAlgorithm
    public nonisolated let initialBranch: String?
    let gitDirectory: URL
    let maximumObjectBytes: Int

    init(directory: URL, algorithm: GitHashAlgorithm, branch: String?, limit: Int) {
        workingDirectory = directory
        gitDirectory = directory.appendingPathComponent(".git", isDirectory: true)
        hashAlgorithm = algorithm
        initialBranch = branch
        maximumObjectBytes = limit
    }

    /// Creates a repository only in a new or empty directory. Existing contents are never replaced.
    @concurrent
    public static func create(
        at directory: URL,
        algorithm: GitHashAlgorithm = .sha1,
        initialBranch: String = "main",
        maximumObjectBytes: Int = 64 * 1_024 * 1_024
    ) async throws -> GitRepository {
        try validate(directory: directory, limit: maximumObjectBytes)
        _ = try GitReferenceName("refs/heads/\(initialBranch)")
        let manager = FileManager.default
        let directory = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            try requireDirectory(directory)
            guard isDirectory.boolValue,
                  try manager.contentsOfDirectory(atPath: directory.path).isEmpty else {
                throw GitError.repositoryAlreadyExists
            }
        }
        try Task.checkCancellation()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        // Exclusive mkdir also prevents concurrent creators from overwriting metadata.
        guard mkdir(git.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            for path in ["objects/info", "objects/pack", "refs/heads", "refs/tags"] {
                try manager.createDirectory(at: git.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            try Data("ref: refs/heads/\(initialBranch)\n".utf8).write(to: git.appendingPathComponent("HEAD"), options: .withoutOverwriting)
            var config = "[core]\n\trepositoryformatversion = \(algorithm == .sha1 ? 0 : 1)\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n"
            if algorithm == .sha256 { config += "[extensions]\n\tobjectFormat = sha256\n" }
            try Data(config.utf8).write(to: git.appendingPathComponent("config"), options: .withoutOverwriting)
        } catch {
            // Only metadata created by this call is removed; the user's destination is retained.
            try? manager.removeItem(at: git)
            throw error
        }
        return GitRepository(directory: directory, algorithm: algorithm, branch: initialBranch, limit: maximumObjectBytes)
    }

    @concurrent
    public static func open(at directory: URL, maximumObjectBytes: Int = 64 * 1_024 * 1_024) async throws -> GitRepository {
        try validate(directory: directory, limit: maximumObjectBytes)
        let directory = directory.standardizedFileURL
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        try requireDirectory(git)
        let data = try readFile(git.appendingPathComponent("config"), limit: 1_024 * 1_024)
        guard let config = String(data: data, encoding: .utf8) else { throw GitError.notRepository }
        let algorithm = try parseConfiguration(config)
        let head = try readFile(git.appendingPathComponent("HEAD"), limit: 4_096)
        let headText = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let branch: String?
        if headText.hasPrefix("ref: ") {
            let name = String(headText.dropFirst(5))
            _ = try GitReferenceName(name)
            branch = name.hasPrefix("refs/heads/") ? String(name.dropFirst(11)) : nil
        } else {
            _ = try GitObjectID(hex: headText, algorithm: algorithm)
            branch = nil
        }
        try requireDirectory(git.appendingPathComponent("objects", isDirectory: true))
        return GitRepository(directory: directory, algorithm: algorithm, branch: branch, limit: maximumObjectBytes)
    }

    /// Writes one bounded loose object. Large-object streaming is a later capability.
    public func writeObject(_ object: GitObject) throws -> GitObjectID {
        guard object.body.count <= maximumObjectBytes else { throw GitError.sizeLimitExceeded(maximumObjectBytes) }
        try Task.checkCancellation()
        let id = try object.validatedID(using: hashAlgorithm)
        let destination = objectURL(id)
        try Self.requireDirectory(gitDirectory)
        try Self.requireDirectory(gitDirectory.appendingPathComponent("objects"))
        if mkdir(destination.deletingLastPathComponent().path, 0o700) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try Self.requireDirectory(destination.deletingLastPathComponent())
        let compressed = try GitZlib.compress(object.encoded())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("tmp_obj_\(UUID().uuidString)")
        try compressed.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        // link publishes without replacing another writer's existing object.
        if link(temporary.path, destination.path) != 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard try readObject(id) == object else { throw GitError.objectHashMismatch }
        }
        return id
    }

    public func readObject(_ id: GitObjectID) throws -> GitObject {
        guard id.algorithm == hashAlgorithm else { throw GitError.invalidObjectID }
        try Task.checkCancellation()
        try Self.requireDirectory(gitDirectory)
        try Self.requireDirectory(gitDirectory.appendingPathComponent("objects"))
        let url = objectURL(id)
        do {
            try Self.requireDirectory(url.deletingLastPathComponent())
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw GitError.objectNotFound(id)
        }
        let compressed: Data
        do {
            compressed = try Self.readFile(url, limit: maximumObjectBytes + 65_536)
        } catch let error as POSIXError where error.code == .ENOENT {
            throw GitError.objectNotFound(id)
        }
        let object = try GitObject(encoded: GitZlib.decompress(compressed, limit: maximumObjectBytes + 128))
        guard object.body.count <= maximumObjectBytes else { throw GitError.sizeLimitExceeded(maximumObjectBytes) }
        guard try object.validatedID(using: hashAlgorithm) == id else { throw GitError.objectHashMismatch }
        return object
    }

    private func objectURL(_ id: GitObjectID) -> URL {
        let hex = id.hex
        return gitDirectory.appendingPathComponent("objects/\(hex.prefix(2))/\(hex.dropFirst(2))")
    }

    private static func validate(directory: URL, limit: Int) throws {
        guard directory.isFileURL else { throw GitError.notRepository }
        guard limit >= 0, limit <= Int(UInt32.max) - 65_536 else { throw GitError.sizeLimitExceeded(limit) }
    }

    static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw GitError.notRepository }
    }

    /// Open without following a final symlink; bound allocation before reading.
    static func readFile(_ url: URL, limit: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw GitError.malformedObject("expected regular file") }
        guard info.st_size >= 0, info.st_size <= limit else { throw GitError.sizeLimitExceeded(limit) }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw GitError.sizeLimitExceeded(limit) }
        return data
    }

    private static func parseConfiguration(_ text: String) throws -> GitHashAlgorithm {
        var section = ""
        var values = [String: String]()
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw GitError.unsupportedFeature("complex config syntax") }
                section = String(line.dropFirst().dropLast()).lowercased()
                if section.hasPrefix("include") { throw GitError.unsupportedFeature("config includes") }
                continue
            }
            let pieces = line.split(separator: "=", maxSplits: 1)
            let key = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pieces.count == 2 ? pieces[1].trimmingCharacters(in: .whitespaces) : "true"
            values["\(section).\(key)"] = value
        }
        guard let version = values["core.repositoryformatversion"], version == "0" || version == "1" else {
            throw GitError.unsupportedFeature("repository format version")
        }
        if values["core.bare"]?.lowercased() == "true" { throw GitError.unsupportedFeature("bare repository") }
        for key in values.keys where key.hasPrefix("extensions.") && key != "extensions.objectformat" {
            throw GitError.unsupportedFeature(key)
        }
        if values["core.worktree"] != nil { throw GitError.unsupportedFeature("separate worktree") }
        if let format = values["extensions.objectformat"] {
            guard version == "1", let algorithm = GitHashAlgorithm(rawValue: format) else {
                throw GitError.unsupportedFeature("object format \(format)")
            }
            return algorithm
        }
        return .sha1
    }
}
