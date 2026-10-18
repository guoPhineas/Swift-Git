//
//  GitHTTPTransport.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Synchronization

protocol GitHTTPTransport: Sendable {
    func discover(_ url: URL) async throws -> Data
    func fetch(_ url: URL, request: Data, to file: URL, limit: Int, progress: GitCloneProgressHandler?) async throws
    func send(_ url: URL, requestFile: URL, limit: Int) async throws -> Data
}

extension GitHTTPTransport {
    func send(_ url: URL, requestFile: URL, limit: Int) async throws -> Data { throw GitError.unsupportedFeature("receive-pack transport") }
}

struct GitURLSessionTransport: GitHTTPTransport {
    var credential: GitHTTPCredential?
    func discover(_ url: URL) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var request = URLRequest(url: url)
        let service = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "service" }?.value ?? "git-upload-pack"
        guard ["git-upload-pack", "git-receive-pack"].contains(service) else { throw GitError.invalidProtocol("service") }
        if service == "git-upload-pack" { request.setValue("version=2", forHTTPHeaderField: "Git-Protocol") }
        request.setValue("application/x-\(service)-advertisement", forHTTPHeaderField: "Accept")
        try await download(request, to: file, limit: 4 * 1_024 * 1_024, mime: "application/x-\(service)-advertisement", progress: nil)
        return try Data(contentsOf: file)
    }

    func fetch(_ url: URL, request body: Data, to file: URL, limit: Int, progress: GitCloneProgressHandler?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        if body.dropFirst(4).starts(with: Data("command=".utf8)) { request.setValue("version=2", forHTTPHeaderField: "Git-Protocol") }
        request.setValue("application/x-git-upload-pack-request", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-git-upload-pack-result", forHTTPHeaderField: "Accept")
        try await download(request, to: file, limit: limit, mime: "application/x-git-upload-pack-result", progress: progress)
    }

    func send(_ url: URL, requestFile: URL, limit: Int) async throws -> Data {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try GitRepository.readFile(requestFile, limit: limit)
        request.setValue("application/x-git-receive-pack-request", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-git-receive-pack-result", forHTTPHeaderField: "Accept")
        try await download(request, to: destination, limit: 1_024 * 1_024, mime: "application/x-git-receive-pack-result", progress: nil)
        return try Data(contentsOf: destination)
    }

    private func download(_ original: URLRequest, to file: URL, limit: Int, mime: String,
                          progress: GitCloneProgressHandler?) async throws {
        var request = original
        if let credential { request.setValue(credential.authorization, forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = GitDownloadDelegate(limit: limit, progress: progress)
        do {
            let (temporary, response) = try await session.download(for: request, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse else { throw GitError.invalidProtocol("missing HTTP response") }
            guard http.statusCode == 200 else { throw GitError.httpStatus(http.statusCode) }
            guard http.url?.scheme?.lowercased() == "https" else { throw GitError.invalidRemoteURL }
            guard http.mimeType?.lowercased() == mime else { throw GitError.invalidProtocol("server does not support Git Smart HTTP") }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= limit else { throw GitError.sizeLimitExceeded(limit) }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: file)
        } catch {
            if let reason = delegate.failure.withLock({ $0 }) { throw reason }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

private final class GitDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let failure = Mutex<GitError?>(nil)
    private let limit: Int
    private let progress: GitCloneProgressHandler?

    init(limit: Int, progress: GitCloneProgressHandler?) {
        self.limit = limit
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Int64(limit) || totalBytesExpectedToWrite > Int64(limit) {
            failure.withLock { $0 = .sizeLimitExceeded(limit) }
            downloadTask.cancel()
            return
        }
        progress?(.init(stage: .receiving, completed: totalBytesWritten,
                        total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https", request.url?.user == nil, request.url?.password == nil else {
            failure.withLock { $0 = .invalidRemoteURL }
            completionHandler(nil)
            return
        }
        if let original = task.originalRequest, original.value(forHTTPHeaderField: "Authorization") != nil,
           (original.url?.host?.lowercased() != request.url?.host?.lowercased() || original.url?.port != request.url?.port) {
            failure.withLock { $0 = .invalidRemoteURL }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
