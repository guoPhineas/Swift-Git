# Swift-Git

A Swift implementation of Git storage and operations for iOS 26+ and macOS 26+.
The implementation is written independently from Git's format specifications.
There is no libgit2 dependency and no Git process execution in the library.
CryptoKit, system zlib and the independently MIT-licensed SHA1DC primitive provide
hashing, compression and SHA-1 collision detection. See [third-party notices](THIRD_PARTY.md).

## Implemented capabilities

- Swift 6 language mode and checked Sendable/actor isolation.
- SHA-1 and SHA-256 object IDs; binary-safe raw blob/tree/commit/tag objects.
- Validated tree parsing and canonical tree ordering, including byte filenames.
- Bounded zlib decoding, object header/size validation and content hash checks.
- New working repository creation, conservative configuration validation and opening.
- Actor-isolated loose-object reads/writes with exclusive object publication.
- Swift Testing tests including bidirectional interchange with Apple Git 2.54.0.
- A deterministic Release hashing microbenchmark.
- Public HTTPS full clone using Git Smart HTTP protocol v0/v1.
- Disk-backed pack transfer, pack v2/v3 parsing, OFS_DELTA and forward REF_DELTA resolution.
- SHA1DC validation of incoming SHA-1 pack/object data and reference type/connectivity checks.
- Initial checkout and index v2 generation, origin tracking refs, tags and branch configuration.
- Atomic publication into a new destination; cancellation/failure removes the unpublished clone.
- Tests against official upload-pack, clean native Git status/fsck and opt-in live GitHub clones.
- Local HEAD/loose and packed-reference resolution, typed commit history across merge parents.
- HEAD/index/worktree status, ignore rules, staged and unstaged before/after comparisons.
- Stage and unstage exact file paths, including deletions, with index v2/v3 decoding.
- Local commits of the index with author identity, tree generation and locked atomic ref updates.

```swift
import Foundation
import Swift_Git

let repository = try await GitRepository.create(at: workspaceURL, algorithm: .sha256)
let object = GitObject(kind: .blob, body: Data("Hello, Git!\n".utf8))
let id = try await repository.writeObject(object)
let restored = try await repository.readObject(id)
```

Writing a raw commit object does **not** update HEAD. Use the index/ref workflow:

```swift
let status = try await repository.status()
try await repository.stage(paths: ["README.md"])
let commit = try await repository.commit(
    message: "Update README",
    author: GitAuthor(name: "Phineas Guo", email: "phineas@example.com")
)
let history = try await repository.log(limit: 200)
```

```swift
let remote = try GitRemoteURL("https://github.com/octocat/Hello-World.git")
let cloned = try await GitRepository.clone(from: remote, to: newWorkspaceURL) { progress in
    // Send progress to your UI actor; this callback can run off the main actor.
}
```

The clone destination must not exist. An existing destination is never replaced.

## Validation

Requires Xcode 27.1 / Swift 6.4 or newer. From this directory:

```sh
swift test
swift test -c release
swift run -c release swift-git-benchmark
SWIFT_GIT_NETWORK_TESTS=1 swift test --filter publicHTTPSClone
```

The official Git executable is used only by macOS integration tests. Tests isolate
Git configuration and generate temporary repositories; they do not copy Git tests.

## Current limits

This is still a development Git client. Clone downloads to disk and unpacks objects
into the loose object store; it does not retain a permanent pack/index. Individual
objects are buffered with a 64 MiB default limit. Default clone budgets are 128 MiB
of HTTP response data, 512 MiB of expanded objects, 250,000 pack entries and 100,000
checkout entries. Limits are configurable through GitCloneOptions and fail explicitly.
Delta chains are bounded to 128 levels and directory nesting to 256.

Checkout preserves regular/executable files and symlinks. Gitlinks are recorded in
the index and created as empty directories; submodule contents are not downloaded.
Unsafe .git paths, case/normalization collisions and unsupported checkout filenames
are rejected before the clone is published. Symlinks are installed last.

Authentication, SSH, protocol v2, shallow/partial clone and server-side filters are
not implemented yet. SHA-256 is tested against official upload-pack fixtures;
actual hosting support depends on the server. Existing packed repositories cannot
yet be read through readObject. Fetch/pull/push, attributes conversion and reftable
remain pending. Initial checkout preserves raw
blob bytes rather than applying executable filters or platform line-ending conversion.

The minimal config parser accepts the plain configuration written here and rejects
unsupported syntax/features rather than pretending full Git config compatibility.
The nonthrowing GitObject.id(using:) is a raw format hash; persisted and incoming
objects use the throwing collision-checked checksum path.

Clones retain their local `.git` directory, loose objects, refs, HEAD, config and
index. Removing the temporary transfer pack does not remove its unpacked objects
or history. Status, staging, commits and history reopen this on-disk data; they do
not use an in-memory imitation of a repository.

Status hashes saved bytes, includes executable and symlink changes, and applies
hierarchical `.gitignore` plus `.git/info/exclude` (including negation, directory
rules and globstar). Global excludes and attributes/clean filters are not applied.
Worktree scans are capped at 100,000 entries and 512 MiB of content, each file at
the repository's object limit. Ignored untracked files are not force-added.
Uninitialized gitlinks are preserved; initialized submodule status is unsupported.
Index v4, conflicted/extended/split/sparse indexes and mandatory extensions fail
explicitly. Local commits do not run hooks, sign commits, write reflogs, or finish
merge/rebase/cherry-pick operations. Existing lock files are respected, not removed.
History pages walk all HEAD parents, load up to 10,000 commits, and bound retained
presentation data to 32 MiB. Branch selection and a graphical DAG remain future work.

## Implementation order

1. **Implemented:** hashes, byte parsing, raw objects, trees and loose storage.
2. **Implemented clone slice:** pack/delta decoding, HTTPS v0/v1, initial index/refs/checkout.
3. **Implemented local workflow:** status, ignores, staging, local commits and HEAD history.
   **Next:** attributes, reflogs, broader index support and safe branch switching.
4. Permanent pack/index storage, reftable transactions, protocol v2 and incremental fetch.
5. Depth/deepen/unshallow, blob:none and blob:limit promisor fetch.
6. Diff, merge bases, conflict resolution, pull and push.
7. Broader fuzzing, crash-recovery testing and mobile performance baselines.

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
