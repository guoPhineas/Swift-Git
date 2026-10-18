//
//  GitReferences.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public struct GitBranch: Sendable, Identifiable {
    public let name: String
    public let reference: String
    public let idValue: GitObjectID
    public let isRemote: Bool
    public let isCurrent: Bool
    public var id: String { reference }
}

extension GitRepository {
    func referenceNames() throws -> [String] {
        var names = Set<String>()
        if let packed = try optionalMetadata("packed-refs", limit: 16 * 1_024 * 1_024) {
            for line in String(decoding: packed, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2 else { throw GitError.malformedObject("packed refs") }
                let name = String(fields[1]); _ = try GitReferenceName(name); names.insert(name)
            }
        }
        func visit(_ url: URL, prefix: String, depth: Int) throws {
            guard depth <= 64 else { throw GitError.resourceLimitExceeded("reference depth", 64) }
            try Self.requireDirectory(url)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw GitError.invalidReference(child.lastPathComponent) }
                let name = prefix + "/" + child.lastPathComponent
                if name.hasSuffix(".lock") { continue }
                if values.isDirectory == true { try visit(child, prefix: name, depth: depth + 1) }
                else { _ = try GitReferenceName(name); names.insert(name) }
                guard names.count <= 100_000 else { throw GitError.resourceLimitExceeded("reference count", 100_000) }
            }
        }
        try visit(gitDirectory.appendingPathComponent("refs"), prefix: "refs", depth: 0)
        return names.sorted()
    }

    public func branches() throws -> [GitBranch] {
        let current = try headState().reference
        return try referenceNames().filter { $0.hasPrefix("refs/heads/") || $0.hasPrefix("refs/remotes/") }.compactMap { reference in
            if reference.hasSuffix("/HEAD") { return nil }
            guard let id = try resolveReference(reference) else { return nil }
            let remote = reference.hasPrefix("refs/remotes/")
            return .init(name: String(reference.dropFirst(remote ? 13 : 11)), reference: reference,
                         idValue: id, isRemote: remote, isCurrent: reference == current)
        }
    }

    public func createBranch(_ name: String, at id: GitObjectID? = nil) throws {
        let reference = "refs/heads/\(name)"
        _ = try GitReferenceName(reference)
        let lock = try GitFileLock(metadataURL(reference, createParents: true))
        guard try resolveReference(reference) == nil else { throw GitError.invalidReference("Branch already exists: \(name)") }
        guard let id = try id ?? headState().id else { throw GitError.invalidReference("No commit to branch from") }
        _ = try commitObject(id)
        try lock.publish(Data("\(id.hex)\n".utf8))
    }

    public func switchBranch(_ name: String) throws {
        let reference = "refs/heads/\(name)"
        _ = try GitReferenceName(reference)
        guard let id = try resolveReference(reference) else { throw GitError.invalidReference(reference) }
        try checkoutTransaction(to: id, changes: [.init(path: "HEAD", value: Data("ref: \(reference)\n".utf8))])
    }

    public func checkoutDetached(_ id: GitObjectID) throws {
        _ = try commitObject(id)
        try checkoutTransaction(to: id, changes: [.init(path: "HEAD", value: Data("\(id.hex)\n".utf8))])
    }

    public func deleteBranch(_ name: String) throws {
        let reference = "refs/heads/\(name)"
        _ = try GitReferenceName(reference)
        let current = try headState()
        guard current.reference != reference, let id = try resolveReference(reference) else { throw GitError.invalidReference(reference) }
        guard let head = current.id, try isAncestor(id, of: head) else { throw GitError.nonFastForward }
        var changes = [GitMetadataChange(path: reference, value: nil)]
        if let data = try optionalMetadata("packed-refs", limit: 16 * 1_024 * 1_024) {
            var removePeeled = false
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                if line.hasPrefix("^") { return !removePeeled }
                removePeeled = line.hasSuffix(" " + reference)
                return !removePeeled
            }.joined(separator: "\n")
            changes.append(.init(path: "packed-refs", value: Data(lines.utf8)))
        }
        try metadataTransaction(changes)
    }

    public func createTag(_ name: String, at id: GitObjectID? = nil) throws {
        let reference = "refs/tags/\(name)"
        _ = try GitReferenceName(reference)
        let lock = try GitFileLock(metadataURL(reference, createParents: true))
        guard try resolveReference(reference) == nil else { throw GitError.invalidReference("Tag already exists") }
        guard let id = try id ?? headState().id else { throw GitError.invalidReference("No object to tag") }
        _ = try readObject(id)
        try lock.publish(Data("\(id.hex)\n".utf8))
    }
}
