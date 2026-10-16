//
//  GitChecksum.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import CSHA1DC
import CryptoKit
import Foundation

/// SHA1DC is an independent MIT-licensed cryptographic primitive, not Git C code.
struct GitChecksum {
    let algorithm: GitHashAlgorithm
    private var sha1 = SHA1_CTX()
    private var sha256 = SHA256()

    init(_ algorithm: GitHashAlgorithm) {
        self.algorithm = algorithm
        if algorithm == .sha1 { SHA1DCInit(&sha1) }
    }

    mutating func update(_ data: Data) {
        guard !data.isEmpty else { return }
        switch algorithm {
        case .sha1:
            data.withUnsafeBytes { bytes in
                SHA1DCUpdate(&sha1, bytes.bindMemory(to: CChar.self).baseAddress, data.count)
            }
        case .sha256: sha256.update(data: data)
        }
    }

    mutating func finalize() throws -> GitObjectID {
        let bytes: [UInt8]
        switch algorithm {
        case .sha1:
            var digest = [UInt8](repeating: 0, count: 20)
            guard SHA1DCFinal(&digest, &sha1) == 0 else { throw GitError.sha1Collision }
            bytes = digest
        case .sha256: bytes = Array(sha256.finalize())
        }
        return try GitObjectID(bytes: bytes, algorithm: algorithm)
    }
}

extension GitObject {
    func validatedID(using algorithm: GitHashAlgorithm) throws -> GitObjectID {
        var checksum = GitChecksum(algorithm)
        checksum.update(header)
        checksum.update(body)
        return try checksum.finalize()
    }
}
