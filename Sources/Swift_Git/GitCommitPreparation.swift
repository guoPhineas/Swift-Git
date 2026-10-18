//
//  GitCommitPreparation.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/18.
//

import Foundation

/// An opaque snapshot of the branch, index and pending merge reviewed by a caller.
public struct GitCommitState: Sendable, Equatable {
    let headText: String
    let headID: GitObjectID?
    let indexChecksum: GitObjectID?
    let mergeHead: Data?
}

public struct GitCommitPreparation: Sendable {
    public let state: GitCommitState
    public let status: GitStatus
    public let isMerging: Bool
    public let suggestedMessage: String?
}

extension GitRepository {
    /// Reads the commit review under Git-compatible index/HEAD locks.
    public func prepareCommit() throws -> GitCommitPreparation {
        try validateCommitOperation()
        let indexLock = try GitFileLock(metadataURL("index"))
        let headLock = try GitFileLock(metadataURL("HEAD"))
        defer { withExtendedLifetime(indexLock) {}; withExtendedLifetime(headLock) {} }
        let state = try captureCommitState()
        let status = try status()
        let message = try optionalMetadata("MERGE_MSG", limit: 256 * 1_024).flatMap { String(data: $0, encoding: .utf8) }
        guard try captureCommitState() == state else { throw GitError.commitStateChanged }
        return .init(state: state, status: status, isMerging: state.mergeHead != nil, suggestedMessage: message)
    }

    func captureCommitState() throws -> GitCommitState {
        let head = try headState()
        let index = try optionalMetadata("index", limit: 32 * 1_024 * 1_024)
        let checksum = try index.map { bytes in
            var hash = GitChecksum(.sha256)
            hash.update(bytes)
            return try hash.finalize()
        }
        return try .init(headText: head.text, headID: head.id, indexChecksum: checksum,
                         mergeHead: optionalMetadata("MERGE_HEAD", limit: 4096))
    }

    func validateCommitOperation() throws {
        for marker in ["CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"] {
            if FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent(marker).path) {
                throw GitError.unsupportedFeature("commit during cherry-pick, revert, or rebase")
            }
        }
    }
}
