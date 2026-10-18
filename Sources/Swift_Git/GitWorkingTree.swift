//
//  GitWorkingTree.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Darwin
import Foundation

/// Directory traversal never follows symlinks and never enters Git metadata.
extension GitRepository {
    func workingTree(tracked: [GitIndexEntry], storing paths: Set<String> = []) throws -> [String: GitIndexEntry] {
        let indexed = Dictionary(uniqueKeysWithValues: tracked.map { ($0.path, $0) })
        var trackedDirectories = Set<String>()
        for entry in tracked {
            var parts = entry.path.split(separator: "/")
            while parts.count > 1 { parts.removeLast(); trackedDirectories.insert(parts.joined(separator: "/")) }
        }
        var result = [String: GitIndexEntry]()
        var visited = 0
        var bytesRead = 0
        let rootRules: [GitIgnore]
        do { rootRules = try GitIgnore.rules(at: metadataURL("info/exclude"), base: "") }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { rootRules = [] }
        func visit(_ directory: URL, base: String, rules inherited: [GitIgnore], excludedParent: Bool, depth: Int) throws {
            guard depth <= 256 else { throw GitError.resourceLimitExceeded("directory depth", 256) }
            try Self.requireDirectory(directory)
            let rules = try inherited + GitIgnore.rules(at: directory.appendingPathComponent(".gitignore"), base: base)
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for url in urls {
                try Task.checkCancellation()
                visited += 1
                guard visited <= 100_000 else { throw GitError.resourceLimitExceeded("worktree entries", 100_000) }
                let name = url.lastPathComponent
                if name.lowercased() == ".git" { continue }
                let path = base.isEmpty ? name : base + "/" + name
                try GitIndex.validatePath(path)
                let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDirectory = info.isDirectory == true && info.isSymbolicLink != true
                var ignored = false
                for rule in rules where rule.matches(path, directory: isDirectory) { ignored = !rule.negated }
                ignored = ignored || excludedParent
                if let entry = indexed[path], entry.mode == .gitlink, isDirectory {
                    // An empty, uninitialized submodule stays at the indexed commit.
                    guard !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
                        throw GitError.unsupportedFeature("initialized submodule status")
                    }
                    result[path] = entry
                } else if isDirectory {
                    if !ignored || trackedDirectories.contains(path) {
                        try visit(url, base: path, rules: rules, excludedParent: ignored, depth: depth + 1)
                    }
                } else if indexed[path] != nil || !ignored {
                    let content = try worktreeContent(path)
                    guard let content else { continue }
                    bytesRead += content.data.count
                    guard bytesRead <= 512 * 1_024 * 1_024 else { throw GitError.sizeLimitExceeded(512 * 1_024 * 1_024) }
                    let object = GitObject(kind: .blob, body: content.data)
                    let id = try paths.contains(path) ? writeObject(object) : object.validatedID(using: hashAlgorithm)
                    result[path] = .init(path: path, mode: content.mode, id: id, size: content.data.count)
                }
            }
        }
        try visit(workingDirectory, base: "", rules: rootRules, excludedParent: false, depth: 0)
        return result
    }

    func worktreeContent(_ path: String) throws -> (data: Data, mode: GitFileMode)? {
        try GitIndex.validatePath(path)
        var url = workingDirectory
        try Self.requireDirectory(url)
        let parts = path.split(separator: "/")
        for component in parts.dropLast() {
            url.appendPathComponent(String(component))
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory != true || values.isSymbolicLink == true { return nil }
            }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
        url.appendPathComponent(String(parts.last!))
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            var buffer = [UInt8](repeating: 0, count: 4097)
            let count = buffer.withUnsafeMutableBytes { readlink(url.path, $0.baseAddress!, $0.count) }
            guard count >= 0, count < buffer.count else { throw GitError.unsafeCheckoutPath(path) }
            return (Data(buffer.prefix(count)), .symbolicLink)
        case S_IFREG:
            return (try Self.readFile(url, limit: maximumObjectBytes), info.st_mode & 0o111 == 0 ? .regular : .executable)
        case S_IFDIR: return nil
        default: throw GitError.unsupportedFeature("special worktree file: \(path)")
        }
    }
}

private struct GitIgnore {
    let base: String
    let pattern: String
    let negated: Bool
    let directoryOnly: Bool
    let anchored: Bool

    static func rules(at url: URL, base: String) throws -> [Self] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return [] }
        let data = try GitRepository.readFile(url, limit: 1_024 * 1_024)
        guard let text = String(data: data, encoding: .utf8) else { throw GitError.unsupportedFeature("non-UTF-8 ignore file") }
        return try text.split(separator: "\n").compactMap { raw in
            var line = String(raw).trimmingCharacters(in: .newlines)
            while line.hasSuffix(" "), !line.hasSuffix("\\ ") { line.removeLast() }
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard line.utf8.count <= 4096 else { throw GitError.sizeLimitExceeded(4096) }
            let negated = line.hasPrefix("!")
            if negated { line.removeFirst() }
            let directoryOnly = line.hasSuffix("/")
            if directoryOnly { line.removeLast() }
            let rooted = line.hasPrefix("/")
            if rooted { line.removeFirst() }
            guard !line.isEmpty else { return nil }
            return Self(base: base, pattern: line, negated: negated, directoryOnly: directoryOnly,
                        anchored: rooted || line.contains("/"))
        }
    }

    func matches(_ path: String, directory: Bool) -> Bool {
        guard !directoryOnly || directory else { return false }
        let relative: String
        if base.isEmpty { relative = path }
        else {
            guard path.hasPrefix(base + "/") else { return false }
            relative = String(path.dropFirst(base.count + 1))
        }
        if !anchored { return fnmatch(pattern, String(relative.split(separator: "/").last!), 0) == 0 }
        let patterns = pattern.split(separator: "/").map(String.init)
        let parts = relative.split(separator: "/").map(String.init)
        // Iterative dynamic programming bounds globstar matching to pattern × path components.
        var states: Set<Int> = [0]
        for part in patterns {
            if part == "**" {
                if let first = states.min() { states = Set(first...parts.count) }
            } else {
                states = Set(states.compactMap { index in
                    index < parts.count && fnmatch(part, parts[index], 0) == 0 ? index + 1 : nil
                })
            }
            if states.isEmpty { return false }
        }
        return states.contains(parts.count)
    }
}
