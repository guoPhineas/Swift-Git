//
//  GitObjectID.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import CryptoKit
import Foundation

public enum GitHashAlgorithm: String, Sendable, CaseIterable {
    case sha1
    case sha256

    public var byteCount: Int { self == .sha1 ? 20 : 32 }
}

public struct GitObjectID: Hashable, Sendable, CustomStringConvertible {
    public let algorithm: GitHashAlgorithm
    public let bytes: [UInt8]

    public init(bytes: [UInt8], algorithm: GitHashAlgorithm) throws {
        guard bytes.count == algorithm.byteCount else { throw GitError.invalidObjectID }
        self.algorithm = algorithm
        self.bytes = bytes
    }

    public init(hex: String, algorithm: GitHashAlgorithm) throws {
        let characters = Array(hex.utf8)
        guard characters.count == algorithm.byteCount * 2 else { throw GitError.invalidObjectID }
        var bytes = [UInt8]()
        bytes.reserveCapacity(algorithm.byteCount)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = Self.nibble(characters[index]),
                  let low = Self.nibble(characters[index + 1]) else { throw GitError.invalidObjectID }
            bytes.append(high << 4 | low)
        }
        try self.init(bytes: bytes, algorithm: algorithm)
    }

    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 15)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    public var description: String { hex }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}

extension GitHashAlgorithm {
    func hash(header: Data, body: Data) -> GitObjectID {
        let bytes: [UInt8]
        switch self {
        case .sha1:
            // CryptoKit SHA-1 provides format compatibility, not Git's SHA1DC protection.
            var hash = Insecure.SHA1()
            hash.update(data: header)
            hash.update(data: body)
            bytes = Array(hash.finalize())
        case .sha256:
            var hash = SHA256()
            hash.update(data: header)
            hash.update(data: body)
            bytes = Array(hash.finalize())
        }
        // Digest lengths are fixed by CryptoKit; this initializer does not parse external data.
        return GitObjectID(digest: bytes, algorithm: self)
    }
}

extension GitObjectID {
    fileprivate init(digest: [UInt8], algorithm: GitHashAlgorithm) {
        self.algorithm = algorithm
        self.bytes = digest
    }
}
