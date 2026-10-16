//
//  ObjectTests.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Testing
@testable import Swift_Git

@Test func knownObjectIDs() throws {
    #expect(GitObject(kind: .blob, body: Data()).id(using: .sha1).hex == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    #expect(GitObject(kind: .tree, body: Data()).id(using: .sha1).hex == "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    let hex = String(repeating: "AB", count: 32)
    #expect(try GitObjectID(hex: hex, algorithm: .sha256).hex == hex.lowercased())
    #expect(throws: GitError.invalidObjectID) { try GitObjectID(hex: hex, algorithm: .sha1) }
    #expect(throws: GitError.invalidObjectID) { try GitObjectID(hex: String(repeating: "zz", count: 20), algorithm: .sha1) }
}

@Test(arguments: GitObjectKind.allCases)
func binaryObjectRoundTrip(kind: GitObjectKind) throws {
    let object = GitObject(kind: kind, body: Data([0, 255, 128, 10, 13]))
    #expect(try GitObject(encoded: object.encoded()) == object)
}

@Test(arguments: ["blob -1\0", "blob 01\0x", "blob 2\0x", "blob 0\0x", "blob 9999999999999999999999999\0", "invalid 0\0", "blob 0"])
func invalidObjectHeaders(input: String) {
    #expect(throws: (any Error).self) { try GitObject(encoded: Data(input.utf8)) }
}

@Test(arguments: [0, 1, 16_384, 65_537, 1_048_576])
func compressionRoundTrip(count: Int) throws {
    let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
    let compressed = try GitZlib.compress(bytes)
    #expect(try GitZlib.decompress(compressed, limit: count) == bytes)
    if count > 0 {
        #expect(throws: GitError.sizeLimitExceeded(count - 1)) {
            try GitZlib.decompress(compressed, limit: count - 1)
        }
    }
    #expect(throws: (any Error).self) { try GitZlib.decompress(compressed.dropLast(), limit: count) }
    #expect(throws: (any Error).self) { try GitZlib.decompress(compressed + Data([0]), limit: count) }
}

@Test func treeOrderingAndByteNames() throws {
    let id = GitObject(kind: .blob, body: Data()).id(using: .sha1)
    let directory = try GitTreeEntry(mode: .directory, name: Data("foo".utf8), objectID: id)
    let file = try GitTreeEntry(mode: .regular, name: Data("foo.bar".utf8), objectID: id)
    let binaryName = try GitTreeEntry(mode: .regular, name: Data([255]), objectID: id)
    let tree = try GitTree(entries: [binaryName, directory, file])
    #expect(tree.entries.map(\.name) == [file.name, directory.name, binaryName.name])
    #expect(try GitTree(object: tree.object(using: .sha1), algorithm: .sha1) == tree)
    #expect(throws: (any Error).self) { try GitTree(entries: [file, file]) }
    #expect(throws: (any Error).self) { try GitTreeEntry(mode: .regular, name: Data("../x".utf8), objectID: id) }
    #expect(throws: GitError.invalidObjectID) { try tree.object(using: .sha256) }
}

@Test func byteCursorUsesSliceIndices() throws {
    let data = Data([9, 1, 2, 0, 3]).dropFirst()
    var reader = GitByteReader(data)
    #expect(try reader.read(until: 0) == Data([1, 2]))
    #expect(try reader.read(count: 1) == Data([3]))
    #expect(reader.isAtEnd)
    #expect(throws: GitError.truncatedInput) { try reader.read(count: -1) }
    #expect(throws: GitError.truncatedInput) { try reader.read(count: 1) }
}

@Test(arguments: ["refs/heads/../x", "refs/heads/a.lock", "refs/heads/a@{b", "refs/heads/a b", "refs//x", "refs/heads/.x", "refs/heads/x.", "refs/heads/a\\b"])
func invalidReferences(name: String) {
    #expect(throws: (any Error).self) { try GitReferenceName(name) }
}
