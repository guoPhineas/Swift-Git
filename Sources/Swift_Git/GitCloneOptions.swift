//
//  GitCloneOptions.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public struct GitRemoteURL: Sendable, Equatable {
    public let url: URL

    public init(_ string: String) throws {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path != "", components.path != "/",
              !components.path.utf8.contains(where: { $0 < 32 || $0 == 127 }),
              let url = components.url else { throw GitError.invalidRemoteURL }
        self.url = url
    }
}

public struct GitCloneOptions: Sendable {
    public var maximumDownloadBytes = 128 * 1_024 * 1_024
    public var maximumObjectBytes = 64 * 1_024 * 1_024
    public var maximumExpandedBytes = 512 * 1_024 * 1_024
    public var maximumObjects = 250_000
    public var maximumCheckoutFiles = 100_000
    public var maximumDeltaDepth = 128

    public init() {}

    func validate() throws {
        guard maximumDownloadBytes > 0, maximumDownloadBytes <= Int(UInt32.max) - 65_536,
              maximumObjectBytes > 0, maximumObjectBytes <= Int(UInt32.max) - 65_536,
              maximumExpandedBytes > 0, maximumObjects > 0, maximumObjects <= Int.max / 8,
              maximumCheckoutFiles > 0, maximumCheckoutFiles <= Int(UInt32.max),
              maximumDeltaDepth > 0 else { throw GitError.invalidProtocol("invalid clone limits") }
    }
}

public struct GitCloneProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case discovering, receiving, unpacking, checkingOut, complete }
    public let stage: Stage
    public let completed: Int64
    public let total: Int64?

    public init(stage: Stage, completed: Int64 = 0, total: Int64? = nil) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }
}

public typealias GitCloneProgressHandler = @Sendable (GitCloneProgress) -> Void
