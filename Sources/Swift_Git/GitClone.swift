//
//  GitClone.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Darwin
import Foundation

extension GitRepository {
    /// Clones a public HTTPS repository into a destination that must not already exist.
    /// Work is staged beside the destination and published atomically after checkout succeeds.
    @concurrent
    public static func clone(from remote: GitRemoteURL, to destination: URL,
                             options: GitCloneOptions = .init(), progress: GitCloneProgressHandler? = nil) async throws -> GitRepository {
        try await clone(from: remote, to: destination, options: options, transport: GitURLSessionTransport(credential: options.credential), progress: progress)
    }

    @concurrent
    static func clone(from remote: GitRemoteURL, to destination: URL, options: GitCloneOptions = .init(),
                      transport: any GitHTTPTransport, progress: GitCloneProgressHandler? = nil) async throws -> GitRepository {
        try options.validate()
        guard destination.isFileURL else { throw GitError.notRepository }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw GitError.repositoryAlreadyExists }
        try Task.checkCancellation()
        progress?(.init(stage: .discovering))
        var discovery = URLComponents(url: remote.url.appendingPathComponent("info/refs"), resolvingAgainstBaseURL: false)
        discovery?.queryItems = [URLQueryItem(name: "service", value: "git-upload-pack")]
        guard let discoveryURL = discovery?.url else { throw GitError.invalidRemoteURL }
        let advertisement = try await GitV2Discovery.discover(discoveryURL, remote: remote, transport: transport)
        try Task.checkCancellation()
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".swift-git-clone-\(UUID().uuidString)", isDirectory: true)
        let repository = try await create(at: temporary, algorithm: advertisement.algorithm,
                                          initialBranch: advertisement.defaultBranch ?? "main", maximumObjectBytes: options.maximumObjectBytes)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var ids = Set<GitObjectID>()
        if !advertisement.wantedReferences.isEmpty {
            let response = temporary.appendingPathComponent(".git/upload-pack.response")
            let pack = temporary.appendingPathComponent(".git/clone.pack")
            progress?(.init(stage: .receiving))
            try await transport.fetch(remote.url.appendingPathComponent("git-upload-pack"), request: advertisement.fetchRequest(),
                                      to: response, limit: options.maximumDownloadBytes, progress: progress)
            try GitUploadPackResponse.extract(response, to: pack, limit: options.maximumDownloadBytes)
            progress?(.init(stage: .unpacking))
            ids = try await GitPack.unpack(pack, into: repository, options: options, progress: progress, persist: true)
            try FileManager.default.removeItem(at: response)
            try FileManager.default.removeItem(at: pack)
            guard Set(advertisement.wantedReferences.values).isSubset(of: ids) else {
                throw GitError.malformedObject("advertised object missing from pack")
            }
        }

        // Branches must reference commits; tags are retained as advertised.
        for (name, id) in advertisement.wantedReferences where name.hasPrefix("refs/heads/") {
            guard try await repository.readObject(id).kind == .commit else { throw GitError.malformedObject("branch is not a commit") }
        }
        let branch = advertisement.defaultBranch
        let head = branch.flatMap { advertisement.references["refs/heads/" + $0] } ?? advertisement.references["HEAD"]
        try await GitCheckout.populate(repository, commit: head, options: options, progress: progress)
        // The validated pack/index now own these objects; avoid duplicate loose storage.
        for id in ids {
            let object = temporary.appendingPathComponent(".git/objects/\(id.hex.prefix(2))/\(id.hex.dropFirst(2))")
            try FileManager.default.removeItem(at: object)
        }
        try installReferences(advertisement, remote: remote, in: temporary)
        try Task.checkCancellation()
        // RENAME_EXCL avoids replacing a destination created by another task during the download.
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw GitError.repositoryAlreadyExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        progress?(.init(stage: .complete, completed: Int64(ids.count), total: Int64(ids.count)))
        return GitRepository(directory: destination.standardizedFileURL, algorithm: advertisement.algorithm,
                             branch: branch ?? (head == nil ? "main" : nil), limit: options.maximumObjectBytes)
    }

    private static func installReferences(_ advertisement: GitAdvertisement, remote: GitRemoteURL, in directory: URL) throws {
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        func writeRef(_ name: String, content: String) throws {
            _ = try GitReferenceName(name)
            let url = git.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .withoutOverwriting)
        }
        for (name, id) in advertisement.wantedReferences.sorted(by: { $0.key < $1.key }) {
            if name.hasPrefix("refs/heads/") {
                try writeRef("refs/remotes/origin/" + name.dropFirst(11), content: id.hex + "\n")
            } else if name.hasPrefix("refs/tags/") { try writeRef(name, content: id.hex + "\n") }
        }
        let branch = advertisement.defaultBranch
        if let branch, let id = advertisement.references["refs/heads/" + branch] {
            try writeRef("refs/heads/" + branch, content: id.hex + "\n")
            if advertisement.references["refs/heads/HEAD"] == nil {
                try writeRef("refs/remotes/origin/HEAD", content: "ref: refs/remotes/origin/\(branch)\n")
            }
        }
        let head = branch.map { "ref: refs/heads/\($0)\n" }
            ?? advertisement.references["HEAD"].map { $0.hex + "\n" }
            ?? "ref: refs/heads/main\n"
        try Data(head.utf8).write(to: git.appendingPathComponent("HEAD"), options: .atomic)
        let configURL = git.appendingPathComponent("config")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        func quoted(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        config += "[remote \"origin\"]\n\turl = \"\(quoted(remote.url.absoluteString))\"\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
        if let branch {
            config += "[branch \"\(quoted(branch))\"]\n\tremote = origin\n\tmerge = refs/heads/\(branch)\n"
        }
        try Data(config.utf8).write(to: configURL, options: .atomic)
    }
}
