//
//  GitStatus.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public enum GitChangeKind: String, Sendable {
    case added, modified, deleted, typeChanged, untracked
}

public struct GitFileStatus: Identifiable, Sendable, Equatable {
    public let path: String
    public let staged: GitChangeKind?
    public let unstaged: GitChangeKind?
    public var id: String { path }
}

public struct GitStatus: Sendable {
    public let head: GitHead
    public let files: [GitFileStatus]
}

public struct GitFileComparison: Sendable {
    public let path: String
    public let before: Data?
    public let after: Data?
    public let beforeMode: GitFileMode?
    public let afterMode: GitFileMode?
}

extension GitRepository {
    public func status() throws -> GitStatus {
        let state = try headState()
        let headFiles = try headFiles(state.id)
        let entries = try indexEntries()
        let index = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let work = try workingTree(tracked: entries)
        let paths = Set(headFiles.keys).union(index.keys).union(work.keys).sorted()
        let files = paths.compactMap { path -> GitFileStatus? in
            let staged = Self.change(from: headFiles[path], to: index[path])
            let unstaged = Self.change(from: index[path], to: work[path], untracked: index[path] == nil)
            guard staged != nil || unstaged != nil else { return nil }
            return .init(path: path, staged: staged, unstaged: unstaged)
        }
        return .init(head: try head(), files: files)
    }

    /// Stages exactly the specified paths, including deletions, without touching working files.
    public func stage(paths: [String]) throws {
        for path in paths { try GitIndex.validatePath(path) }
        let lock = try GitFileLock(metadataURL("index"))
        let entries = try indexEntries()
        var index = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let selected = Set(paths)
        let work = try workingTree(tracked: entries, storing: selected)
        for path in selected {
            guard index[path] != nil || work[path] != nil else { throw GitError.unsafeCheckoutPath(path) }
            index[path] = work[path]
        }
        try validateIndexPaths(Array(index.values))
        try lock.publish(GitIndex.encode(Array(index.values), algorithm: hashAlgorithm))
    }

    public func unstage(paths: [String]) throws {
        for path in paths { try GitIndex.validatePath(path) }
        let lock = try GitFileLock(metadataURL("index"))
        var index = Dictionary(uniqueKeysWithValues: try indexEntries().map { ($0.path, $0) })
        let original = try headFiles(headState().id)
        for path in Set(paths) { index[path] = original[path] }
        try validateIndexPaths(Array(index.values))
        try lock.publish(GitIndex.encode(Array(index.values), algorithm: hashAlgorithm))
    }

    /// A before/after pair from HEAD→index or index→working tree.
    public func comparison(path: String, staged: Bool) throws -> GitFileComparison {
        try GitIndex.validatePath(path)
        let index = try indexEntries().first { $0.path == path }
        let before = staged ? try headFiles(headState().id)[path] : index
        func bytes(_ entry: GitIndexEntry?) throws -> Data? {
            guard let entry else { return nil }
            if entry.mode == .gitlink { return Data("Subproject commit \(entry.id.hex)\n".utf8) }
            let object = try readObject(entry.id)
            guard object.kind == .blob else { throw GitError.malformedObject("index blob") }
            return object.body
        }
        let after: Data?
        let afterMode: GitFileMode?
        if staged { after = try bytes(index); afterMode = index?.mode }
        else if index?.mode == .gitlink { after = try bytes(index); afterMode = index?.mode }
        else { let content = try worktreeContent(path); after = content?.data; afterMode = content?.mode }
        return try .init(path: path, before: bytes(before), after: after, beforeMode: before?.mode, afterMode: afterMode)
    }

    func indexEntries() throws -> [GitIndexEntry] {
        guard let data = try optionalMetadata("index", limit: 32 * 1_024 * 1_024) else { return [] }
        let entries = try GitIndex.decode(data, algorithm: hashAlgorithm)
        try validateIndexPaths(entries)
        return entries
    }

    func headFiles(_ commit: GitObjectID?) throws -> [String: GitIndexEntry] {
        guard let commit else { return [:] }
        var files = [String: GitIndexEntry]()
        var visited = 0
        func visit(_ treeID: GitObjectID, base: String, depth: Int) throws {
            guard depth <= 256 else { throw GitError.resourceLimitExceeded("tree depth", 256) }
            let tree = try GitTree(object: readObject(treeID), algorithm: hashAlgorithm)
            for entry in tree.entries {
                try Task.checkCancellation()
                visited += 1
                guard visited <= 100_000 else { throw GitError.resourceLimitExceeded("tree entries", 100_000) }
                guard let name = String(data: entry.name, encoding: .utf8) else { throw GitError.unsupportedFeature("non-UTF-8 tree path") }
                let path = base.isEmpty ? name : base + "/" + name
                try GitIndex.validatePath(path)
                if entry.mode == .directory { try visit(entry.objectID, base: path, depth: depth + 1) }
                else { files[path] = .init(path: path, mode: entry.mode, id: entry.objectID, size: 0) }
            }
        }
        try visit(commitObject(commit).tree, base: "", depth: 0)
        return files
    }

    func validateIndexPaths(_ entries: [GitIndexEntry]) throws {
        let paths = Set(entries.map(\.path))
        var normalized = Set<String>()
        for entry in entries {
            try GitIndex.validatePath(entry.path)
            let key = entry.path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard normalized.insert(key).inserted else { throw GitError.unsafeCheckoutPath(entry.path) }
            var parts = entry.path.split(separator: "/")
            while parts.count > 1 {
                parts.removeLast()
                guard !paths.contains(parts.joined(separator: "/")) else { throw GitError.unsafeCheckoutPath(entry.path) }
            }
        }
    }

    private static func change(from old: GitIndexEntry?, to new: GitIndexEntry?, untracked: Bool = false) -> GitChangeKind? {
        if old == nil, new == nil { return nil }
        guard let old else { return untracked ? .untracked : .added }
        guard let new else { return .deleted }
        if old.matches(new) { return nil }
        if (old.mode == .symbolicLink) != (new.mode == .symbolicLink) || (old.mode == .gitlink) != (new.mode == .gitlink) { return .typeChanged }
        return .modified
    }
}
