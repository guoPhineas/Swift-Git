//
//  GitPackInstaller.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import CZlib
import Darwin
import Foundation

enum GitPackInstaller {
    static func install(_ url: URL, entries: [(id: GitObjectID, offset: Int)], in root: URL, algorithm: GitHashAlgorithm) throws {
        let reader = try GitFileReader(url, limit: Int(UInt32.max))
        let end = reader.size - algorithm.byteCount
        try reader.seek(to: end)
        let digest = try GitObjectID(bytes: Array(reader.read(algorithm.byteCount)), algorithm: algorithm)
        let ordered = entries.sorted { $0.offset < $1.offset }
        var crcs = [GitObjectID: UInt32]()
        for (position, entry) in ordered.enumerated() {
            try reader.seek(to: entry.offset)
            let next = position + 1 < ordered.count ? ordered[position + 1].offset : end
            var crc = crc32(0, nil, 0)
            while reader.offset < next {
                try Task.checkCancellation()
                let bytes = try reader.read(min(65_536, next - reader.offset))
                crc = bytes.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            }
            crcs[entry.id] = UInt32(truncatingIfNeeded: crc)
        }
        guard crcs.count == entries.count else { throw GitError.malformedObject("duplicate pack objects") }
        let byID = entries.sorted { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) }
        var index = Data([0xFF, 0x74, 0x4F, 0x63]); index.appendNetwork(2)
        var fanout = [UInt32](repeating: 0, count: 256)
        for entry in byID { fanout[Int(entry.id.bytes[0])] += 1 }
        var count: UInt32 = 0
        for value in fanout { count += value; index.appendNetwork(count) }
        for entry in byID { index.append(contentsOf: entry.id.bytes) }
        for entry in byID { index.appendNetwork(crcs[entry.id]!) }
        var large = [UInt64]()
        for entry in byID {
            if entry.offset < 0x80000000 { index.appendNetwork(UInt32(entry.offset)) }
            else { index.appendNetwork(0x80000000 | UInt32(large.count)); large.append(UInt64(entry.offset)) }
        }
        for value in large { index.appendNetwork(UInt32(value >> 32)); index.appendNetwork(UInt32(truncatingIfNeeded: value)) }
        index.append(contentsOf: digest.bytes)
        var hash = GitChecksum(algorithm); hash.update(index)
        index.append(contentsOf: try hash.finalize().bytes)
        let directory = root.appendingPathComponent(".git/objects/pack")
        try GitRepository.requireDirectory(directory)
        let destination = directory.appendingPathComponent("pack-\(digest.hex).pack")
        let indexURL = destination.deletingPathExtension().appendingPathExtension("idx")
        let temporaryPack = directory.appendingPathComponent("tmp-\(UUID().uuidString).pack")
        let temporaryIndex = directory.appendingPathComponent("tmp-\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(at: temporaryPack); try? FileManager.default.removeItem(at: temporaryIndex) }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: url, to: temporaryPack)
            guard link(temporaryPack.path, destination.path) == 0 || errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        if !FileManager.default.fileExists(atPath: indexURL.path) {
            try index.write(to: temporaryIndex, options: .withoutOverwriting)
            guard link(temporaryIndex.path, indexURL.path) == 0 || errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let installed = try GitPackIndex(GitRepository.readFile(indexURL, limit: 16 * 1_024 * 1_024), algorithm: algorithm)
        guard installed.packHash == digest, installed.count == entries.count else { throw GitError.objectHashMismatch }
        // A pre-existing filename is not proof of intact content. Clone may remove
        // redundant loose copies after this returns, so verify the installed pack.
        let published = try GitFileReader(destination, limit: Int(UInt32.max))
        guard published.size == reader.size else { throw GitError.objectHashMismatch }
        var verification = GitChecksum(algorithm)
        while published.offset < end { verification.update(try published.read(min(65_536, end - published.offset))) }
        guard try verification.finalize() == digest,
              try published.read(algorithm.byteCount) == Data(digest.bytes) else { throw GitError.objectHashMismatch }
    }
}
