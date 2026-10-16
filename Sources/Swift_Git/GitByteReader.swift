//
//  GitByteReader.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

/// A bounded byte cursor. Slices share their Data storage until mutation.
struct GitByteReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }
    var remainingCount: Int { data.endIndex - offset }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, count <= remainingCount else { throw GitError.truncatedInput }
        let end = offset + count
        defer { offset = end }
        return data[offset..<end]
    }

    mutating func read(until delimiter: UInt8) throws -> Data {
        guard let end = data[offset...].firstIndex(of: delimiter) else { throw GitError.truncatedInput }
        defer { offset = end + 1 }
        return data[offset..<end]
    }
}
