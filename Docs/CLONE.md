# Public HTTPS clone — 2026-10-16

The clone feature is implemented by Swift-Git and exposed in MobGit through
**Add Repository → Clone Repository**. App-authored strings remain English.

## Behavior

- Git Smart HTTP v0/v1 discovery, want negotiation and side-band pack transfer.
- Pack v2/v3, OFS_DELTA and forward REF_DELTA resolution, including SHA-256.
- Pack checksums, collision-checked SHA-1 objects, object reference kinds/connectivity.
- Default branch checkout, index v2, origin remote-tracking branches and tags.
- Executable bits and symlinks preserved; gitlinks recorded with empty directories.
- Downloads stored on disk; clone work stays in a unique sibling directory until
  successful checkout and exclusive atomic publication.
- Cancellation and failure discard the unpublished workspace. Existing destinations
  are never replaced. A failed App catalog save preserves the successful clone and
  offers registration retry without another download.
- Progress covers discovery, receiving, unpacking and checkout. Foreground operation
  is expected; long-running background clone is not promised.

This increment does not implement incremental fetch, private credentials, SSH,
protocol v2, shallow/partial clone, permanent packed storage or general index workflows.
Resource limits and checkout filename restrictions are documented in README.md.
The default client reference store is files; server reference storage is independent.

## Verification completed

- `SWIFT_GIT_NETWORK_TESTS=1 swift test -c release`: **21 test functions passed**,
  including parameterized SHA-1/SHA-256 and live HTTPS cases.
- Official upload-pack fixture clones pass `git fsck --strict` and clean native
  `git status --porcelain`; HEAD, feature branch and annotated tag IDs match.
- Fixture includes binary content, executable scripts, symlinks and a gitlink.
- Known SHA-1 collision input is rejected by SHA1DC.
- Forward/offset deltas, checksum corruption, missing/mistyped object links,
  malformed delta instructions, object/expanded/entry budgets and unsafe paths tested.
- Cancellation test verifies no destination or hidden staging directory remains.
- Real GitHub `octocat/Hello-World` cloned with both `.git` and suffix-free URLs;
  both clones pass official Git status/fsck checks.
- MobGit's 5 workspace tests passed after clone integration.
- Generic iOS Simulator build passed for arm64 and x86_64, without signing.

Simulator launch and physical-device interaction remain unverified because simulator
service access was not approved earlier. No attempt was made to bypass that choice.

## Commands

```sh
# Swift-Git, offline deterministic tests
swift test

# Opt-in network validation and optimized build
SWIFT_GIT_NETWORK_TESTS=1 swift test -c release
```

## Pre-feature commits

The requested baseline commits were created before clone implementation:

- Swift-Git: `128f9e2` — native object storage foundation.
- MobGit: `cc8f343` — SwiftUI workspace and English editor interface.

