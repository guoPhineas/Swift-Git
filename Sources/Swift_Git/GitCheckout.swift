//
//  GitCheckout.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Darwin
import Foundation

/// Initial checkout into an unpublished, empty clone, never a destructive reset.
enum GitCheckout {
    private struct IndexEntry {
        let path: Data
        let mode: GitFileMode
        let id: GitObjectID
        let size: Int
    }

    private struct SymbolicLink {
        let path: URL
        let target: Data
    }

    @concurrent
    static func populate(_ repository: GitRepository, commit: GitObjectID?, options: GitCloneOptions,
                         progress: GitCloneProgressHandler?) async throws {
        var index = [IndexEntry]()
        var links = [SymbolicLink]()
        var paths = Set<String>()
        var entryCount = 0
        let root = repository.workingDirectory
        progress?(.init(stage: .checkingOut))

        func visit(_ id: GitObjectID, components: [String], depth: Int) async throws {
            guard depth <= 256 else { throw GitError.resourceLimitExceeded("directory depth", 256) }
            let tree = try GitTree(object: await repository.readObject(id), algorithm: repository.hashAlgorithm,
                                   maximumEntries: options.maximumCheckoutFiles - entryCount)
            for entry in tree.entries {
                try Task.checkCancellation()
                entryCount += 1
                guard entryCount <= options.maximumCheckoutFiles else { throw GitError.resourceLimitExceeded("checkout entry count", options.maximumCheckoutFiles) }
                guard let name = String(data: entry.name, encoding: .utf8),
                      name.lowercased() != ".git", !name.contains(":"), !name.contains("\\"),
                      name.utf8.count <= 255 else {
                    throw GitError.unsafeCheckoutPath(String(decoding: entry.name, as: UTF8.self))
                }
                let components = components + [name]
                let relative = components.joined(separator: "/")
                let key = relative.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                guard paths.insert(key).inserted else { throw GitError.unsafeCheckoutPath(relative) }
                let url = components.reduce(root) { $0.appendingPathComponent($1) }
                switch entry.mode {
                case .directory:
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    try await visit(entry.objectID, components: components, depth: depth + 1)
                case .gitlink:
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    index.append(IndexEntry(path: Data(relative.utf8), mode: entry.mode, id: entry.objectID, size: 0))
                case .regular, .executable, .symbolicLink:
                    let blob = try await repository.readObject(entry.objectID)
                    guard blob.kind == .blob else { throw GitError.malformedObject("tree file is not a blob") }
                    if entry.mode == .symbolicLink {
                        guard !blob.body.contains(0), !blob.body.isEmpty else { throw GitError.unsafeCheckoutPath(relative) }
                        links.append(SymbolicLink(path: url, target: blob.body))
                    } else {
                        try blob.body.write(to: url, options: .withoutOverwriting)
                        try FileManager.default.setAttributes([.posixPermissions: entry.mode == .executable ? 0o755 : 0o644], ofItemAtPath: url.path)
                    }
                    index.append(IndexEntry(path: Data(relative.utf8), mode: entry.mode, id: entry.objectID, size: blob.body.count))
                }
                if entryCount % 100 == 0 { progress?(.init(stage: .checkingOut, completed: Int64(entryCount))) }
            }
        }

        if let commit {
            let object = try await repository.readObject(commit)
            guard object.kind == .commit, let tree = try object.referencedObjects(using: repository.hashAlgorithm).first else {
                throw GitError.malformedObject("HEAD is not a commit")
            }
            try await visit(tree, components: [], depth: 0)
        }
        // Install symlinks last so no later checkout write can follow an untrusted link.
        for link in links {
            try Task.checkCancellation()
            let target = Array(link.target) + [0]
            let status = target.withUnsafeBytes { bytes in
                Darwin.symlink(bytes.bindMemory(to: CChar.self).baseAddress!, link.path.path)
            }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try writeIndex(index, algorithm: repository.hashAlgorithm, at: root.appendingPathComponent(".git/index"))
        progress?(.init(stage: .checkingOut, completed: Int64(entryCount), total: Int64(entryCount)))
    }

    private static func writeIndex(_ entries: [IndexEntry], algorithm: GitHashAlgorithm, at url: URL) throws {
        var data = Data("DIRC".utf8)
        data.appendNetwork(2)
        data.appendNetwork(UInt32(entries.count))
        for entry in entries.sorted(by: { $0.path.lexicographicallyPrecedes($1.path) }) {
            try Task.checkCancellation()
            let start = data.count
            // Zero stat fields force a safe content refresh by other Git clients.
            for _ in 0..<6 { data.appendNetwork(0) }
            guard let mode = UInt32(entry.mode.rawValue, radix: 8) else { throw GitError.malformedObject("index mode") }
            data.appendNetwork(mode)
            data.appendNetwork(0) // uid
            data.appendNetwork(0) // gid
            data.appendNetwork(UInt32(entry.size))
            data.append(contentsOf: entry.id.bytes)
            let length = min(entry.path.count, 0xFFF)
            data.append(UInt8(length >> 8))
            data.append(UInt8(length & 255))
            data.append(entry.path)
            data.append(0)
            while (data.count - start) % 8 != 0 { data.append(0) }
        }
        var checksum = GitChecksum(algorithm)
        checksum.update(data)
        data.append(contentsOf: try checksum.finalize().bytes)
        try data.write(to: url, options: .withoutOverwriting)
    }
}

extension Data {
    mutating func appendNetwork(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
