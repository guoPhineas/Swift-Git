//
//  GitWireProtocol.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

enum GitPacket {
    static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= 65_516 else { throw GitError.invalidProtocol("packet too large") }
        var packet = Data(String(format: "%04x", payload.count + 4).utf8)
        packet.append(payload)
        return packet
    }

    static func read(from reader: GitFileReader) throws -> Data? {
        let header = try reader.read(4)
        guard header.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
              let size = Int(String(decoding: header, as: UTF8.self), radix: 16) else {
            throw GitError.invalidProtocol("invalid packet length")
        }
        if size == 0 { return nil }
        guard size >= 4, size <= 65_520 else { throw GitError.invalidProtocol("invalid packet length") }
        return try reader.read(size - 4)
    }
}

struct GitAdvertisement {
    let algorithm: GitHashAlgorithm
    let references: [String: GitObjectID]
    let capabilities: Set<String>
    let headTarget: String?

    init(_ data: Data) throws {
        var reader = GitByteReader(data)
        func packet() throws -> Data? {
            let header = try reader.read(count: 4)
            guard header.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
                  let length = Int(String(decoding: header, as: UTF8.self), radix: 16) else {
                throw GitError.invalidProtocol("invalid advertisement packet")
            }
            if length == 0 { return nil }
            guard length >= 4, length <= 65_520 else { throw GitError.invalidProtocol("advertisement packet length") }
            return try reader.read(count: length - 4)
        }
        guard try packet() == Data("# service=git-upload-pack\n".utf8), try packet() == nil else {
            throw GitError.invalidProtocol("missing upload-pack service")
        }
        var refs = [String: GitObjectID]()
        var caps = Set<String>()
        var format: GitHashAlgorithm?
        var firstReference = true
        var terminated = false
        while !reader.isAtEnd {
            guard let bytes = try packet() else { terminated = true; break }
            if bytes == Data("version 1\n".utf8), firstReference { continue }
            guard let text = String(data: bytes, encoding: .utf8) else { throw GitError.invalidProtocol("reference encoding") }
            if text.hasPrefix("ERR ") { throw GitError.invalidProtocol("remote rejected reference discovery") }
            let parts = text.trimmingCharacters(in: .newlines).split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                guard firstReference else { throw GitError.invalidProtocol("unexpected capabilities") }
                caps = Set(parts[1].split(separator: " ").map(String.init))
            }
            firstReference = false
            let fields = parts[0].split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { throw GitError.invalidProtocol("reference line") }
            let algorithm: GitHashAlgorithm
            switch fields[0].utf8.count {
            case 40: algorithm = .sha1
            case 64: algorithm = .sha256
            default: throw GitError.invalidObjectID
            }
            if let format, format != algorithm { throw GitError.invalidProtocol("mixed object formats") }
            format = algorithm
            let id = try GitObjectID(hex: String(fields[0]), algorithm: algorithm)
            let name = String(fields[1])
            if name == "capabilities^{}", id.bytes.allSatisfy({ $0 == 0 }) { continue }
            if name.hasSuffix("^{}") { continue }
            if name != "HEAD" { _ = try GitReferenceName(name) }
            guard refs[name] == nil, !id.bytes.allSatisfy({ $0 == 0 }) else { throw GitError.invalidProtocol("duplicate or zero reference") }
            refs[name] = id
        }
        guard terminated, reader.isAtEnd, !firstReference else { throw GitError.invalidProtocol("incomplete reference advertisement") }
        let algorithm = format ?? .sha1
        if let advertised = caps.first(where: { $0.hasPrefix("object-format=") }), advertised != "object-format=\(algorithm.rawValue)" {
            throw GitError.invalidProtocol("object-format capability differs from references")
        }
        self.algorithm = algorithm
        references = refs
        capabilities = caps
        if let target = caps.first(where: { $0.hasPrefix("symref=HEAD:") }).map({ String($0.dropFirst(12)) }) {
            _ = try GitReferenceName(target)
            headTarget = target
        } else { headTarget = nil }
    }

    var wantedReferences: [String: GitObjectID] {
        references.filter { $0.key == "HEAD" || $0.key.hasPrefix("refs/heads/") || $0.key.hasPrefix("refs/tags/") }
    }

    var defaultBranch: String? {
        if let headTarget, headTarget.hasPrefix("refs/heads/"),
           references.isEmpty || references[headTarget] == references["HEAD"] { return String(headTarget.dropFirst(11)) }
        let heads = references.keys.filter { $0.hasPrefix("refs/heads/") }.sorted()
        let matching = heads.filter { references["HEAD"] == nil || references[$0] == references["HEAD"] }
        return (matching.first(where: { $0 == "refs/heads/main" }) ?? matching.first).map { String($0.dropFirst(11)) }
    }

    func fetchRequest() throws -> Data {
        let wants = Set(wantedReferences.values).sorted { $0.hex < $1.hex }
        var selected = [String]()
        guard capabilities.contains("side-band-64k") || capabilities.contains("side-band") else {
            throw GitError.unsupportedFeature("Git server without side-band support")
        }
        selected.append(capabilities.contains("side-band-64k") ? "side-band-64k" : "side-band")
        if capabilities.contains("ofs-delta") { selected.append("ofs-delta") }
        if capabilities.contains("object-format=\(algorithm.rawValue)") { selected.append("object-format=\(algorithm.rawValue)") }
        var data = Data()
        for (index, want) in wants.enumerated() {
            let suffix = index == 0 ? " " + selected.joined(separator: " ") : ""
            data.append(try GitPacket.encode(Data("want \(want.hex)\(suffix)\n".utf8)))
        }
        data.append(Data("0000".utf8))
        data.append(try GitPacket.encode(Data("done\n".utf8)))
        return data
    }
}

enum GitUploadPackResponse {
    static func extract(_ response: URL, to pack: URL, limit: Int) throws {
        let reader = try GitFileReader(response, limit: limit)
        try Data().write(to: pack, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: pack)
        defer { try? output.close() }
        var receivedNAK = false
        var terminated = false
        var packBytes = 0
        while reader.offset < reader.size {
            try Task.checkCancellation()
            guard let packet = try GitPacket.read(from: reader) else {
                guard reader.offset == reader.size else { throw GitError.invalidProtocol("data after final flush") }
                terminated = true
                break
            }
            if !receivedNAK {
                guard packet == Data("NAK\n".utf8) else { throw GitError.invalidProtocol("expected initial NAK") }
                receivedNAK = true
                continue
            }
            guard let channel = packet.first else { throw GitError.invalidProtocol("empty side-band packet") }
            switch channel {
            case 1:
                let bytes = packet.dropFirst()
                packBytes += bytes.count
                guard packBytes <= limit else { throw GitError.sizeLimitExceeded(limit) }
                try output.write(contentsOf: bytes)
            case 2: break // Remote progress text is not executed or shown as an application instruction.
            case 3: throw GitError.invalidProtocol("remote upload-pack failed")
            default: throw GitError.invalidProtocol("unknown side-band channel")
            }
        }
        guard receivedNAK, packBytes > 0, terminated else { throw GitError.invalidProtocol("incomplete pack response") }
    }
}
