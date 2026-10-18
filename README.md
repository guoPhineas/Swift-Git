# Swift-Git

An independent Swift Git engine for iOS 26+ and macOS 26+, built from Git's public
format/protocol specifications. The library does not execute Git, use libgit2, or
translate/copy Git's GPL implementation. CryptoKit, system zlib and the independently
MIT-licensed SHA1DC primitive provide hashing, compression and collision detection.
See [third-party notices](THIRD_PARTY.md).

## Implemented capabilities

- Swift 6 actor isolation and Sendable APIs; binary-safe SHA-1/SHA-256 objects.
- Loose-object read/write, validated trees/commits/tags, packed refs, permanent pack
  files and pack index v1/v2 reads with object/hash validation.
- Smart HTTPS full-history clone over protocol v0/v1/v2, `ls-refs`, incremental fetch
  negotiation, origin tracking refs, tags, FETCH_HEAD and initial branch configuration.
- Pack v2/v3 decoding, OFS_DELTA/REF_DELTA, bounded delta expansion, canonical pack
  index v2 writing with CRCs, and retained packs after clone/fetch.
- Optional HTTPS credentials supplied in memory; credentials are excluded from Git
  config/remote URLs. Ephemeral HTTP sessions reject cross-origin redirects.
- Push with receive-pack report-status, bounded outgoing packs, server compare-and-swap
  ref updates and rejection of non-fast-forward branch updates.
- Saved-byte status for HEAD/index/worktree, hierarchical ignore rules, executable
  and symbolic link changes, exact-path stage/unstage and before/after comparisons.
- Index v2/v3, including standard merge conflict stages 1/2/3.
- Commit author/committer data, index tree generation, locked ref updates and reflogs.
- Commit preparation with an opaque review snapshot; optional expected-state checks
  reject index, branch or pending-merge changes while allowing unstaged file edits.
- Branch listing/create/switch, tracking configuration, detached checkout, safe
  deletion of merged branches and lightweight tag creation.
- Fast-forward and bounded three-way merge, merge-base lookup, text conflict markers,
  binary/add/delete conflicts, choose-side or edit-and-stage resolution, merge commit
  continuation, and abort of merges started by this library.
- Pull as fetch plus merge, protecting against a branch/HEAD change while fetching.
- Recoverable worktree/index/ref transactions, rollback, persistent journals and
  reopening recovery for interrupted operations. Existing unrelated locks are respected.
- Typed history across all merge parents, topological ordering, commit changed-file
  lists and file comparison against a selected parent.

```swift
import Foundation
import Swift_Git

let remote = try GitRemoteURL("https://github.com/octocat/Hello-World.git")
let repository = try await GitRepository.clone(from: remote, to: newWorkspaceURL)
let status = try await repository.status()
try await repository.stage(paths: ["README.md"])
let commit = try await repository.commit(
    message: "Update README",
    author: GitAuthor(name: "Phineas Guo", email: "phineas@example.com")
)
let history = try await repository.log(limit: 200)
let changes = try await repository.changes(in: commit)
```

For a reviewable commit UI, use a snapshot rather than committing an unseen index:

```swift
let review = try await repository.prepareCommit()
// Show review.status and review.suggestedMessage to the user.
let reviewedCommit = try await repository.commit(
    message: message,
    author: author,
    expectedState: review.state
)
// GitError.commitStateChanged requires refreshing and reviewing again.
```

Authenticated network operations accept a caller-provided credential:

```swift
var options = GitCloneOptions()
options.credential = try GitHTTPCredential(password: accessToken)
let fetched = try await repository.fetch(options: options)
let result = try await repository.pull(options: options)
// A non-fast-forward pull can require resolution and an explicit merge commit.
let pushed = try await repository.push(credential: options.credential)
```

The clone destination must not exist; a failed/cancelled unpublished clone is removed.
Fetch updates remote-tracking refs without changing the current worktree. Branch
switches/merges require a clean worktree and protect unrelated untracked/ignored files.
Push never forces a branch update. Fetch publishes each validated ref under its lock;
it is not a single atomic update of every advertised ref.

`GitRepository.create`, `open`, `readObject` and `writeObject` also expose raw storage
for reusable framework clients. Writing a raw commit object alone does not move HEAD.

## Build and tests

Requires Xcode 27.1 / Swift 6.4 or newer.

```sh
swift test
swift test -c release
SWIFT_GIT_NETWORK_TESTS=1 swift test -c release
swift run -c release swift-git-benchmark
```

macOS integration tests use the official Git executable only as an independent
fixture server/oracle. The production library never runs it. Temporary repositories
isolate user Git configuration. Tests cover SHA-1/SHA-256, real upload-pack/receive-pack
exchanges, v2 with and without the HTTP service preamble, empty repos, fetch/push,
non-fast-forward rejection, packed storage after native gc, tracking configuration,
checkout protection, conflict continuation/abort, journal recovery and historical
diffs. Native status/fsck check interoperability. Opt-in tests clone a real public
GitHub repository with and without a `.git` URL suffix.

## Limits and unsupported features

This is a development Git client, not a drop-in implementation of every Git command.
The current scope is full-history HTTPS repositories with files refs. Reftable,
SSH/LFS and shallow/partial/promisor clones are deferred by the project decision.
Rebase, cherry-pick/revert, stash, commit signing, linked worktrees, submodule
management and repository maintenance commands are not implemented.

Clone/fetch default budgets are 128 MiB HTTP data, 512 MiB expanded objects, 64 MiB
per object, 250,000 pack objects, 100,000 checkout files, 128 delta levels and 256
directory levels. Clone budgets are configurable through GitCloneOptions. Push uses
128 MiB output/512 MiB expanded budgets and writes full objects, without outgoing
delta optimization. Existing pack index reads are capped at 250,000 objects and
16 MiB index data; pack files at UInt32.max bytes, individual objects at the repository
limit. Packs are checksum-verified on cache load, then selected objects are read on
demand. Changing the pack invalidates the small index cache.

Checkout preserves raw regular/executable/symlink blob data; it does not run hooks,
attributes filters or line-ending conversion. Gitlinks are recorded in the index and
created as empty directories. Unsafe `.git` paths, case/normalization collisions and
unsupported filenames are rejected. Initialized submodule status is unsupported.

Status applies hierarchical `.gitignore` and `.git/info/exclude`, including negation,
directory patterns and globstar. Global excludes and attributes are not applied.
Scans are capped at 100,000 entries/512 MiB content. Ignored untracked files are not
force-added. Index v4, extended/split/sparse indexes and mandatory extensions fail
explicitly. The conservative config parser supports quoted values/subsections, but
not the complete Git config language, includes, arbitrary refspecs or URL rewriting.

Three-way text merge is bounded to 2 MiB and 6,000 total input lines; larger/binary
conflicts can be resolved by selecting a side or editing externally. Automatic rename
and complex directory conflict resolution, unrelated histories and recursive multiple
merge bases are unsupported. Non-fast-forward clean merges remain pending until the
caller creates a merge commit. Reopening preserves pending conflicts.

Transaction journals retain before/after data and known lock identities. Recovery
only removes matching journal-owned locks after confirming the owning process is
gone; it never blindly clears another client's locks. Filesystem/provider failures
can still require recovery, and a crash before a journal exists may leave a normal
Git lock requiring inspection. This is not a guarantee against every power-loss or
concurrent external writer scenario. Cancellation stops before mutation or transfer;
once a journaled mutation starts, completion/rollback finishes without cancellation.

History walks HEAD ancestors, presents at most 10,000 commits and bounds retained
presentation data at 32 MiB. SHA-256 support is tested against native Git; remote host
support depends on the server. The nonthrowing `GitObject.id(using:)` is a raw format
hash; persisted/incoming objects use the collision-checked checksum path.

## Performance and next validation

Object hashing feeds header/body separately, parsers use Data slices, transfers use
temporary files, and permanent pack/index storage avoids retaining a loose copy of
every cloned object. Packed reads cache a small number of verified indexes; history
uses a priority heap and topological ordering. These are implementation choices,
not evidence of being faster than C Git.

The benchmark reports deterministic 1 MiB hashing. Release work still needs broader
fuzzing, real-device memory/latency measurements, large-repository workloads,
File Provider failure tests and power-loss/crash matrices before production claims.

## References

- [Repository layout](https://git-scm.com/docs/gitrepository-layout)
- [Pack format](https://git-scm.com/docs/gitformat-pack)
- [Index format](https://git-scm.com/docs/gitformat-index)
- [HTTP protocol](https://git-scm.com/docs/gitprotocol-http)
- [Pack protocol](https://git-scm.com/docs/gitprotocol-pack)
- [Protocol v2](https://git-scm.com/docs/gitprotocol-v2)

Original code remains under this repository's MIT license. Preserve the separate
SHA1DC notices. Reusing third-party source requires its own license review; a change
of implementation language does not remove the original source's obligations.
