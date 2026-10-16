//
//  GitIndex.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Darwin
import Foundation

struct GitIndexEntry: Sendable, Equatable {
    let path: String
    let mode: GitFileMode
    let id: GitObjectID
    let size: Int

    func matches(_ other: Self?) -> Bool { other?.mode == mode && other?.id == id }
}

enum GitIndex {
    static func decode(_ data: Data, algorithm: GitHashAlgorithm) throws -> [GitIndexEntry] {
        guard data.count >= 12 + algorithm.byteCount else { throw GitError.truncatedInput }
        let payload = Data(data.dropLast(algorithm.byteCount))
        var hash = GitChecksum(algorithm)
        hash.update(payload)
        guard try hash.finalize().bytes == Array(data.suffix(algorithm.byteCount)) else { throw GitError.objectHashMismatch }
        var reader = GitByteReader(payload)
        guard try reader.read(count: 4) == Data("DIRC".utf8) else { throw GitError.malformedObject("index signature") }
        let version = try reader.networkUInt32()
        guard version == 2 || version == 3 else { throw GitError.unsupportedFeature("index version \(version)") }
        let count = Int(try reader.networkUInt32())
        guard count <= 100_000 else { throw GitError.resourceLimitExceeded("index entries", 100_000) }
        var entries = [GitIndexEntry]()
        for _ in 0..<count {
            try Task.checkCancellation()
            let start = reader.offset
            _ = try reader.read(count: 24)
            guard let mode = GitFileMode(rawValue: String(try reader.networkUInt32(), radix: 8)), mode != .directory else {
                throw GitError.malformedObject("index mode")
            }
            _ = try reader.read(count: 8)
            let size = Int(try reader.networkUInt32())
            let id = try GitObjectID(bytes: Array(reader.read(count: algorithm.byteCount)), algorithm: algorithm)
            let flags = try reader.read(count: 2).reduce(0) { $0 << 8 | Int($1) }
            guard flags & 0x7000 == 0 else { throw GitError.unsupportedFeature("conflicted or extended index entries") }
            guard let path = String(data: try reader.read(until: 0), encoding: .utf8) else {
                throw GitError.unsupportedFeature("non-UTF-8 index path")
            }
            try validatePath(path)
            guard flags & 0xFFF == min(path.utf8.count, 0xFFF) else { throw GitError.malformedObject("index name length") }
            let padding = (8 - (reader.offset - start) % 8) % 8
            guard try reader.read(count: padding).allSatisfy({ $0 == 0 }) else { throw GitError.malformedObject("index padding") }
            if let previous = entries.last, !Data(previous.path.utf8).lexicographicallyPrecedes(Data(path.utf8)) {
                throw GitError.malformedObject("unsorted or duplicate index path")
            }
            entries.append(.init(path: path, mode: mode, id: id, size: size))
        }
        while !reader.isAtEnd {
            let signature = try reader.read(count: 4)
            guard let first = signature.first, (65...90).contains(first) else {
                throw GitError.unsupportedFeature("mandatory index extension")
            }
            _ = try reader.read(count: Int(reader.networkUInt32()))
        }
        return entries
    }

    static func encode(_ entries: [GitIndexEntry], algorithm: GitHashAlgorithm) throws -> Data {
        guard entries.count <= 100_000 else { throw GitError.resourceLimitExceeded("index entries", 100_000) }
        var data = Data("DIRC".utf8)
        data.appendNetwork(2)
        data.appendNetwork(UInt32(entries.count))
        for entry in entries.sorted(by: { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }) {
            try Task.checkCancellation()
            try validatePath(entry.path)
            let start = data.count
            for _ in 0..<6 { data.appendNetwork(0) }
            guard let mode = UInt32(entry.mode.rawValue, radix: 8) else { throw GitError.malformedObject("index mode") }
            data.appendNetwork(mode)
            data.appendNetwork(0)
            data.appendNetwork(0)
            data.appendNetwork(UInt32(truncatingIfNeeded: entry.size))
            data.append(contentsOf: entry.id.bytes)
            let length = min(entry.path.utf8.count, 0xFFF)
            data.append(UInt8(length >> 8))
            data.append(UInt8(length & 255))
            data.append(contentsOf: entry.path.utf8)
            data.append(0)
            while (data.count - start) % 8 != 0 { data.append(0) }
        }
        var hash = GitChecksum(algorithm)
        hash.update(data)
        data.append(contentsOf: try hash.finalize().bytes)
        return data
    }

    static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 4096, components.count <= 256,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
                  && !$0.contains(":") && !$0.contains("\\") && !$0.utf8.contains(0) }) else {
            throw GitError.unsafeCheckoutPath(path)
        }
    }
}

extension GitByteReader {
    mutating func networkUInt32() throws -> UInt32 {
        try read(count: 4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Git's exclusive lock-file publication convention, shared with other clients.
final class GitFileLock {
    private let destination: URL
    private let lockURL: URL
    private let file: FileHandle
    private var published = false

    init(_ destination: URL) throws {
        self.destination = destination
        lockURL = destination.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw GitError.repositoryBusy }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func publish(_ data: Data) throws {
        try Task.checkCancellation()
        try file.write(contentsOf: data)
        try file.synchronize()
        guard rename(lockURL.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        published = true
    }

    deinit {
        try? file.close()
        if !published { try? FileManager.default.removeItem(at: lockURL) }
    }
}
