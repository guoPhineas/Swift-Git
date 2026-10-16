//
//  GitZlib.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import CZlib
import Foundation

enum GitZlib {
    static func compress(_ input: Data) throws -> Data {
        guard input.count <= Int(UInt32.max) else { throw GitError.sizeLimitExceeded(Int(UInt32.max)) }
        var length = compressBound(uLong(input.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &length,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw GitError.compression(status) }
        output.count = Int(length)
        return output
    }

    static func decompress(_ input: Data, limit: Int) throws -> Data {
        guard limit >= 0 else { throw GitError.sizeLimitExceeded(limit) }
        guard input.count <= Int(UInt32.max) else { throw GitError.sizeLimitExceeded(Int(UInt32.max)) }
        var stream = z_stream()
        let initialized = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw GitError.compression(initialized) }
        defer { inflateEnd(&stream) }

        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            defer { stream.next_in = nil; stream.next_out = nil }
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while true {
                try Task.checkCancellation()
                let (status, written) = chunk.withUnsafeMutableBytes { buffer -> (Int32, Int) in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    stream.next_out = nil
                    return (status, buffer.count - Int(stream.avail_out))
                }
                guard written <= limit - output.count else { throw GitError.sizeLimitExceeded(limit) }
                output.append(contentsOf: chunk.prefix(written))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw GitError.malformedObject("trailing zlib data") }
                    return output
                }
                guard status == Z_OK, written > 0 || stream.avail_in > 0 else {
                    throw GitError.compression(status)
                }
            }
        }
    }
}
