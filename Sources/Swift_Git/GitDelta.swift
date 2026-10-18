//
//  GitDelta.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

enum GitDelta {
    static func apply(_ delta: Data, to base: Data, limit: Int, checkingCancellation: Bool = true) throws -> Data {
        var reader = GitByteReader(delta)
        let baseSize = try size(&reader)
        let resultSize = try size(&reader)
        guard baseSize == base.count else { throw GitError.malformedObject("delta base size") }
        guard resultSize <= limit else { throw GitError.sizeLimitExceeded(limit) }
        var result = Data()
        result.reserveCapacity(resultSize)
        while !reader.isAtEnd {
            if checkingCancellation { try Task.checkCancellation() }
            let opcode = try byte(&reader)
            if opcode & 0x80 == 0 {
                guard opcode != 0 else { throw GitError.malformedObject("zero delta instruction") }
                let count = Int(opcode)
                guard count <= resultSize - result.count else { throw GitError.malformedObject("delta output overflow") }
                result.append(try reader.read(count: count))
            } else {
                var offset = 0
                var length = 0
                for bit in 0..<4 where opcode & (1 << bit) != 0 {
                    offset |= Int(try byte(&reader)) << (8 * bit)
                }
                for bit in 0..<3 where opcode & (1 << (bit + 4)) != 0 {
                    length |= Int(try byte(&reader)) << (8 * bit)
                }
                if length == 0 { length = 65_536 }
                guard offset <= base.count, length <= base.count - offset,
                      length <= resultSize - result.count else { throw GitError.malformedObject("delta copy overflow") }
                let start = base.startIndex + offset
                result.append(base[start..<(start + length)])
            }
        }
        guard result.count == resultSize else { throw GitError.malformedObject("delta result size") }
        return result
    }

    private static func byte(_ reader: inout GitByteReader) throws -> UInt8 {
        try reader.read(count: 1).first!
    }

    private static func size(_ reader: inout GitByteReader) throws -> Int {
        var result: UInt64 = 0
        var shift = 0
        while true {
            let value = try byte(&reader)
            guard shift < 63, UInt64(value & 127) <= UInt64(Int.max) >> shift else {
                throw GitError.malformedObject("delta size overflow")
            }
            result |= UInt64(value & 127) << shift
            if value & 128 == 0 { return Int(result) }
            shift += 7
        }
    }
}
