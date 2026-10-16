//
//  GitTree.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public enum GitFileMode: String, Sendable {
    case directory = "40000"
    case regular = "100644"
    case executable = "100755"
    case symbolicLink = "120000"
    case gitlink = "160000"
}

public struct GitTreeEntry: Sendable, Equatable {
    public let mode: GitFileMode
    public let name: Data
    public let objectID: GitObjectID

    public init(mode: GitFileMode, name: Data, objectID: GitObjectID) throws {
        guard !name.isEmpty, !name.contains(0), !name.contains(47),
              name != Data(".".utf8), name != Data("..".utf8) else {
            throw GitError.malformedObject("invalid tree entry name")
        }
        self.mode = mode
        self.name = name
        self.objectID = objectID
    }

    var sortKey: Data {
        var key = name
        key.append(mode == .directory ? 47 : 0)
        return key
    }
}

public struct GitTree: Sendable, Equatable {
    public let entries: [GitTreeEntry]

    public init(entries: [GitTreeEntry]) throws {
        guard Set(entries.map(\.name)).count == entries.count else {
            throw GitError.malformedObject("duplicate tree entry")
        }
        self.entries = entries.sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }
    }

    public init(object: GitObject, algorithm: GitHashAlgorithm, maximumEntries: Int = 100_000) throws {
        guard object.kind == .tree else { throw GitError.malformedObject("expected tree") }
        var reader = GitByteReader(object.body)
        var entries = [GitTreeEntry]()
        while !reader.isAtEnd {
            try Task.checkCancellation()
            guard entries.count < maximumEntries else { throw GitError.resourceLimitExceeded("tree entry count", maximumEntries) }
            let modeBytes = try reader.read(until: 32)
            guard let mode = GitFileMode(rawValue: String(decoding: modeBytes, as: UTF8.self)) else {
                throw GitError.malformedObject("invalid tree mode")
            }
            let name = try reader.read(until: 0)
            let id = try GitObjectID(bytes: Array(reader.read(count: algorithm.byteCount)), algorithm: algorithm)
            entries.append(try GitTreeEntry(mode: mode, name: name, objectID: id))
        }
        try self.init(entries: entries)
        guard self.entries == entries else { throw GitError.malformedObject("unsorted tree") }
    }

    public func object(using algorithm: GitHashAlgorithm) throws -> GitObject {
        var body = Data()
        for entry in entries {
            guard entry.objectID.algorithm == algorithm else { throw GitError.invalidObjectID }
            body.append(contentsOf: entry.mode.rawValue.utf8)
            body.append(32)
            body.append(entry.name)
            body.append(0)
            body.append(contentsOf: entry.objectID.bytes)
        }
        return GitObject(kind: .tree, body: body)
    }
}
