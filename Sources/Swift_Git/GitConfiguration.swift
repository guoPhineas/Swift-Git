//
//  GitConfiguration.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

struct GitConfiguration {
    struct Entry {
        let section: String
        let subsection: String?
        let key: String
        let value: String
    }
    let entries: [Entry]

    init(_ text: String) throws {
        var section = "", subsection: String?
        var entries = [Entry]()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw GitError.unsupportedFeature("config syntax") }
                let header = String(line.dropFirst().dropLast())
                if let quote = header.firstIndex(of: "\"") {
                    section = header[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
                    subsection = try Self.unquote(String(header[quote...]))
                } else { section = header.lowercased(); subsection = nil }
            } else {
                let fields = line.split(separator: "=", maxSplits: 1)
                let key = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = fields.count > 1 ? try Self.unquote(fields[1].trimmingCharacters(in: .whitespaces)) : "true"
                entries.append(.init(section: section, subsection: subsection, key: key, value: value))
            }
        }
        self.entries = entries
    }

    func value(_ section: String, _ subsection: String? = nil, _ key: String) -> String? {
        entries.last { $0.section == section && $0.subsection == subsection && $0.key == key }?.value
    }

    static func quote(_ string: String) throws -> String {
        guard !string.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw GitError.unsupportedFeature("control characters in config") }
        return "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func unquote(_ string: String) throws -> String {
        guard string.hasPrefix("\"") else { return string }
        guard string.hasSuffix("\""), string.count >= 2 else { throw GitError.unsupportedFeature("config quote syntax") }
        var result = "", escaped = false
        for character in string.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "\\", "\"": result.append(character)
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "b": result.append("\u{8}")
                default: throw GitError.unsupportedFeature("config escape")
                }
                escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        guard !escaped else { throw GitError.unsupportedFeature("config escape") }
        return result
    }
}

public struct GitRemote: Sendable, Identifiable {
    public let name: String
    public let url: GitRemoteURL
    public var id: String { name }
}

extension GitRepository {
    func configuration() throws -> GitConfiguration {
        try GitConfiguration(String(decoding: Self.readFile(metadataURL("config"), limit: 1_024 * 1_024), as: UTF8.self))
    }

    public func remotes() throws -> [GitRemote] {
        let config = try configuration()
        return try Set(config.entries.filter { $0.section == "remote" }.compactMap(\.subsection)).sorted().map { name in
            guard let value = config.value("remote", name, "url") else { throw GitError.invalidRemoteURL }
            return try .init(name: name, url: GitRemoteURL(value))
        }
    }

    public func setUpstream(branch: String, remote: String, remoteBranch: String) throws {
        let localReference = "refs/heads/\(branch)"
        let mergeReference = "refs/heads/\(remoteBranch)"
        _ = try GitReferenceName(localReference)
        _ = try GitReferenceName(mergeReference)
        guard try resolveReference(localReference) != nil else { throw GitError.invalidReference(localReference) }
        let lock = try GitFileLock(metadataURL("config"))
        let config = try configuration()
        guard config.value("remote", remote, "url") != nil else { throw GitError.invalidRemoteURL }
        var text = ""
        for entry in config.entries where !(entry.section == "branch" && entry.subsection == branch && ["remote", "merge"].contains(entry.key)) {
            let subsection = try entry.subsection.map { " " + (try GitConfiguration.quote($0)) } ?? ""
            text += try "[\(entry.section)\(subsection)]\n\t\(entry.key) = \(GitConfiguration.quote(entry.value))\n"
        }
        text += try "\n[branch \(GitConfiguration.quote(branch))]\n\tremote = \(GitConfiguration.quote(remote))\n\tmerge = \(GitConfiguration.quote(mergeReference))\n"
        try lock.publish(Data(text.utf8))
    }

    public func setRemote(name: String = "origin", url: GitRemoteURL) throws {
        _ = try GitReferenceName("refs/remotes/\(name)/HEAD")
        guard !name.contains("/") else { throw GitError.invalidReference(name) }
        let lock = try GitFileLock(metadataURL("config"))
        let config = try configuration()
        var text = ""
        for entry in config.entries where !(entry.section == "remote" && entry.subsection == name) {
            let subsection = try entry.subsection.map { " " + (try GitConfiguration.quote($0)) } ?? ""
            text += try "[\(entry.section)\(subsection)]\n\t\(entry.key) = \(GitConfiguration.quote(entry.value))\n"
        }
        text += try "\n[remote \(GitConfiguration.quote(name))]\n\turl = \(GitConfiguration.quote(url.url.absoluteString))\n\tfetch = +refs/heads/*:refs/remotes/\(name)/*\n"
        try lock.publish(Data(text.utf8))
    }
}
