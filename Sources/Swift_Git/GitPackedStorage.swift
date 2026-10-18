//
//  GitPackedStorage.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

struct GitPackIndex {
    let data: Data
    let count: Int
    let algorithm: GitHashAlgorithm
    let packHash: GitObjectID
    let namesStart: Int
    let offsetsStart: Int
    let largeOffsetsStart: Int
    let version: Int

    init(_ data: Data, algorithm: GitHashAlgorithm) throws {
        guard data.count >= 1024 + 2 * algorithm.byteCount else { throw GitError.truncatedInput }
        var hash = GitChecksum(algorithm)
        hash.update(data.dropLast(algorithm.byteCount))
        guard try hash.finalize().bytes == Array(data.suffix(algorithm.byteCount)) else { throw GitError.objectHashMismatch }
        var reader = GitByteReader(data)
        let first = try reader.networkUInt32()
        let version: Int
        if first == 0xFF744F63 {
            guard try reader.networkUInt32() == 2 else { throw GitError.unsupportedFeature("pack index version") }
            version = 2
        } else { version = 1; reader = GitByteReader(data) }
        var previous: UInt32 = 0
        for _ in 0..<256 {
            let value = try reader.networkUInt32()
            guard value >= previous else { throw GitError.malformedObject("pack index fanout") }
            previous = value
        }
        let count = Int(previous)
        guard count <= 250_000 else { throw GitError.resourceLimitExceeded("pack index entries", 250_000) }
        let namesStart = reader.offset
        let offsetsStart: Int, largeOffsetsStart: Int
        if version == 2 {
            offsetsStart = namesStart + count * algorithm.byteCount + count * 4
            largeOffsetsStart = offsetsStart + count * 4
            guard largeOffsetsStart + 2 * algorithm.byteCount <= data.count else { throw GitError.truncatedInput }
        } else {
            offsetsStart = namesStart
            largeOffsetsStart = namesStart + count * (4 + algorithm.byteCount)
            guard largeOffsetsStart + 2 * algorithm.byteCount == data.count else { throw GitError.malformedObject("pack index length") }
        }
        self.data = data; self.count = count; self.algorithm = algorithm
        self.namesStart = namesStart; self.offsetsStart = offsetsStart; self.largeOffsetsStart = largeOffsetsStart; self.version = version
        packHash = try .init(bytes: Array(data[(data.count - 2 * algorithm.byteCount)..<(data.count - algorithm.byteCount)]), algorithm: algorithm)
        var previousName: Data?
        for index in 0..<count {
            let name = name(at: index)
            if let previousName, !previousName.lexicographicallyPrecedes(name) { throw GitError.malformedObject("pack index ordering") }
            previousName = name
        }
    }

    func offset(of id: GitObjectID) throws -> Int? {
        let sought = Data(id.bytes)
        var low = 0, high = count
        while low < high {
            let middle = low + (high - low) / 2
            if name(at: middle).lexicographicallyPrecedes(sought) { low = middle + 1 } else { high = middle }
        }
        guard low < count, name(at: low) == sought else { return nil }
        let start = version == 2 ? offsetsStart + low * 4 : namesStart + low * (4 + algorithm.byteCount)
        let value = data[start..<(start + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        if version == 1 || value & 0x80000000 == 0 { return Int(value) }
        let index = Int(value & 0x7FFFFFFF)
        let location = largeOffsetsStart + index * 8
        guard location + 8 <= data.count - 2 * algorithm.byteCount else { throw GitError.truncatedInput }
        let large = data[location..<(location + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard large <= Int.max else { throw GitError.sizeLimitExceeded(Int.max) }
        return Int(large)
    }

    private func name(at index: Int) -> Data {
        let start = version == 2 ? namesStart + index * algorithm.byteCount : namesStart + index * (4 + algorithm.byteCount) + 4
        return data[start..<(start + algorithm.byteCount)]
    }
}

struct GitCachedPack {
    let index: GitPackIndex
    let indexModified: Date?
    let indexSize: Int?
    let packModified: Date?
    let packSize: Int?
}

extension GitRepository {
    func readPackedObject(_ id: GitObjectID, depth: Int, ancestors: Set<GitObjectID>) throws -> GitObject? {
        guard depth <= 128, !ancestors.contains(id) else { throw GitError.malformedObject("cyclic or deep pack delta") }
        let directory = gitDirectory.appendingPathComponent("objects/pack")
        try Self.requireDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("pack-") && $0.pathExtension == "idx" }.sorted { $0.path < $1.path }
        for url in files {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let pack = url.deletingPathExtension().appendingPathExtension("pack")
            let packValues = try pack.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let cached: GitCachedPack
            if let current = packedIndexes[url], current.indexModified == values.contentModificationDate, current.indexSize == values.fileSize,
               current.packModified == packValues.contentModificationDate, current.packSize == packValues.fileSize { cached = current }
            else {
                let index = try GitPackIndex(Self.readFile(url, limit: 16 * 1_024 * 1_024), algorithm: hashAlgorithm)
                let reader = try GitFileReader(pack, limit: Int(UInt32.max), checksCancellation: !ignoresTransactionCancellation)
                guard reader.size >= 12 + hashAlgorithm.byteCount, try reader.read(4) == Data("PACK".utf8) else { throw GitError.malformedObject("pack signature") }
                let version = try reader.uint32()
                guard version == 2 || version == 3, try reader.uint32() == UInt32(index.count) else { throw GitError.malformedObject("pack count or version") }
                try reader.seek(to: 0)
                var hash = GitChecksum(hashAlgorithm)
                while reader.offset < reader.size - hashAlgorithm.byteCount {
                    if !ignoresTransactionCancellation { try Task.checkCancellation() }
                    hash.update(try reader.read(min(65_536, reader.size - hashAlgorithm.byteCount - reader.offset)))
                }
                guard try hash.finalize() == index.packHash,
                      try Array(reader.read(hashAlgorithm.byteCount)) == index.packHash.bytes else { throw GitError.objectHashMismatch }
                cached = .init(index: index, indexModified: values.contentModificationDate, indexSize: values.fileSize,
                               packModified: packValues.contentModificationDate, packSize: packValues.fileSize)
                if packedIndexes.count >= 4 { packedIndexes.removeAll(keepingCapacity: true) }
                packedIndexes[url] = cached
            }
            guard let offset = try cached.index.offset(of: id) else { continue }
            var chain = ancestors; chain.insert(id)
            let object = try packedObject(at: offset, in: pack, depth: depth, ancestors: chain)
            guard try object.validatedID(using: hashAlgorithm) == id else { throw GitError.objectHashMismatch }
            return object
        }
        return nil
    }

    private func packedObject(at offset: Int, in url: URL, depth: Int, ancestors: Set<GitObjectID>) throws -> GitObject {
        guard depth <= 128, offset >= 12 else { throw GitError.malformedObject("pack delta depth or offset") }
        let reader = try GitFileReader(url, limit: Int(UInt32.max), checksCancellation: !ignoresTransactionCancellation)
        guard offset < reader.size - hashAlgorithm.byteCount else { throw GitError.truncatedInput }
        try reader.seek(to: offset)
        let first = try reader.byte(), kind = (first >> 4) & 7
        var size = Int(first & 15), shift = 4, byte = first
        while byte & 128 != 0 {
            byte = try reader.byte()
            guard shift < 63, Int(byte & 127) <= maximumObjectBytes >> shift else { throw GitError.sizeLimitExceeded(maximumObjectBytes) }
            size |= Int(byte & 127) << shift; shift += 7
        }
        guard size <= maximumObjectBytes else { throw GitError.sizeLimitExceeded(maximumObjectBytes) }
        var base: GitObject?
        switch kind {
        case 6:
            var byte = try reader.byte(), distance = Int(byte & 127)
            while byte & 128 != 0 {
                byte = try reader.byte()
                guard distance < (Int.max >> 7) - 1 else { throw GitError.malformedObject("delta distance") }
                distance = ((distance + 1) << 7) | Int(byte & 127)
            }
            guard distance > 0, distance <= offset - 12 else { throw GitError.malformedObject("delta offset") }
            base = try packedObject(at: offset - distance, in: url, depth: depth + 1, ancestors: ancestors)
        case 7:
            let id = try GitObjectID(bytes: Array(reader.read(hashAlgorithm.byteCount)), algorithm: hashAlgorithm)
            base = try readStoredObject(id, depth: depth + 1, ancestors: ancestors)
        case 1...4: break
        default: throw GitError.malformedObject("packed object type")
        }
        let payload = try GitZlib.decompress(from: reader, expectedSize: size, limit: maximumObjectBytes)
        if let base { return try .init(kind: base.kind, body: GitDelta.apply(payload, to: base.body, limit: maximumObjectBytes, checkingCancellation: !ignoresTransactionCancellation)) }
        let kinds: [UInt8: GitObjectKind] = [1: .commit, 2: .tree, 3: .blob, 4: .tag]
        return .init(kind: kinds[kind]!, body: payload)
    }
}
