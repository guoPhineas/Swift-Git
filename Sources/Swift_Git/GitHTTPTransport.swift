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
}

struct GitURLSessionTransport: GitHTTPTransport {
    func discover(_ url: URL) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var request = URLRequest(url: url)
        request.setValue("application/x-git-upload-pack-advertisement", forHTTPHeaderField: "Accept")
        try await download(request, to: file, limit: 4 * 1_024 * 1_024, mime: "application/x-git-upload-pack-advertisement", progress: nil)
        return try Data(contentsOf: file)
    }

    func fetch(_ url: URL, request body: Data, to file: URL, limit: Int, progress: GitCloneProgressHandler?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-git-upload-pack-request", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-git-upload-pack-result", forHTTPHeaderField: "Accept")
        try await download(request, to: file, limit: limit, mime: "application/x-git-upload-pack-result", progress: progress)
    }

    private func download(_ request: URLRequest, to file: URL, limit: Int, mime: String,
                          progress: GitCloneProgressHandler?) async throws {
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
        completionHandler(request)
    }
}
