//
//  GitMerge.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public enum GitMergeResult: Sendable, Equatable {
    case upToDate
    case fastForward(GitObjectID)
    case readyToCommit
    case conflicts([String])
}

public struct GitConflict: Sendable, Identifiable {
    public let path: String
    public let base: Data?
    public let ours: Data?
    public let theirs: Data?
    public var id: String { path }
}

private struct GitMergeState: Codable {
    let original: String
    let incoming: String
    let workingPaths: [String]
}

extension GitRepository {
    public func mergeState() throws -> Bool { try optionalMetadata("MERGE_HEAD", limit: 4096) != nil }

    public func mergeBase(_ lhs: GitObjectID, _ rhs: GitObjectID) throws -> GitObjectID? {
        var ancestors = Set<GitObjectID>(), pending = [lhs]
        while let id = pending.popLast() {
            try Task.checkCancellation()
            guard ancestors.insert(id).inserted else { continue }
            guard ancestors.count <= 250_000 else { throw GitError.resourceLimitExceeded("merge graph", 250_000) }
            pending.append(contentsOf: try commitObject(id).parents)
        }
        var seen = Set<GitObjectID>(), common = Set<GitObjectID>()
        pending = [rhs]
        while let id = pending.popLast() {
            try Task.checkCancellation()
            guard seen.insert(id).inserted else { continue }
            guard seen.count <= 250_000 else { throw GitError.resourceLimitExceeded("merge graph", 250_000) }
            if ancestors.contains(id) { common.insert(id) }
            else { pending.append(contentsOf: try commitObject(id).parents) }
        }
        var best = [GitObjectID]()
        for candidate in common {
            var redundant = false
            for other in common where other != candidate {
                if try isAncestor(candidate, of: other) { redundant = true; break }
            }
            if !redundant { best.append(candidate) }
        }
        guard best.count <= 1 else { throw GitError.unsupportedFeature("recursive merge of multiple merge bases") }
        return best.first
    }

    public func merge(_ incoming: GitObjectID) throws -> GitMergeResult {
        guard try !mergeState() else { throw GitError.unsupportedFeature("another merge is in progress") }
        guard try status().files.isEmpty else { throw GitError.dirtyWorktree }
        let head = try headState()
        guard let oursID = head.id else { throw GitError.invalidReference("No current commit") }
        _ = try commitObject(incoming)
        if try isAncestor(incoming, of: oursID) { return .upToDate }
        if try isAncestor(oursID, of: incoming) {
            let target = head.reference ?? "HEAD"
            try checkoutTransaction(to: incoming, changes: [.init(path: target, value: Data("\(incoming.hex)\n".utf8)),
                                                            .init(path: "ORIG_HEAD", value: Data("\(oursID.hex)\n".utf8))], expectedHead: head)
            return .fastForward(incoming)
        }
        guard let baseID = try mergeBase(oursID, incoming) else { throw GitError.unsupportedFeature("merge of unrelated histories") }
        let base = try headFiles(baseID), ours = try headFiles(oursID), theirs = try headFiles(incoming)
        let paths = Set(base.keys).union(ours.keys).union(theirs.keys).sorted()
        var index = [GitIndexEntry](), working = [GitIndexEntry](), conflicts = [String]()
        func matches(_ a: GitIndexEntry?, _ b: GitIndexEntry?) -> Bool { a == nil ? b == nil : a!.matches(b) }
        for path in paths {
            try Task.checkCancellation()
            let old = base[path], lhs = ours[path], rhs = theirs[path]
            var chosen: GitIndexEntry?, conflicted = false
            if matches(lhs, rhs) { chosen = lhs }
            else if matches(lhs, old) { chosen = rhs }
            else if matches(rhs, old) { chosen = lhs }
            else if let lhs, let rhs, [.regular, .executable].contains(lhs.mode), [.regular, .executable].contains(rhs.mode),
                    old == nil || [.regular, .executable].contains(old!.mode),
                    let merged = try GitMergeText.merge(base: old.map { try readObject($0.id).body } ?? Data(),
                                                        ours: readObject(lhs.id).body, theirs: readObject(rhs.id).body) {
                let mode = lhs.mode == old?.mode ? rhs.mode : lhs.mode
                let object = GitObject(kind: .blob, body: merged.data)
                chosen = .init(path: path, mode: mode, id: try writeObject(object), size: object.body.count)
                conflicted = merged.conflicted
            } else { chosen = lhs ?? rhs; conflicted = true }
            if let chosen { working.append(chosen) }
            if conflicted {
                conflicts.append(path)
                for (stage, entry) in [(1, old), (2, lhs), (3, rhs)] {
                    if let entry { index.append(.init(path: path, mode: entry.mode, id: entry.id, size: entry.size, stage: stage)) }
                }
            } else if let chosen { index.append(chosen) }
        }
        try validateIndexPaths(working)
        let state = GitMergeState(original: oursID.hex, incoming: incoming.hex, workingPaths: working.map(\.path))
        try workingTransaction(entries: working, changes: [
            .init(path: "MERGE_HEAD", value: Data("\(incoming.hex)\n".utf8)),
            .init(path: "MERGE_MSG", value: Data("Merge \(incoming.hex.prefix(12))\n".utf8)),
            .init(path: "ORIG_HEAD", value: Data("\(oursID.hex)\n".utf8)),
            .init(path: "mobgit-merge.json", value: JSONEncoder().encode(state)),
        ], index: index) {
            guard try headState() == head else { throw GitError.repositoryBusy }
        }
        return conflicts.isEmpty ? .readyToCommit : .conflicts(conflicts)
    }

    public func pull(remote: String = "origin", options: GitCloneOptions = .init(), progress: GitCloneProgressHandler? = nil) async throws -> GitMergeResult {
        try await pull(remote: remote, options: options, transport: GitURLSessionTransport(credential: options.credential), progress: progress)
    }

    func pull(remote: String, options: GitCloneOptions = .init(), transport: any GitHTTPTransport,
              progress: GitCloneProgressHandler? = nil) async throws -> GitMergeResult {
        let expected = try headState()
        guard let reference = expected.reference else { throw GitError.invalidReference("Pull needs a local branch") }
        let branch = String(reference.dropFirst("refs/heads/".count))
        let config = try configuration()
        let upstream = config.value("branch", branch, "merge") ?? "refs/heads/\(branch)"
        let result = try await fetch(remote: remote, options: options, transport: transport, progress: progress)
        guard try headState() == expected else { throw GitError.repositoryBusy }
        guard let incoming = result.references[upstream] else { throw GitError.invalidReference(upstream) }
        return try merge(incoming)
    }

    public func conflicts() throws -> [GitConflict] {
        let grouped = Dictionary(grouping: try indexEntries().filter { $0.stage > 0 }, by: \.path)
        return try grouped.keys.sorted().map { path in
            let entries = grouped[path]!
            func bytes(_ stage: Int) throws -> Data? {
                guard let entry = entries.first(where: { $0.stage == stage }) else { return nil }
                if entry.mode == .gitlink { return Data(entry.id.hex.utf8) }
                return try readObject(entry.id).body
            }
            return try .init(path: path, base: bytes(1), ours: bytes(2), theirs: bytes(3))
        }
    }

    public func resolveConflict(path: String, takingTheirs: Bool) throws {
        let all = try indexEntries()
        guard all.contains(where: { $0.path == path && $0.stage > 0 }) else { throw GitError.unsafeCheckoutPath(path) }
        let selected = all.first { $0.path == path && $0.stage == (takingTheirs ? 3 : 2) }
        let baseline = workingIndex(all)
        let actual = try workingTree(tracked: baseline)
        var work = Dictionary(uniqueKeysWithValues: baseline.compactMap { actual[$0.path] }.map { ($0.path, $0) })
        work[path] = selected.map { .init(path: path, mode: $0.mode, id: $0.id, size: $0.size) }
        let index = all.filter { $0.path != path } + (work[path].map { [$0] } ?? [])
        let original = baseline.compactMap { actual[$0.path] }
        // Save current conflict-marker bytes as objects so rollback can restore them.
        for entry in original {
            if let content = try worktreeContent(entry.path), entry.mode != .gitlink { _ = try writeObject(.init(kind: .blob, body: content.data)) }
        }
        try workingTransaction(entries: Array(work.values), changes: [], index: index, originalWorking: original)
    }

    public func abortMerge() throws {
        guard let data = try optionalMetadata("mobgit-merge.json", limit: 16 * 1_024 * 1_024) else { throw GitError.unsupportedFeature("no MobGit merge to abort") }
        let state = try JSONDecoder().decode(GitMergeState.self, from: data)
        let original = try GitObjectID(hex: state.original, algorithm: hashAlgorithm)
        guard try headState().id == original else { throw GitError.repositoryBusy }
        let target = Array(try headFiles(original).values)
        let baseline = workingIndex(try indexEntries())
        let actual = try workingTree(tracked: baseline)
        let paths = Set(state.workingPaths).union(target.map(\.path))
        let current = actual.values.filter { paths.contains($0.path) }
        for entry in current where entry.mode != .gitlink {
            if let content = try worktreeContent(entry.path) { _ = try writeObject(.init(kind: .blob, body: content.data)) }
        }
        try workingTransaction(entries: target, changes: [.init(path: "MERGE_HEAD", value: nil), .init(path: "MERGE_MSG", value: nil),
                                                          .init(path: "mobgit-merge.json", value: nil)], originalWorking: Array(current))
    }
}
