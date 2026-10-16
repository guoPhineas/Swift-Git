//
//  GitError.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public enum GitError: Error, Sendable, Equatable {
    case invalidObjectID
    case malformedObject(String)
    case truncatedInput
    case sizeLimitExceeded(Int)
    case compression(Int32)
    case objectNotFound(GitObjectID)
    case objectHashMismatch
    case invalidReference(String)
    case notRepository
    case repositoryAlreadyExists
    case unsupportedFeature(String)
    case invalidRemoteURL
    case resourceLimitExceeded(String, Int)
    case httpStatus(Int)
    case invalidProtocol(String)
    case sha1Collision
    case unsafeCheckoutPath(String)
    case repositoryBusy
    case nothingToCommit
    case invalidIdentity
}

extension GitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .repositoryBusy: "Another Git operation is in progress. Wait for it to finish and retry."
        case .nothingToCommit: "There are no staged changes to commit."
        case .invalidIdentity: "Enter a valid author name and email address."
        case .invalidObjectID: "Invalid Git object ID."
        case .malformedObject(let reason): "Invalid Git object: \(reason)"
        case .truncatedInput: "Git data ended unexpectedly."
        case .sizeLimitExceeded(let limit): "This operation exceeds its \(limit)-byte safety limit."
        case .compression(let status): "zlib failed with status \(status)."
        case .objectNotFound(let id): "Object \(id.hex) is not available in the loose object store."
        case .objectHashMismatch: "The object content does not match its ID."
        case .invalidReference(let name): "Invalid Git reference: \(name)"
        case .notRepository: "The directory is not a supported Git repository."
        case .repositoryAlreadyExists: "The repository destination is not empty."
        case .unsupportedFeature(let feature): "Not supported yet: \(feature)."
        case .resourceLimitExceeded(let resource, let limit): "The repository exceeds the \(resource) limit (\(limit))."
        case .invalidRemoteURL: "Enter a public HTTPS repository URL without credentials, a query, or a fragment."
        case .httpStatus(let status): "The Git server returned HTTP \(status). The repository may be unavailable or require authentication."
        case .invalidProtocol(let reason): "Invalid Git server response: \(reason)"
        case .sha1Collision: "A SHA-1 collision was detected. The repository was rejected."
        case .unsafeCheckoutPath(let path): "The repository contains a path that cannot be safely checked out: \(path)"
        }
    }
}
