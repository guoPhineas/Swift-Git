//
//  GitReferenceName.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public struct GitReferenceName: Hashable, Sendable {
    public let rawValue: String

    public init(_ value: String) throws {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components.first == "refs",
              !value.contains(".."), !value.contains("@{"), !value.hasSuffix("."),
              !value.utf8.contains(where: { $0 <= 32 || $0 == 127 || "~^:?*[\\".utf8.contains($0) }),
              components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }) else {
            throw GitError.invalidReference(value)
        }
        rawValue = value
    }
}
