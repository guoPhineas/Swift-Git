# Swift-Git

A Swift implementation of Git storage and operations for iOS 26+ and macOS 26+.
The implementation is written independently from Git's format specifications.
There is no libgit2 dependency and no Git process execution in the library.
CryptoKit and system zlib provide hashing and compression.

## Implemented foundation

- Swift 6 language mode and checked Sendable/actor isolation.
- SHA-1 and SHA-256 object IDs; binary-safe raw blob/tree/commit/tag objects.
- Validated tree parsing and canonical tree ordering, including byte filenames.
- Bounded zlib decoding, object header/size validation and content hash checks.
- New working repository creation, conservative configuration validation and opening.
- Actor-isolated loose-object reads/writes with exclusive object publication.
- Swift Testing tests including bidirectional interchange with Apple Git 2.54.0.
- A deterministic Release hashing microbenchmark.

```swift
import Foundation
import Swift_Git

let repository = try await GitRepository.create(at: workspaceURL, algorithm: .sha256)
let object = GitObject(kind: .blob, body: Data("Hello, Git!\n".utf8))
let id = try await repository.writeObject(object)
let restored = try await repository.readObject(id)
```

Writing a raw commit object does **not** update HEAD, stage files or perform a
user-facing commit. Those workflows must be implemented with index/ref transactions.

## Validation

Requires Xcode 27.1 / Swift 6.4 or newer. From this directory:

```sh
swift test
swift test -c release
swift run -c release swift-git-benchmark
```

The official Git executable is used only by macOS integration tests. Tests isolate
Git configuration and generate temporary repositories; they do not copy Git tests.

## Current limits

This is a development foundation, not yet a general-purpose Git client. Objects
are buffered with a configurable 64 MiB default safety limit; large-object streaming
and pack support are pending. `readObject` accesses loose objects only; a missing
object may be packed and is not automatically considered repository corruption.
The minimal config parser accepts the plain configuration written here and rejects
unsupported syntax/features rather than pretending full Git config compatibility.

CryptoKit SHA-1 is format-compatible hashing, **not SHA1DC collision detection**.
Untrusted remote repository support is not ready for release until collision defense,
hostile-input testing and protocol validation are complete.

## Implementation order

1. **Foundation (implemented):** hashes, byte parsing, raw objects, trees, loose store.
2. **Local workflows:** index, transactional refs/reflog, status, ignore/attributes,
   typed commits, history and safe checkout.
3. **Packed storage:** pack/delta/index readers and writers; reftable transactions.
4. **Remote reads:** HTTPS Smart HTTP, protocol v2 with v0/v1 compatibility.
5. **Extended clone:** depth/deepen/unshallow, blob:none and blob:limit promisor fetch.
6. **Integration:** diff, merge bases, conflict resolution, pull and push.
7. **Hardening:** interoperability matrix, fuzzing, interruption recovery and mobile benchmarks.

All release requirements include SHA-1/SHA-256 and files/reftable combinations.
SHA-256 conversion, arbitrary partial-clone filters, SSH, LFS, sparse/split index,
linked worktrees, submodule management and executable hooks/filters are deferred.

## Performance

Current hashing updates the header and body separately, avoiding an extra combined
buffer for object IDs. Byte parsing uses Data slices until an owned value is needed.
The benchmark reports 100 hashes of deterministic 1 MiB input; it is a starting
measurement, not evidence of being faster than C Git. Next baselines cover status,
history first-page latency, diff, allocation counts, peak memory and cancellation.

## References

- [Git repository layout](https://git-scm.com/docs/gitrepository-layout)
- [Pack format](https://git-scm.com/docs/gitformat-pack)
- [Index format](https://git-scm.com/docs/gitformat-index)
- [HTTP protocol](https://git-scm.com/docs/gitprotocol-http)
- [Protocol v2](https://git-scm.com/docs/gitprotocol-v2)
- [Reftable specification](https://github.com/git/git/blob/master/Documentation/technical/reftable.adoc)

Original code remains under the repository's MIT license. Any future third-party
source reuse requires separate license review; changing implementation language
does not remove the source's license obligations.
