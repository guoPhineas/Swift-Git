//
//  GitRemoteOperations.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

public struct GitFetchResult: Sendable {
    public let references: [String: GitObjectID]
    public let receivedObjects: Int
}

public struct GitPushResult: Sendable {
    public let id: GitObjectID
    public let trackingUpdated: Bool
}

extension GitRepository {
    public func fetch(remote name: String = "origin", options: GitCloneOptions = .init(),
                      progress: GitCloneProgressHandler? = nil) async throws -> GitFetchResult {
        try await fetch(remote: name, options: options, transport: GitURLSessionTransport(credential: options.credential), progress: progress)
    }

    func fetch(remote name: String, options: GitCloneOptions = .init(), transport: any GitHTTPTransport,
               progress: GitCloneProgressHandler? = nil) async throws -> GitFetchResult {
        try options.validate()
        let operationLock = try GitFileLock(metadataURL("mobgit-fetch"))
        defer { withExtendedLifetime(operationLock) {} }
        guard let remote = try remotes().first(where: { $0.name == name }) else { throw GitError.invalidRemoteURL }
        progress?(.init(stage: .discovering))
        let advertisement = try await GitV2Discovery.discover(Self.discoveryURL(remote.url, service: "git-upload-pack"), remote: remote.url, transport: transport)
        guard advertisement.algorithm == hashAlgorithm else { throw GitError.invalidObjectID }
        var haves = Set<GitObjectID>()
        if let head = try headState().id { haves.insert(head) }
        for ref in try referenceNames() where ref.hasPrefix("refs/remotes/\(name)/") {
            if let id = try resolveReference(ref), try readObject(id).kind == .commit { haves.insert(id) }
        }
        var missing = false
        for id in Set(advertisement.wantedReferences.values) {
            do { _ = try readObject(id) }
            catch GitError.objectNotFound { missing = true }
        }
        var received = 0
        if missing {
            let transfer = gitDirectory.appendingPathComponent("mobgit-transfer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: transfer, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: transfer) }
            let response = transfer.appendingPathComponent("response"), pack = transfer.appendingPathComponent("pack")
            try await transport.fetch(remote.url.url.appendingPathComponent("git-upload-pack"), request: advertisement.fetchRequest(haves: Array(haves)),
                                      to: response, limit: options.maximumDownloadBytes, progress: progress)
            try GitUploadPackResponse.extract(response, to: pack, limit: options.maximumDownloadBytes)
            received = try await GitPack.unpack(pack, into: self, options: options, progress: progress, allowExisting: true, persist: true).count
        }
        // Verify every advertised tip before publishing references.
        for (ref, id) in advertisement.wantedReferences {
            let object = try readObject(id)
            if ref.hasPrefix("refs/heads/"), object.kind != .commit { throw GitError.malformedObject("remote branch is not a commit") }
        }
        for (ref, id) in advertisement.wantedReferences.sorted(by: { $0.key < $1.key }) {
            let destination: String
            if ref.hasPrefix("refs/heads/") { destination = "refs/remotes/\(name)/" + ref.dropFirst(11) }
            else if ref.hasPrefix("refs/tags/") {
                if let existing = try resolveReference(ref), existing != id { continue }
                destination = ref
            } else { continue }
            let lock = try GitFileLock(metadataURL(destination, createParents: true))
            try lock.publish(Data("\(id.hex)\n".utf8))
        }
        let fetchHead = advertisement.wantedReferences.sorted(by: { $0.key < $1.key }).map {
            "\($0.value.hex)\t\t\($0.key) of \(remote.url.url.absoluteString)\n"
        }.joined()
        try GitFileLock(metadataURL("FETCH_HEAD")).publish(Data(fetchHead.utf8))
        progress?(.init(stage: .complete, completed: Int64(received), total: Int64(received)))
        return .init(references: advertisement.wantedReferences, receivedObjects: received)
    }

    public func push(remote name: String = "origin", branch: String? = nil, credential: GitHTTPCredential? = nil) async throws -> GitPushResult {
        try await push(remote: name, branch: branch, transport: GitURLSessionTransport(credential: credential))
    }

    func push(remote name: String, branch: String? = nil, transport: any GitHTTPTransport) async throws -> GitPushResult {
        let lock = try GitFileLock(metadataURL("mobgit-push"))
        defer { withExtendedLifetime(lock) {} }
        guard let remote = try remotes().first(where: { $0.name == name }),
              let branch = try branch ?? head().branch else { throw GitError.invalidReference("Choose a local branch to push") }
        let reference = "refs/heads/\(branch)"
        _ = try GitReferenceName(reference)
        guard let new = try resolveReference(reference) else { throw GitError.invalidReference(reference) }
        let advertised = try GitAdvertisement(await transport.discover(Self.discoveryURL(remote.url, service: "git-receive-pack")), service: "git-receive-pack")
        guard advertised.algorithm == hashAlgorithm else { throw GitError.invalidObjectID }
        guard advertised.capabilities.contains("report-status") else { throw GitError.unsupportedFeature("receive-pack without report-status") }
        let old = advertised.references[reference]
        if old == new { return .init(id: new, trackingUpdated: try resolveReference("refs/remotes/\(name)/\(branch)") == new) }
        if let old, try !isAncestor(old, of: new) { throw GitError.nonFastForward }
        let transfer = gitDirectory.appendingPathComponent("mobgit-push-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: transfer) }
        let zero = String(repeating: "0", count: hashAlgorithm.byteCount * 2)
        var caps = ["report-status"]
        if advertised.capabilities.contains("object-format=\(hashAlgorithm.rawValue)") { caps.append("object-format=\(hashAlgorithm.rawValue)") }
        var prefix = try GitPacket.encode(Data("\(old?.hex ?? zero) \(new.hex) \(reference)\0\(caps.joined(separator: " "))\n".utf8))
        prefix.append(Data("0000".utf8))
        var excluded = Set<GitObjectID>()
        for tip in Set(advertised.references.values) {
            if (try? readObject(tip)) != nil { excluded.formUnion(try reachableObjects(from: [tip], excluding: [])) }
        }
        let ids = try reachableObjects(from: [new], excluding: excluded)
        try writePack(ids, prefix: prefix, to: transfer)
        let response = try await transport.send(remote.url.url.appendingPathComponent("git-receive-pack"), requestFile: transfer, limit: 128 * 1_024 * 1_024)
        try Self.verifyPushResponse(response, reference: reference)
        var trackingUpdated = false
        do {
            let tracking = try GitFileLock(metadataURL("refs/remotes/\(name)/\(branch)", createParents: true))
            try tracking.publish(Data("\(new.hex)\n".utf8))
            trackingUpdated = true
        } catch { /* The server update succeeded; report tracking separately. */ }
        return .init(id: new, trackingUpdated: trackingUpdated)
    }

    public func isAncestor(_ ancestor: GitObjectID, of descendant: GitObjectID) throws -> Bool {
        var pending = [descendant], seen = Set<GitObjectID>()
        while let id = pending.popLast() {
            try Task.checkCancellation()
            if id == ancestor { return true }
            guard seen.insert(id).inserted else { continue }
            guard seen.count <= 250_000 else { throw GitError.resourceLimitExceeded("commit graph", 250_000) }
            pending.append(contentsOf: try commitObject(id).parents)
        }
        return false
    }

    func reachableObjects(from tips: [GitObjectID], excluding: Set<GitObjectID>) throws -> Set<GitObjectID> {
        var pending = tips, seen = Set<GitObjectID>()
        while let id = pending.popLast() {
            try Task.checkCancellation()
            if excluding.contains(id) || !seen.insert(id).inserted { continue }
            guard seen.count <= 250_000 else { throw GitError.resourceLimitExceeded("object graph", 250_000) }
            pending.append(contentsOf: try readObject(id).referencedObjects(using: hashAlgorithm))
        }
        return seen
    }

    private func writePack(_ ids: Set<GitObjectID>, prefix: Data, to url: URL) throws {
        try prefix.write(to: url, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        var hash = GitChecksum(hashAlgorithm), bytes = prefix.count, expanded = 0
        func append(_ data: Data) throws {
            bytes += data.count
            guard bytes <= 128 * 1_024 * 1_024 else { throw GitError.sizeLimitExceeded(128 * 1_024 * 1_024) }
            hash.update(data)
            try file.write(contentsOf: data)
        }
        var header = Data("PACK".utf8)
        header.appendNetwork(2); header.appendNetwork(UInt32(ids.count))
        try append(header)
        for id in ids.sorted(by: { $0.hex < $1.hex }) {
            let object = try readObject(id)
            expanded += object.body.count
            guard expanded <= 512 * 1_024 * 1_024 else { throw GitError.sizeLimitExceeded(512 * 1_024 * 1_024) }
            let types: [GitObjectKind: UInt8] = [.commit: 1, .tree: 2, .blob: 3, .tag: 4]
            var remaining = object.body.count >> 4
            var first = (types[object.kind]! << 4) | UInt8(object.body.count & 15)
            if remaining > 0 { first |= 128 }
            var entry = Data([first])
            while remaining > 0 {
                var byte = UInt8(remaining & 127)
                remaining >>= 7
                if remaining > 0 { byte |= 128 }
                entry.append(byte)
            }
            try append(entry)
            try append(GitZlib.compress(object.body))
        }
        try file.write(contentsOf: Data(hash.finalize().bytes))
    }

    private static func discoveryURL(_ remote: GitRemoteURL, service: String) throws -> URL {
        var url = URLComponents(url: remote.url.appendingPathComponent("info/refs"), resolvingAgainstBaseURL: false)
        url?.queryItems = [.init(name: "service", value: service)]
        guard let result = url?.url else { throw GitError.invalidRemoteURL }
        return result
    }

    private static func verifyPushResponse(_ data: Data, reference: String) throws {
        var reader = GitByteReader(data), unpacked = false, updated = false, flushed = false
        while !reader.isAtEnd {
            let header = try reader.read(count: 4)
            guard let size = Int(String(decoding: header, as: UTF8.self), radix: 16) else { throw GitError.invalidProtocol("push status packet") }
            if size == 0 { flushed = true; break }
            guard size >= 4, size <= 65_520 else { throw GitError.invalidProtocol("push status length") }
            let message = String(decoding: try reader.read(count: size - 4), as: UTF8.self)
            if message == "unpack ok\n" { unpacked = true }
            else if message == "ok \(reference)\n" { updated = true }
            else { throw GitError.invalidProtocol("Remote rejected push: " + String(message.prefix(200))) }
        }
        guard unpacked, updated, flushed, reader.isAtEnd else { throw GitError.invalidProtocol("incomplete push result") }
    }
}
