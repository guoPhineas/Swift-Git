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
}

extension GitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
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
        }
    }
}
