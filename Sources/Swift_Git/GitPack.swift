//
//  GitPack.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

enum GitPack {
    private struct Resolved {
        let id: GitObjectID
        let depth: Int
        let kind: GitObjectKind
    }

    private enum Base {
        case offset(Int)
        case id(GitObjectID)
    }

    private struct Pending {
        let offset: Int
        let payloadOffset: Int
        let size: Int
        let base: Base
    }

    @concurrent
    static func unpack(_ url: URL, into repository: GitRepository, options: GitCloneOptions,
                       progress: GitCloneProgressHandler?) async throws -> Set<GitObjectID> {
        let algorithm = repository.hashAlgorithm
        let reader = try GitFileReader(url, limit: options.maximumDownloadBytes)
        guard reader.size >= 12 + algorithm.byteCount else { throw GitError.truncatedInput }
        try verifyChecksum(reader, algorithm: algorithm)
        try reader.seek(to: 0)
        guard try reader.read(4) == Data("PACK".utf8) else { throw GitError.malformedObject("pack signature") }
        let version = try reader.uint32()
        guard version == 2 || version == 3 else { throw GitError.unsupportedFeature("pack version \(version)") }
        let count = Int(try reader.uint32())
        guard count <= options.maximumObjects else { throw GitError.resourceLimitExceeded("object count", options.maximumObjects) }
        var resolvedByOffset = [Int: Resolved]()
        var resolvedByID = [GitObjectID: Resolved]()
        var pending = [Pending]()
        var references = [GitObjectID: GitObjectKind]()
        var expanded = 0
        var completed = 0

        func store(_ object: GitObject, offset: Int, depth: Int) async throws {
            guard depth <= options.maximumDeltaDepth else { throw GitError.resourceLimitExceeded("delta depth", options.maximumDeltaDepth) }
            guard object.body.count <= options.maximumExpandedBytes - expanded else {
                throw GitError.sizeLimitExceeded(options.maximumExpandedBytes)
            }
            expanded += object.body.count
            for link in try object.referencedObjectRequirements(using: algorithm, maximumReferences: options.maximumObjects,
                                                                maximumTreeEntries: options.maximumCheckoutFiles) {
                if let expected = references[link.id], expected != link.kind {
                    throw GitError.malformedObject("conflicting referenced object types")
                }
                references[link.id] = link.kind
                guard references.count <= count else { throw GitError.malformedObject("too many missing referenced objects") }
            }
            let id = try await repository.writeObject(object)
            let resolved = Resolved(id: id, depth: depth, kind: object.kind)
            resolvedByOffset[offset] = resolved
            resolvedByID[id] = resolved
            completed += 1
            if completed % 100 == 0 || completed == count {
                progress?(.init(stage: .unpacking, completed: Int64(completed), total: Int64(count)))
            }
        }

        for _ in 0..<count {
            try Task.checkCancellation()
            let offset = reader.offset
            let first = try reader.byte()
            let type = (first >> 4) & 7
            var size = Int(first & 15)
            var shift = 4
            var byte = first
            while byte & 128 != 0 {
                byte = try reader.byte()
                guard shift < 63, Int(byte & 127) <= options.maximumObjectBytes >> shift else {
                    throw GitError.sizeLimitExceeded(options.maximumObjectBytes)
                }
                size |= Int(byte & 127) << shift
                shift += 7
            }
            guard size <= options.maximumObjectBytes else { throw GitError.sizeLimitExceeded(options.maximumObjectBytes) }
            let base: Base?
            switch type {
            case 6:
                var byte = try reader.byte()
                var distance = Int(byte & 127)
                while byte & 128 != 0 {
                    byte = try reader.byte()
                    guard distance < (Int.max >> 7) - 1 else { throw GitError.malformedObject("delta distance overflow") }
                    distance = ((distance + 1) << 7) | Int(byte & 127)
                }
                guard distance > 0, distance <= offset - 12 else { throw GitError.malformedObject("delta base offset") }
                base = .offset(offset - distance)
            case 7: base = .id(try GitObjectID(bytes: Array(reader.read(algorithm.byteCount)), algorithm: algorithm))
            case 1...4: base = nil
            default: throw GitError.malformedObject("pack object type")
            }
            let payloadOffset = reader.offset
            let payload = try GitZlib.decompress(from: reader, expectedSize: size, limit: options.maximumObjectBytes)
            if let base {
                pending.append(Pending(offset: offset, payloadOffset: payloadOffset, size: size, base: base))
            } else {
                let kinds: [UInt8: GitObjectKind] = [1: .commit, 2: .tree, 3: .blob, 4: .tag]
                guard let kind = kinds[type] else { throw GitError.malformedObject("pack object type") }
                try await store(GitObject(kind: kind, body: payload), offset: offset, depth: 0)
            }
        }
        guard reader.offset == reader.size - algorithm.byteCount else { throw GitError.malformedObject("pack object count or trailing data") }

        while !pending.isEmpty {
            var unresolved = [Pending]()
            let previousCount = pending.count
            for entry in pending {
                try Task.checkCancellation()
                let base: Resolved?
                switch entry.base {
                case .offset(let offset): base = resolvedByOffset[offset]
                case .id(let id): base = resolvedByID[id]
                }
                guard let base else { unresolved.append(entry); continue }
                guard base.depth < options.maximumDeltaDepth else { throw GitError.resourceLimitExceeded("delta depth", options.maximumDeltaDepth) }
                let object = try await repository.readObject(base.id)
                try reader.seek(to: entry.payloadOffset)
                let delta = try GitZlib.decompress(from: reader, expectedSize: entry.size, limit: options.maximumObjectBytes)
                let body = try GitDelta.apply(delta, to: object.body, limit: options.maximumObjectBytes)
                try await store(GitObject(kind: object.kind, body: body), offset: entry.offset, depth: base.depth + 1)
            }
            guard unresolved.count < previousCount else { throw GitError.malformedObject("missing or cyclic delta base") }
            pending = unresolved
        }
        let ids = Set(resolvedByID.keys)
        for (id, kind) in references {
            guard resolvedByID[id]?.kind == kind else { throw GitError.malformedObject("missing or mistyped referenced object") }
        }
        return ids
    }

    private static func verifyChecksum(_ reader: GitFileReader, algorithm: GitHashAlgorithm) throws {
        var checksum = GitChecksum(algorithm)
        let end = reader.size - algorithm.byteCount
        while reader.offset < end {
            try Task.checkCancellation()
            checksum.update(try reader.read(min(65_536, end - reader.offset)))
        }
        let expected = try GitObjectID(bytes: Array(reader.read(algorithm.byteCount)), algorithm: algorithm)
        guard try checksum.finalize() == expected else { throw GitError.objectHashMismatch }
    }
}

extension GitObject {
    struct ReferenceRequirement {
        let id: GitObjectID
        let kind: GitObjectKind
    }

    func referencedObjects(using algorithm: GitHashAlgorithm) throws -> [GitObjectID] {
        try referencedObjectRequirements(using: algorithm).map(\.id)
    }

    func referencedObjectRequirements(using algorithm: GitHashAlgorithm, maximumReferences: Int = 250_000,
                                     maximumTreeEntries: Int = 100_000) throws -> [ReferenceRequirement] {
        switch kind {
        case .blob: return []
        case .tree:
            // A gitlink points into a different repository and is not part of this pack.
            return try GitTree(object: self, algorithm: algorithm, maximumEntries: maximumTreeEntries).entries.filter { $0.mode != .gitlink }.map {
                ReferenceRequirement(id: $0.objectID, kind: $0.mode == .directory ? .tree : .blob)
            }
        case .commit, .tag:
            var result = [GitObjectID]()
            var reader = GitByteReader(body)
            let required = kind == .commit ? "tree" : "object"
            var foundRequired = false
            var tagType: GitObjectKind?
            var first = true
            while !reader.isAtEnd {
                try Task.checkCancellation()
                let line = try reader.read(until: 10)
                if line.isEmpty { break }
                if line.first == 32 { continue }
                guard let separator = line.firstIndex(of: 32) else { throw GitError.malformedObject("object header") }
                let key = String(decoding: line[..<separator], as: UTF8.self)
                if first, key != required { throw GitError.malformedObject("missing \(required) header") }
                first = false
                if key == required || (kind == .commit && key == "parent") {
                    guard result.count < maximumReferences else { throw GitError.resourceLimitExceeded("object reference count", maximumReferences) }
                    if key == required {
                        guard !foundRequired else { throw GitError.malformedObject("duplicate \(required) header") }
                        foundRequired = true
                    }
                    result.append(try GitObjectID(hex: String(decoding: line[(separator + 1)...], as: UTF8.self), algorithm: algorithm))
                } else if kind == .tag, key == "type" {
                    guard tagType == nil, let type = GitObjectKind(rawValue: String(decoding: line[(separator + 1)...], as: UTF8.self)) else {
                        throw GitError.malformedObject("invalid tag target type")
                    }
                    tagType = type
                }
            }
            guard foundRequired else { throw GitError.malformedObject("missing \(required) header") }
            if kind == .tag {
                guard let tagType else { throw GitError.malformedObject("missing tag target type") }
                return result.map { ReferenceRequirement(id: $0, kind: tagType) }
            }
            return result.enumerated().map { ReferenceRequirement(id: $0.element, kind: $0.offset == 0 ? .tree : .commit) }
        }
    }
}
