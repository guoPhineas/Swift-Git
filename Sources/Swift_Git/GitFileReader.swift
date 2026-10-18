//
//  GitFileReader.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Darwin

/// A task-owned, buffered reader; never shared across concurrent tasks.
final class GitFileReader {
    private let file: FileHandle
    let size: Int
    let checksCancellation: Bool
    private(set) var offset = 0
    private var buffer = Data()
    private var bufferStart = 0
    private var index = 0

    init(_ url: URL, limit: Int, checksCancellation: Bool = true) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw GitError.malformedObject("expected regular pack file") }
        guard info.st_size >= 0, info.st_size <= limit else { throw GitError.sizeLimitExceeded(limit) }
        size = Int(info.st_size)
        file = handle
        self.checksCancellation = checksCancellation
    }

    deinit { try? file.close() }

    func seek(to offset: Int) throws {
        guard offset >= 0, offset <= size else { throw GitError.truncatedInput }
        self.offset = offset
        if offset >= bufferStart, offset <= bufferStart + buffer.count {
            index = offset - bufferStart
        } else {
            buffer = Data()
            index = 0
            bufferStart = offset
            try file.seek(toOffset: UInt64(offset))
        }
    }

    func peek() throws -> Data {
        if index == buffer.count {
            if checksCancellation { try Task.checkCancellation() }
            try file.seek(toOffset: UInt64(offset))
            buffer = try file.read(upToCount: 65_536) ?? Data()
            bufferStart = offset
            index = 0
        }
        return buffer[index...]
    }

    func advance(_ count: Int) throws {
        guard count >= 0, count <= buffer.count - index else { throw GitError.truncatedInput }
        index += count
        offset += count
    }

    func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= size - offset else { throw GitError.truncatedInput }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try peek()
            guard !chunk.isEmpty else { throw GitError.truncatedInput }
            let length = min(count - result.count, chunk.count)
            result.append(chunk.prefix(length))
            try advance(length)
        }
        return result
    }

    func byte() throws -> UInt8 {
        let bytes = try peek()
        guard let byte = bytes.first else { throw GitError.truncatedInput }
        try advance(1)
        return byte
    }

    func uint32() throws -> UInt32 {
        try read(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
