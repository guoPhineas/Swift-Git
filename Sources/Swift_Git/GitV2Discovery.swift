//
//  GitV2Discovery.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

enum GitV2Discovery {
    @concurrent
    static func discover(_ url: URL, remote: GitRemoteURL, transport: any GitHTTPTransport) async throws -> GitAdvertisement {
        let data = try await transport.discover(url)
        var preamble = try GitPacket.encode(Data("# service=git-upload-pack\n".utf8))
        preamble.append(Data("0000".utf8))
        let advertisementData = data.starts(with: preamble) ? Data(data.dropFirst(preamble.count)) : data
        guard advertisementData.starts(with: Data("000eversion 2\n".utf8)) else { return try GitAdvertisement(data) }
        let capabilities = try packets(advertisementData).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) }
        guard capabilities.first == "version 2", capabilities.contains(where: { $0 == "ls-refs" || $0.hasPrefix("ls-refs=") }),
              capabilities.contains(where: { $0 == "fetch" || $0.hasPrefix("fetch=") }) else { throw GitError.invalidProtocol("missing v2 commands") }
        let format = capabilities.first { $0.hasPrefix("object-format=") }.map { String($0.dropFirst(14)) } ?? "sha1"
        guard let algorithm = GitHashAlgorithm(rawValue: format) else { throw GitError.unsupportedFeature("server object format") }
        var request = try command("ls-refs", algorithm: algorithm)
        let unborn = capabilities.contains { $0.hasPrefix("ls-refs=") && $0.split(separator: "=").last?.split(separator: " ").contains("unborn") == true }
        var arguments = ["symrefs", "ref-prefix HEAD", "ref-prefix refs/heads/", "ref-prefix refs/tags/"]
        if unborn { arguments.append("unborn") }
        for argument in arguments { request.append(try GitPacket.encode(Data("\(argument)\n".utf8))) }
        request.append(Data("0000".utf8))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try await transport.fetch(remote.url.appendingPathComponent("git-upload-pack"), request: request, to: file, limit: 4 * 1_024 * 1_024, progress: nil)
        let references = try packets(GitRepository.readFile(file, limit: 4 * 1_024 * 1_024))
        var rows = [(String, String)](), target: String?
        for reference in references {
            let fields = String(decoding: reference, as: UTF8.self).trimmingCharacters(in: .newlines).split(separator: " ")
            guard fields.count >= 2 else { throw GitError.invalidProtocol("v2 reference") }
            let oid = String(fields[0]), name = String(fields[1])
            if name == "HEAD", let attribute = fields.dropFirst(2).first(where: { $0.hasPrefix("symref-target:") }) { target = String(attribute.dropFirst(14)) }
            if oid == "unborn" { guard name == "HEAD" else { throw GitError.invalidProtocol("unborn ref") }; continue }
            rows.append((oid, name))
        }
        var caps = ["side-band-64k", "ofs-delta", "object-format=\(algorithm.rawValue)"]
        if let target { _ = try GitReferenceName(target); caps.append("symref=HEAD:\(target)") }
        var synthetic = try GitPacket.encode(Data("# service=git-upload-pack\n".utf8))
        synthetic.append(Data("0000".utf8))
        if rows.isEmpty { rows = [(String(repeating: "0", count: algorithm.byteCount * 2), "capabilities^{}")] }
        for (position, row) in rows.enumerated() {
            let suffix = position == 0 ? "\0" + caps.joined(separator: " ") : ""
            synthetic.append(try GitPacket.encode(Data("\(row.0) \(row.1)\(suffix)\n".utf8)))
        }
        synthetic.append(Data("0000".utf8))
        var advertisement = try GitAdvertisement(synthetic)
        advertisement.wireVersion = 2
        advertisement.v2Features = Set(capabilities.first(where: { $0.hasPrefix("fetch=") })?.dropFirst(6).split(separator: " ").map(String.init) ?? [])
        return advertisement
    }

    static func command(_ name: String, algorithm: GitHashAlgorithm) throws -> Data {
        var data = try GitPacket.encode(Data("command=\(name)\n".utf8))
        data.append(try GitPacket.encode(Data("object-format=\(algorithm.rawValue)\n".utf8)))
        data.append(Data("0001".utf8))
        return data
    }

    private static func packets(_ data: Data) throws -> [Data] {
        var reader = GitByteReader(data), result = [Data](), flushed = false
        while !reader.isAtEnd {
            let header = try reader.read(count: 4)
            guard let size = Int(String(decoding: header, as: UTF8.self), radix: 16) else { throw GitError.invalidProtocol("v2 packet") }
            if size == 0 { flushed = true; break }
            guard size >= 4, size <= 65_520 else { throw GitError.invalidProtocol("v2 packet length") }
            result.append(try reader.read(count: size - 4))
        }
        if flushed, reader.remainingCount == 4, try reader.read(count: 4) == Data("0002".utf8) { return result }
        guard flushed, reader.isAtEnd else { throw GitError.invalidProtocol("unterminated v2 response") }
        return result
    }
}
