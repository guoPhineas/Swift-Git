//
//  GitObject.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public enum GitObjectKind: String, Sendable, CaseIterable {
    case blob, tree, commit, tag
}

/// Raw bytes are retained, including unknown headers and non-UTF-8 content.
public struct GitObject: Sendable, Equatable {
    public let kind: GitObjectKind
    public let body: Data

    public init(kind: GitObjectKind, body: Data) {
        self.kind = kind
        self.body = body
    }

    var header: Data { Data("\(kind.rawValue) \(body.count)\0".utf8) }

    public func id(using algorithm: GitHashAlgorithm) -> GitObjectID {
        algorithm.hash(header: header, body: body)
    }

    public func encoded() -> Data {
        var result = header
        result.append(body)
        return result
    }

    public init(encoded: Data) throws {
        var reader = GitByteReader(encoded)
        let header = try reader.read(until: 0)
        guard let separator = header.firstIndex(of: 32),
              let kind = GitObjectKind(rawValue: String(decoding: header[..<separator], as: UTF8.self)) else {
            throw GitError.malformedObject("invalid type or header")
        }
        let sizeBytes = header[(separator + 1)...]
        guard !sizeBytes.isEmpty,
              sizeBytes.allSatisfy({ (48...57).contains($0) }),
              sizeBytes.count == 1 || sizeBytes.first != 48,
              let size = Int(String(decoding: sizeBytes, as: UTF8.self)),
              size == reader.remainingCount else {
            throw GitError.malformedObject("invalid size")
        }
        self.kind = kind
        body = try reader.read(count: size)
    }
}
