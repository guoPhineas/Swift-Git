//
//  GitCredential.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

/// Kept in memory by the framework. Applications should persist secrets only in Keychain.
public struct GitHTTPCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let username: String
    private let password: String

    public init(username: String = "x-access-token", password: String) throws {
        guard !username.contains(":"), !username.isEmpty, !password.isEmpty,
              !(username + password).utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw GitError.invalidIdentity }
        self.username = username
        self.password = password
    }

    var authorization: String { "Basic " + Data("\(username):\(password)".utf8).base64EncodedString() }
    public var description: String { "Git HTTPS credential (redacted)" }
    public var debugDescription: String { description }
}
