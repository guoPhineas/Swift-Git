# Foundation baseline — 2026-10-16

Host: arm64 macOS 27, Xcode 27.1, Apple Swift 6.4. Release configuration.
Reference Git: Apple Git 2.54.0. These are initial development measurements,
not a comparison against C Git or a device performance guarantee.

## Correctness

- Debug and Release: 10 Swift Testing functions, 32 parameter-expanded cases passed.
- SHA-1 and SHA-256 repositories: Git reads Swift-written blob/tree/commit objects;
  `git fsck --strict` passes; Swift reads Git-written loose objects.
- Header/size validation, invalid object IDs, byte paths, tree ordering, bounded
  decompression, truncation, trailing compressed bytes and hash mismatch covered.

## Initial hash microbenchmark

Command: `/usr/bin/time -l .build/release/swift-git-benchmark` after `swift test -c release`.

| Workload | One observed run |
|---|---:|
| SHA-1, 100 × deterministic 1 MiB blob | 70.14 ms |
| SHA-256, 100 × deterministic 1 MiB blob | 46.68 ms |
| Whole benchmark process maximum resident set size | 8,552,448 bytes |
| Whole benchmark process peak memory footprint | 4,243,984 bytes |

Process memory includes initialization and fixture construction, and is not a
per-hash allocation measurement. This is a single run with scheduling noise;
repeated samples and median/p95 comparisons must precede performance claims.
The benchmark currently measures hashing only, not object-store or app memory.

## App integration

- MobGit: generic iOS Simulator build passed, both arm64 and x86_64.
- Workspace: 5 macOS-hosted tests passed for safe saves, BOM/CRLF/permissions,
  external modifications, persistent drafts, limits and path/symlink checks.
- CodeEditorView pinned to `289d87ce92035467788631fda5516b9f843b9f60`.
- MarkdownView QuoteAlert pinned to `724ebf4d7106cb5c4a920b003a0c7021768f73b6`.
- No simulator launch, Chinese IME/undo interaction or physical-device acceptance
  was performed. Simulator service access was not approved in this session.

## Next measurements

Add deterministic status, history first-page, diff and pack fixtures as those
capabilities become available. Record repeated Release timings, allocations,
peak memory and cancellation latency on a fixed iPhone as well as this host.
