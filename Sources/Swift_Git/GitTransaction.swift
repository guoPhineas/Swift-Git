//
//  GitTransaction.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Darwin
import Foundation

struct GitMetadataChange: Codable {
    let path: String
    let value: Data?
}

struct GitTransactionJournal: Codable {
    struct Entry: Codable {
        let path: String
        let mode: String
        let hex: String
        let size: Int
        init(_ entry: GitIndexEntry) { path = entry.path; mode = entry.mode.rawValue; hex = entry.id.hex; size = entry.size }
        func decoded(_ algorithm: GitHashAlgorithm) throws -> GitIndexEntry {
            try GitIndex.validatePath(path)
            guard let mode = GitFileMode(rawValue: mode), mode != .directory else { throw GitError.malformedObject("transaction mode") }
            return try .init(path: path, mode: mode, id: GitObjectID(hex: hex, algorithm: algorithm), size: size)
        }
    }
    let oldFiles: [Entry]
    let newFiles: [Entry]
    let oldMetadata: [GitMetadataChange]
    let newMetadata: [GitMetadataChange]
    var owner: Int32
    var locks: [GitLockIdentity]
}

extension GitRepository {
    func checkoutTransaction(to id: GitObjectID, changes: [GitMetadataChange], expectedHead: HeadState? = nil) throws {
        let expected = try expectedHead ?? headState()
        guard try status().files.isEmpty else { throw GitError.dirtyWorktree }
        var entries = Array(try headFiles(id).values)
        for index in entries.indices where entries[index].mode != .gitlink {
            let entry = entries[index]
            let size = try readObject(entry.id).body.count
            entries[index] = .init(path: entry.path, mode: entry.mode, id: entry.id, size: size)
        }
        var updates = changes
        var symbolicTarget: String?
        if let value = changes.first(where: { $0.path == "HEAD" })?.value {
            let text = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("ref: ") {
                let reference = String(text.dropFirst(5)); _ = try GitReferenceName(reference)
                symbolicTarget = reference
                updates.append(.init(path: reference, value: Data("\(id.hex)\n".utf8)))
            }
        }
        try workingTransaction(entries: entries, changes: updates) {
            guard try headState() == expected else { throw GitError.repositoryBusy }
            if let reference = symbolicTarget, try resolveReference(reference) != id { throw GitError.repositoryBusy }
        }
    }

    func metadataTransaction(_ changes: [GitMetadataChange], holding: [String: GitFileLock] = [:], validate: () throws -> Void = {}) throws {
        try transaction(oldFiles: [], newFiles: [], changes: changes, holding: holding, validate: validate)
    }

    func workingTransaction(entries: [GitIndexEntry], changes: [GitMetadataChange], index: [GitIndexEntry]? = nil,
                            originalWorking: [GitIndexEntry]? = nil, validate: () throws -> Void = {}) throws {
        let expectedIndex = try indexEntries()
        let old = originalWorking ?? expectedIndex
        try validateIndexPaths(entries)
        let encoded = try GitIndex.encode(index ?? entries, algorithm: hashAlgorithm)
        try transaction(oldFiles: old, newFiles: entries, changes: changes + [.init(path: "index", value: encoded)]) {
            guard try indexEntries() == expectedIndex else { throw GitError.repositoryBusy }
            try validate()
        }
    }

    private func transaction(oldFiles: [GitIndexEntry], newFiles: [GitIndexEntry], changes: [GitMetadataChange],
                             holding: [String: GitFileLock] = [:], validate: () throws -> Void = {}) throws {
        let operation = try GitFileLock(metadataURL("mobgit-operation"))
        defer { withExtendedLifetime(operation) {} }
        guard try optionalMetadata("mobgit-transaction.json", limit: 128 * 1_024 * 1_024) == nil else { throw GitError.recoveryRequired }
        let paths = Set(changes.map(\.path)).union(["HEAD", "index"]).sorted()
        var locks = holding
        for path in paths {
            try validateTransactionPath(path)
            if locks[path] == nil { locks[path] = try GitFileLock(metadataURL(path, createParents: true)) }
        }
        defer { withExtendedLifetime(locks) {} }
        try validate()
        try preflightWorkingFiles(old: oldFiles, new: newFiles)
        let previous = try changes.map { GitMetadataChange(path: $0.path, value: try optionalMetadata($0.path, limit: 32 * 1_024 * 1_024)) }
        let journal = GitTransactionJournal(oldFiles: oldFiles.map(GitTransactionJournal.Entry.init), newFiles: newFiles.map(GitTransactionJournal.Entry.init),
                                            oldMetadata: previous, newMetadata: changes, owner: getpid(),
                                            locks: [operation.identity] + locks.values.map(\.identity))
        let journalURL = try metadataURL("mobgit-transaction.json")
        try Task.checkCancellation()
        try saveTransactionJournal(journal, at: journalURL)
        ignoresTransactionCancellation = true
        defer { ignoresTransactionCancellation = false }
        do {
            try replaceWorkingFiles(old: oldFiles, new: newFiles)
            for change in changes {
                if let value = change.value { try locks[change.path]!.publish(value, checkingCancellation: false) }
                else {
                    let url = try metadataURL(change.path)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                }
            }
            try FileManager.default.removeItem(at: journalURL)
        } catch {
            do { try rollback(journal); try FileManager.default.removeItem(at: journalURL) }
            catch { throw GitError.recoveryRequired }
            throw error
        }
    }

    func recoverTransactionIfNeeded() throws {
        guard let data = try optionalMetadata("mobgit-transaction.json", limit: 128 * 1_024 * 1_024) else { return }
        var journal = try JSONDecoder().decode(GitTransactionJournal.self, from: data)
        try removeOwnedStaleLocks(journal)
        let operation = try GitFileLock(metadataURL("mobgit-operation"))
        defer { withExtendedLifetime(operation) {} }
        var locks = [GitFileLock]()
        for path in Set(journal.oldMetadata.map(\.path)).union(["HEAD", "index"]).sorted() {
            try validateTransactionPath(path)
            locks.append(try GitFileLock(metadataURL(path, createParents: true)))
        }
        defer { withExtendedLifetime(locks) {} }
        journal.owner = getpid()
        journal.locks = [operation.identity] + locks.map(\.identity)
        try saveTransactionJournal(journal, at: metadataURL("mobgit-transaction.json"))
        ignoresTransactionCancellation = true
        defer { ignoresTransactionCancellation = false }
        try rollback(journal)
        try FileManager.default.removeItem(at: metadataURL("mobgit-transaction.json"))
    }

    private func saveTransactionJournal(_ journal: GitTransactionJournal, at url: URL) throws {
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 128 * 1_024 * 1_024 else { throw GitError.sizeLimitExceeded(128 * 1_024 * 1_024) }
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func removeOwnedStaleLocks(_ journal: GitTransactionJournal) throws {
        guard journal.owner > 0 else { throw GitError.recoveryRequired }
        var present = [URL]()
        for identity in journal.locks {
            let url = URL(fileURLWithPath: identity.path).standardizedFileURL
            let prefix = gitDirectory.standardizedFileURL.path + "/"
            guard url.path.hasPrefix(prefix), url.path.hasSuffix(".lock") else { throw GitError.recoveryRequired }
            let relative = String(url.path.dropFirst(prefix.count).dropLast(5))
            if relative != "mobgit-operation" { try validateTransactionPath(relative) }
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { continue }
                throw GitError.recoveryRequired
            }
            guard info.st_mode & S_IFMT == S_IFREG, UInt64(info.st_ino) == identity.inode, Int64(info.st_dev) == identity.device else {
                throw GitError.repositoryBusy
            }
            present.append(url)
        }
        guard !present.isEmpty else { return }
        guard kill(journal.owner, 0) != 0, errno == ESRCH else { throw GitError.repositoryBusy }
        for url in present { try FileManager.default.removeItem(at: url) }
    }

    private func rollback(_ journal: GitTransactionJournal) throws {
        guard journal.oldFiles.count <= 100_000, journal.newFiles.count <= 100_000,
              journal.oldMetadata.count == journal.newMetadata.count, journal.oldMetadata.count <= 1024 else { throw GitError.recoveryRequired }
        let old = try journal.oldFiles.map { try $0.decoded(hashAlgorithm) }
        let new = try journal.newFiles.map { try $0.decoded(hashAlgorithm) }
        try validateIndexPaths(old); try validateIndexPaths(new)
        try restoreWorkingFiles(old: old, proposed: new)
        for (before, after) in zip(journal.oldMetadata, journal.newMetadata) {
            guard before.path == after.path else { throw GitError.recoveryRequired }
            try validateTransactionPath(before.path)
            let current = try optionalMetadata(before.path, limit: 32 * 1_024 * 1_024)
            guard current == before.value || current == after.value else { throw GitError.recoveryRequired }
            let url = try metadataURL(before.path, createParents: true)
            if let value = before.value { try value.write(to: url, options: .atomic) }
            else if current != nil { try FileManager.default.removeItem(at: url) }
        }
    }

    private func validateTransactionPath(_ path: String) throws {
        let allowed = ["HEAD", "index", "packed-refs", "MERGE_HEAD", "MERGE_MSG", "ORIG_HEAD", "mobgit-merge.json"]
        if allowed.contains(path) || path == "logs/HEAD" { return }
        if path.hasPrefix("logs/") { _ = try GitReferenceName(String(path.dropFirst(5))); return }
        _ = try GitReferenceName(path)
    }

    private func changedFiles(old: [GitIndexEntry], new: [GitIndexEntry]) -> Set<String> {
        let lhs = Dictionary(uniqueKeysWithValues: old.map { ($0.path, $0) })
        let rhs = Dictionary(uniqueKeysWithValues: new.map { ($0.path, $0) })
        return Set(lhs.keys).union(rhs.keys).filter { path in
            if let entry = lhs[path] { return !entry.matches(rhs[path]) }
            return rhs[path] != nil
        }
    }

    private func preflightWorkingFiles(old: [GitIndexEntry], new: [GitIndexEntry]) throws {
        let changed = changedFiles(old: old, new: new)
        let original = Dictionary(uniqueKeysWithValues: old.map { ($0.path, $0) })
        for entry in old where changed.contains(entry.path) {
            guard try matchesWorkingFile(entry) else { throw GitError.dirtyWorktree }
        }
        func inspectDirectory(_ url: URL, base: String, depth: Int = 0) throws {
            guard depth <= 256 else { throw GitError.resourceLimitExceeded("directory depth", 256) }
            try Self.requireDirectory(url)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let path = base + "/" + child.lastPathComponent
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true { try inspectDirectory(child, base: path, depth: depth + 1) }
                else { guard original[path] != nil else { throw GitError.dirtyWorktree } }
            }
        }
        for entry in new where changed.contains(entry.path) && original[entry.path] == nil {
            let url = workingDirectory.appendingPathComponent(entry.path)
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, old.contains(where: { $0.path.hasPrefix(entry.path + "/") }) else { throw GitError.dirtyWorktree }
                try inspectDirectory(url, base: entry.path)
            }
        }
    }

    private func replaceWorkingFiles(old: [GitIndexEntry], new: [GitIndexEntry]) throws {
        let changed = changedFiles(old: old, new: new)
        for entry in old.filter({ changed.contains($0.path) }).sorted(by: { $0.path.count > $1.path.count }) {
            try removeWorkingFile(entry, allowAbsent: false)
        }
        try pruneEmptyParents(changed)
        for entry in new.filter({ changed.contains($0.path) }).sorted(by: { $0.path < $1.path }) { try installWorkingFile(entry) }
    }

    private func restoreWorkingFiles(old: [GitIndexEntry], proposed: [GitIndexEntry]) throws {
        let changed = changedFiles(old: old, new: proposed)
        let original = Dictionary(uniqueKeysWithValues: old.map { ($0.path, $0) })
        for entry in proposed.filter({ changed.contains($0.path) }).sorted(by: { $0.path.count > $1.path.count }) {
            if let previous = original[entry.path], try matchesWorkingFile(previous) { continue }
            var info = stat()
            let url = workingDirectory.appendingPathComponent(entry.path)
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
               old.contains(where: { $0.path.hasPrefix(entry.path + "/") }) { continue }
            try removeWorkingFile(entry, allowAbsent: true)
        }
        try pruneEmptyParents(changed)
        for entry in old.filter({ changed.contains($0.path) }).sorted(by: { $0.path < $1.path }) {
            if try matchesWorkingFile(entry) { continue }
            try installWorkingFile(entry)
        }
    }

    private func matchesWorkingFile(_ entry: GitIndexEntry) throws -> Bool {
        if entry.mode == .gitlink {
            let url = workingDirectory.appendingPathComponent(entry.path)
            return FileManager.default.fileExists(atPath: url.path) && (try? FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty) == true
        }
        guard let content = try worktreeContent(entry.path) else { return false }
        return try content.mode == entry.mode && GitObject(kind: .blob, body: content.data).validatedID(using: hashAlgorithm) == entry.id
    }

    private func removeWorkingFile(_ entry: GitIndexEntry, allowAbsent: Bool) throws {
        let url = workingDirectory.appendingPathComponent(entry.path)
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT || errno == ENOTDIR { if allowAbsent { return } }
        guard try matchesWorkingFile(entry) else { throw GitError.dirtyWorktree }
        if entry.mode == .gitlink {
            guard rmdir(url.path) == 0 else { throw GitError.dirtyWorktree }
        } else { try FileManager.default.removeItem(at: url) }
    }

    private func installWorkingFile(_ entry: GitIndexEntry) throws {
        try GitIndex.validatePath(entry.path)
        var directory = workingDirectory
        for part in entry.path.split(separator: "/").dropLast() {
            directory.appendPathComponent(String(part))
            if !FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
            try Self.requireDirectory(directory)
        }
        let destination = workingDirectory.appendingPathComponent(entry.path)
        if entry.mode == .gitlink { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false); return }
        let object = try readObject(entry.id)
        guard object.kind == .blob else { throw GitError.malformedObject("checkout blob") }
        if entry.mode == .symbolicLink {
            guard !object.body.isEmpty, !object.body.contains(0) else { throw GitError.unsafeCheckoutPath(entry.path) }
            let bytes = Array(object.body) + [0]
            let status = bytes.withUnsafeBytes { symlink($0.bindMemory(to: CChar.self).baseAddress!, destination.path) }
            guard status == 0 else { throw GitError.dirtyWorktree }
        } else {
            try object.body.write(to: destination, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: entry.mode == .executable ? 0o755 : 0o644], ofItemAtPath: destination.path)
        }
    }

    private func pruneEmptyParents(_ paths: Set<String>) throws {
        var parents = Set<String>()
        for path in paths {
            var components = path.split(separator: "/")
            while components.count > 1 { components.removeLast(); parents.insert(components.joined(separator: "/")) }
        }
        for parent in parents.sorted(by: { $0.count > $1.count }) {
            // rmdir cannot remove a nonempty folder or follow a symlink.
            _ = rmdir(workingDirectory.appendingPathComponent(parent).path)
        }
    }
}
