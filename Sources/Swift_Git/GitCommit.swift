//
//  GitCommit.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public struct GitAuthor: Sendable {
    public let name: String
    public let email: String

    public init(name: String, email: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, email.contains("@"), !email.contains(" "),
              (name + email).utf8.allSatisfy({ $0 >= 32 && $0 != 127 && $0 != 60 && $0 != 62 }) else {
            throw GitError.invalidIdentity
        }
        self.name = name
        self.email = email
    }
}

extension GitRepository {
    /// Commits the current index only. Files edited after staging remain unstaged.
    /// All writes are serialized by Git-compatible lock files; worktree files are untouched.
    /// Pass the state from prepareCommit() to reject changes since the user's review.
    public func commit(message: String, author: GitAuthor, date: Date = .now, expectedState: GitCommitState? = nil) throws -> GitObjectID {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !message.utf8.contains(0) else {
            throw GitError.malformedObject("empty or invalid commit message")
        }
        try validateCommitOperation()
        let indexLock = try GitFileLock(metadataURL("index"))
        let headLock = try GitFileLock(metadataURL("HEAD"))
        defer { withExtendedLifetime(indexLock) {}; withExtendedLifetime(headLock) {} }
        let state = try headState()
        let targetLock: GitFileLock
        if let reference = state.reference {
            if let data = try optionalMetadata(reference, limit: 4096), data.starts(with: Data("ref: ".utf8)) {
                throw GitError.unsupportedFeature("nested symbolic branch update")
            }
            targetLock = try GitFileLock(metadataURL(reference, createParents: true))
        } else { targetLock = headLock }
        if let expectedState, try captureCommitState() != expectedState { throw GitError.commitStateChanged }
        let entries = try indexEntries()
        guard entries.allSatisfy({ $0.stage == 0 }) else { throw GitError.unresolvedConflicts }
        let mergeParents = try optionalMetadata("MERGE_HEAD", limit: 4096).map {
            try String(decoding: $0, as: UTF8.self).split(whereSeparator: \.isWhitespace).map { try GitObjectID(hex: String($0), algorithm: hashAlgorithm) }
        } ?? []
        let tree = try writeTree(entries, base: "", depth: 0)
        if mergeParents.isEmpty, let old = state.id, try commitObject(old).tree == tree { throw GitError.nothingToCommit }
        guard state.id != nil || !entries.isEmpty else { throw GitError.nothingToCommit }
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0, timestamp < Double(Int64.max) else {
            throw GitError.malformedObject("invalid commit date")
        }
        let identity = "\(author.name) <\(author.email)> \(Int64(timestamp)) +0000"
        var body = "tree \(tree.hex)\n"
        if let parent = state.id { body += "parent \(parent.hex)\n" }
        for parent in mergeParents { _ = try commitObject(parent); body += "parent \(parent.hex)\n" }
        body += "author \(identity)\ncommitter \(identity)\n\n" + message
        if !body.hasSuffix("\n") { body += "\n" }
        let id = try writeObject(.init(kind: .commit, body: Data(body.utf8)))
        guard try headState() == state else { throw GitError.repositoryBusy }
        let target = state.reference ?? "HEAD"
        var changes = [GitMetadataChange(path: target, value: Data("\(id.hex)\n".utf8))]
        let zero = String(repeating: "0", count: hashAlgorithm.byteCount * 2)
        let entry = "\(state.id?.hex ?? zero) \(id.hex) \(identity)\tcommit: \(message.split(separator: "\n").first ?? "")\n"
        for path in Set(["logs/HEAD", state.reference.map { "logs/" + $0 }].compactMap { $0 }) {
            var log = try optionalMetadata(path, limit: 8 * 1_024 * 1_024) ?? Data()
            log.append(Data(entry.utf8))
            changes.append(.init(path: path, value: log))
        }
        if !mergeParents.isEmpty {
            changes += [.init(path: "MERGE_HEAD", value: nil), .init(path: "MERGE_MSG", value: nil), .init(path: "mobgit-merge.json", value: nil)]
        }
        var holding = ["index": indexLock, "HEAD": headLock]
        holding[target] = targetLock
        try metadataTransaction(changes, holding: holding) {
            guard try headState() == state, try indexEntries() == entries else { throw GitError.repositoryBusy }
            if let expectedState, try captureCommitState() != expectedState { throw GitError.commitStateChanged }
        }
        return id
    }

    func writeTree(_ entries: [GitIndexEntry], base: String, depth: Int) throws -> GitObjectID {
        guard depth <= 256 else { throw GitError.resourceLimitExceeded("tree depth", 256) }
        var files = [GitTreeEntry]()
        var directories = [String: [GitIndexEntry]]()
        for entry in entries {
            try Task.checkCancellation()
            let relative = entry.path.dropFirst(base.count)
            if let slash = relative.firstIndex(of: "/") {
                directories[String(relative[..<slash]), default: []].append(entry)
            } else {
                if entry.mode != .gitlink {
                    guard try readObject(entry.id).kind == .blob else { throw GitError.malformedObject("staged file is not a blob") }
                }
                files.append(try .init(mode: entry.mode, name: Data(relative.utf8), objectID: entry.id))
            }
        }
        for (name, children) in directories {
            let id = try writeTree(children, base: base + name + "/", depth: depth + 1)
            files.append(try .init(mode: .directory, name: Data(name.utf8), objectID: id))
        }
        return try writeObject(GitTree(entries: files).object(using: hashAlgorithm))
    }
}
