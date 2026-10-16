//
//  GitHistory.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public struct GitCommit: Identifiable, Sendable, Equatable {
    public let id: GitObjectID
    public let tree: GitObjectID
    public let parents: [GitObjectID]
    public let author: String
    public let committer: String
    public let date: Date
    public let message: String
    public var subject: String { String(message.split(separator: "\n", omittingEmptySubsequences: false).first ?? "") }

    init(id: GitObjectID, object: GitObject) throws {
        guard object.kind == .commit, let split = object.body.range(of: Data("\n\n".utf8)) else {
            throw GitError.malformedObject("commit headers")
        }
        let header = String(decoding: object.body[..<split.lowerBound], as: UTF8.self)
        var fields = [String: [String]]()
        for line in header.split(separator: "\n") where !line.hasPrefix(" ") {
            guard let space = line.firstIndex(of: " ") else { throw GitError.malformedObject("commit header") }
            fields[String(line[..<space]), default: []].append(String(line[line.index(after: space)...]))
        }
        guard let tree = fields["tree"]?.first, fields["tree"]?.count == 1 else { throw GitError.malformedObject("commit tree") }
        self.id = id
        self.tree = try GitObjectID(hex: tree, algorithm: id.algorithm)
        parents = try (fields["parent"] ?? []).map { try GitObjectID(hex: $0, algorithm: id.algorithm) }
        let rawAuthor = fields["author"]?.first ?? "Unknown author"
        let rawCommitter = fields["committer"]?.first ?? "Unknown committer"
        author = rawAuthor.lastIndex(of: ">").map { String(rawAuthor[...$0]) } ?? rawAuthor
        committer = rawCommitter.lastIndex(of: ">").map { String(rawCommitter[...$0]) } ?? rawCommitter
        let timestamp = rawCommitter.split(separator: " ").dropLast().last.flatMap { TimeInterval($0) } ?? 0
        date = Date(timeIntervalSince1970: timestamp)
        // Keep raw objects intact; replacement decoding is only for presentation.
        message = String(decoding: object.body[split.upperBound...], as: UTF8.self)
    }
}

public struct GitHead: Sendable, Equatable {
    public let id: GitObjectID?
    public let branch: String?
}

extension GitRepository {
    public func head() throws -> GitHead {
        let state = try headState()
        return .init(id: state.id, branch: state.reference.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : nil })
    }

    /// Walks all parents reachable from HEAD (including merges), newest frontier first.
    public func log(limit: Int = 200) throws -> [GitCommit] {
        guard limit > 0, limit <= 10_000 else { throw GitError.resourceLimitExceeded("history page", 10_000) }
        guard let id = try headState().id else { return [] }
        var frontier = [try commitObject(id)]
        var seen: Set<GitObjectID> = [id]
        var result = [GitCommit]()
        var retainedBytes = 0
        func account(_ commit: GitCommit) throws {
            retainedBytes += commit.message.utf8.count + commit.author.utf8.count + commit.committer.utf8.count
                + commit.parents.count * (hashAlgorithm.byteCount + 32) + 256
            guard retainedBytes <= 32 * 1_024 * 1_024 else { throw GitError.sizeLimitExceeded(32 * 1_024 * 1_024) }
        }
        try account(frontier[0])
        while !frontier.isEmpty, result.count < limit {
            try Task.checkCancellation()
            let index = frontier.indices.max { frontier[$0].date < frontier[$1].date }!
            let commit = frontier.remove(at: index)
            result.append(commit)
            for parent in commit.parents where seen.insert(parent).inserted {
                guard seen.count <= 50_000 else { throw GitError.resourceLimitExceeded("history frontier", 50_000) }
                let next = try commitObject(parent)
                try account(next)
                frontier.append(next)
            }
        }
        return result
    }

    func commitObject(_ id: GitObjectID) throws -> GitCommit { try GitCommit(id: id, object: readObject(id)) }

    struct HeadState: Equatable {
        let text: String
        let reference: String?
        let id: GitObjectID?
    }

    func headState() throws -> HeadState {
        let text = try metadataText("HEAD")
        if text.hasPrefix("ref: ") {
            let reference = String(text.dropFirst(5))
            _ = try GitReferenceName(reference)
            return try .init(text: text, reference: reference, id: resolveReference(reference))
        }
        return try .init(text: text, reference: nil, id: GitObjectID(hex: text, algorithm: hashAlgorithm))
    }

    private func resolveReference(_ reference: String, depth: Int = 0) throws -> GitObjectID? {
        guard depth < 5 else { throw GitError.malformedObject("reference cycle") }
        _ = try GitReferenceName(reference)
        if let value = try optionalMetadata(reference, limit: 4096) {
            let text = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("ref: ") { return try resolveReference(String(text.dropFirst(5)), depth: depth + 1) }
            return try GitObjectID(hex: text, algorithm: hashAlgorithm)
        }
        if let packed = try optionalMetadata("packed-refs", limit: 16 * 1_024 * 1_024) {
            for line in String(decoding: packed, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { throw GitError.malformedObject("packed reference") }
                if parts[1] == reference { return try GitObjectID(hex: String(parts[0]), algorithm: hashAlgorithm) }
            }
        }
        return nil
    }

    func metadataURL(_ path: String, createParents: Bool = false) throws -> URL {
        try Self.requireDirectory(gitDirectory)
        var url = gitDirectory
        for component in path.split(separator: "/").dropLast() {
            url.appendPathComponent(String(component))
            if createParents, !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
            try Self.requireDirectory(url)
        }
        return url.appendingPathComponent(String(path.split(separator: "/").last!))
    }

    func optionalMetadata(_ path: String, limit: Int) throws -> Data? {
        do { return try Self.readFile(metadataURL(path), limit: limit) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func metadataText(_ path: String) throws -> String {
        String(decoding: try Self.readFile(metadataURL(path), limit: 4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
