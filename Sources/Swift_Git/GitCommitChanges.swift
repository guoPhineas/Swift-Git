//
//  GitCommitChanges.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public struct GitCommitFileChange: Identifiable, Sendable {
    public let path: String
    public let kind: GitChangeKind
    public var id: String { path }
}

extension GitRepository {
    public func changes(in commit: GitObjectID, parent: Int = 0) throws -> [GitCommitFileChange] {
        let object = try commitObject(commit)
        guard parent >= 0, parent < max(1, object.parents.count) else { throw GitError.malformedObject("parent selection") }
        let before = try headFiles(object.parents.isEmpty ? nil : object.parents[parent])
        let after = try headFiles(commit)
        return Set(before.keys).union(after.keys).sorted().compactMap { path in
            let old = before[path], new = after[path]
            if let old, old.matches(new) { return nil }
            let kind: GitChangeKind
            if old == nil { kind = .added }
            else if new == nil { kind = .deleted }
            else if (old?.mode == .symbolicLink) != (new?.mode == .symbolicLink) { kind = .typeChanged }
            else { kind = .modified }
            return .init(path: path, kind: kind)
        }
    }

    public func comparison(in commit: GitObjectID, path: String, parent: Int = 0) throws -> GitFileComparison {
        try GitIndex.validatePath(path)
        let object = try commitObject(commit)
        guard parent >= 0, parent < max(1, object.parents.count) else { throw GitError.malformedObject("parent selection") }
        let before = try headFiles(object.parents.isEmpty ? nil : object.parents[parent])[path]
        let after = try headFiles(commit)[path]
        func bytes(_ entry: GitIndexEntry?) throws -> Data? {
            guard let entry else { return nil }
            if entry.mode == .gitlink { return Data("Subproject commit \(entry.id.hex)\n".utf8) }
            let object = try readObject(entry.id)
            guard object.kind == .blob else { throw GitError.malformedObject("commit file is not a blob") }
            return object.body
        }
        return try .init(path: path, before: bytes(before), after: bytes(after), beforeMode: before?.mode, afterMode: after?.mode)
    }
}
