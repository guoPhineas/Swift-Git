# Swift-Git

Swift-Git is a reusable Git framework for iOS and macOS. It provides asynchronous Swift APIs for repository storage, HTTPS synchronization, commits, branches, history and merge workflows.

The repository engine implements Git object formats and network protocols directly. It uses CryptoKit, system zlib and SHA1DC for hashing, compression and SHA-1 collision detection, without requiring an installed Git executable or libgit2 at runtime.

## Capabilities

| Area | Supported functionality |
| --- | --- |
| Objects | SHA-1/SHA-256 IDs; blobs, trees, commits and tags; loose and packed storage |
| Pack files | Pack v2/v3, OFS_DELTA/REF_DELTA, pack index v1/v2 reads and v2 writing |
| Transport | Smart HTTPS protocol v0/v1/v2, full-history clone, incremental fetch and branch push |
| Local changes | HEAD/index/worktree status, ignore rules, stage/unstage and file comparisons |
| Commits | Author metadata, tree creation, reflogs, merge parents and review-state validation |
| References | Loose/packed refs, local/remote branches, upstream configuration and lightweight tags |
| Checkout | Branch switching and detached checkout with worktree protection |
| Merge | Merge-base lookup, fast-forward/three-way merge, conflict resolution, continuation and abort |
| History | Topologically ordered commit history, changed-file lists and comparisons against selected parents |
| Transactions | Git-compatible locks, mutation journals, rollback and interrupted-operation recovery |

`GitRepository` is an actor. Repository operations expose `async`/`throws` call sites and use `Sendable` values for results and progress reporting.

## Requirements

- Swift 6.4 and Swift 6 language mode
- iOS 18 or macOS 15 and later
- Xcode 27.1 for Apple-platform development

## Package integration

The library product is named `Swift-Git`; its Swift module is `Swift_Git`. For a local checkout, add the package and product to the consuming manifest:

```swift
dependencies: [
    .package(url: "https://github.com/guoPhineas/Swift-Git.git")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "Swift-Git", package: "Swift-Git")]
    )
]
```

```swift
import Swift_Git
```

## Local repository workflow

Create a repository, write a working file, stage it and create a commit:

```swift
import Foundation
import Swift_Git

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
let repository = try await GitRepository.create(at: directory)

try Data("# Example\n".utf8)
    .write(to: directory.appendingPathComponent("README.md"))
try await repository.stage(paths: ["README.md"])

let author = try GitAuthor(name: "Example Developer", email: "dev@example.com")
let id = try await repository.commit(message: "Initial commit", author: author)
let history = try await repository.log(limit: 200)
let changes = try await repository.changes(in: id)
```

Use `GitRepository.open(at:)` to reopen an existing working repository. New repositories default to SHA-1; pass `algorithm: .sha256` to create a SHA-256 repository. `readObject` and `writeObject` provide access to raw Git storage.

### Commit review

A commit UI can capture the state being reviewed and require that state when committing:

```swift
let review = try await repository.prepareCommit()
// Present review.status and review.suggestedMessage in the interface.
let id = try await repository.commit(
    message: "Update documentation",
    author: author,
    expectedState: review.state
)
```

Changes to the branch, index or pending merge cause `GitError.commitStateChanged`. The caller can refresh the review before retrying. Commits include the index only; working-file edits made after staging remain unstaged.

## Remote repositories

```swift
let remote = try GitRemoteURL("https://github.com/octocat/Hello-World.git")
let repository = try await GitRepository.clone(from: remote, to: destinationURL)
let fetched = try await repository.fetch()
```

The clone destination must not exist. Clone retains the repository's local `.git` data and permanent pack/index files. Fetch updates remote-tracking refs and `FETCH_HEAD` without changing working files.

Authenticated operations accept credentials separately from the remote URL:

```swift
var options = GitCloneOptions()
options.credential = try GitHTTPCredential(password: accessToken)

let fetched = try await repository.fetch(options: options)
let merged = try await repository.pull(options: options)
let pushed = try await repository.push(credential: options.credential)
```

The caller supplies and stores credentials. Remote URLs must use HTTPS and exclude embedded credentials, queries and fragments. Network sessions are ephemeral and reject cross-origin redirects. Push checks remote ancestry and does not force branch updates. Fetch publishes validated references individually under their locks.

### Branches and merges

```swift
try await repository.createBranch("feature")
try await repository.switchBranch("feature")
let branches = try await repository.branches()
```

Branch switches and merges require a clean worktree. Checkout protects unrelated untracked and ignored files. `setUpstream` configures tracking; `checkoutDetached` opens a commit without selecting a branch.

`merge` and `pull` return `GitMergeResult`: up to date, fast-forward, ready to commit, or conflicts. Non-fast-forward merges remain pending until the caller creates the merge commit. Conflicts can be resolved by selecting a side or editing the working file and staging it. `abortMerge` restores the pre-merge state for merges started by Swift-Git. Pending conflicts survive repository reopening.

## Resource limits

Default clone/fetch limits are configurable through `GitCloneOptions`:

| Resource | Default limit |
| --- | --- |
| Network response | 128 MiB |
| Individual object | 64 MiB |
| Expanded pack contents | 512 MiB |
| Objects in a received pack | 250,000 |
| Checkout entries | 100,000 |
| Delta chain depth | 128 |

Worktree scans are bounded to 100,000 entries and 512 MiB of content. Three-way text merge supports up to 2 MiB and 6,000 total input lines. History returns up to 10,000 commits per request and bounds retained presentation data at 32 MiB.

Packed storage verifies checksums, caches a small number of indexes and reads objects on demand. Existing pack indexes are limited to 250,000 entries and 16 MiB; pack files are limited to `UInt32.max` bytes. Push writes full objects with 128 MiB output and 512 MiB expanded-content limits.

## Compatibility

Swift-Git supports files-based refs and full-history HTTPS repositories. Unsupported mandatory repository features return explicit errors.

The following functionality is not implemented:

- SSH, Git LFS, reftable and shallow/partial/promisor clones.
- Rebase, cherry-pick/revert, stash and commit signing.
- Linked worktrees, submodule management and repository maintenance commands.
- Index v4, extended/sparse/split indexes and initialized-submodule status.
- Executable hooks, attributes filters, line-ending conversion and global ignore files.
- Automatic rename/directory conflict resolution, unrelated-history merges and recursive multiple merge bases.
- The complete Git configuration language, includes, arbitrary refspecs and URL rewriting.

Checkout preserves raw blob bytes, executable modes and symbolic links. Gitlinks are recorded in the index and represented by empty directories. Case/normalization collisions, unsafe metadata paths and unsupported filenames are rejected.

Journal recovery removes only matching locks owned by an exited transaction process. External changes, storage-provider failures or a crash before journal creation can require manual inspection. Once a journaled mutation starts, it completes or rolls back before honoring further cancellation. SHA-256 hosting support depends on the server.

## Build, tests and benchmarks

```sh
swift build
swift test
swift test -c release
```

The macOS integration tests use native Git as a fixture server and interoperability oracle. They cover SHA-1/SHA-256, upload-pack/receive-pack, protocol negotiation, packed storage, status, commits, tracking, checkout, merge conflicts and transaction recovery. Native Git is used by tests only.

Enable public GitHub clone tests with:

```sh
SWIFT_GIT_NETWORK_TESTS=1 swift test -c release
```

Run the deterministic object-hashing benchmark with:

```sh
swift run -c release swift-git-benchmark
```

## Git format references

- [Repository layout](https://git-scm.com/docs/gitrepository-layout)
- [Pack format](https://git-scm.com/docs/gitformat-pack)
- [Index format](https://git-scm.com/docs/gitformat-index)
- [HTTP protocol](https://git-scm.com/docs/gitprotocol-http)
- [Pack protocol](https://git-scm.com/docs/gitprotocol-pack)
- [Protocol v2](https://git-scm.com/docs/gitprotocol-v2)

## License

Swift-Git is available under the [MIT License](LICENSE). SHA1DC is separately MIT-licensed; its attribution and bundled license are documented in [THIRD_PARTY.md](THIRD_PARTY.md).
