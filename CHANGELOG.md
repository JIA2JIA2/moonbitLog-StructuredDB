# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- **Compaction as a library API (M14)**：`Log::compact` folds a log down to its
  live view in place, invoking a callback per dropped segment so the caller can
  reclaim the backing files.
- **Timestamp retention (M15)**：`Log::retain_before` and the `prune-before`
  CLI command drop segments whose last record predates a cutoff.
- **Segment size verification (M16)**：the manifest now records each segment's
  byte size; opening cross-checks the real file size and falls back to a full
  recovery scan when it does not match.
- **Runnable examples (M17)**：`examples/mem_demo` demonstrates the in-memory
  backend end to end on wasm, js and native.
- **Batch append (M18)**：`Log::append_batch` and the `put-batch` CLI command
  append several records in one call.
- **Integrity check (M19)**：`Log::verify` (with `VerifyReport`) and the `fsck`
  CLI command sweep the log for segment gaps, offset jumps and decode errors.
- **Named cursors (M20)**：`save_named_cursor` / `load_named_cursor` and the
  `cursor-save` / `cursor-load` CLI commands persist independent consumer
  positions as `CURSOR.<name>` files.
- **Atomic metadata (M21)**：the manifest and per-segment indexes are replaced
  atomically (write temp → fsync → rename → fsync directory), so a crash can
  never leave a half-written metadata file.
- **Group commit (M22)**：`SyncPolicy::Batch` defers fsync to the end of
  `append_batch`, and `Log::flush` exposes an explicit fsync point.
- **Creation/deletion hardening (M23)**：newly created segment files and
  retention deletions fsync the directory, and cursor files are written
  atomically.

## 0.1.0 - 2026-10-31

First complete release of the append-only event log database, built up over
milestones M0–M13.

### Added

- **Core (M0/M1)**：record encoding/decoding with CRC32, monotonic logical
  offsets, tombstones, and an in-memory reference backend.
- **Multi-segment log (M2)**：`Log` rolls segments at `roll_size`; a native
  file backend (`backend_native`) persists segments via a C stub FFI.
- **Sparse index and range scans (M3)**：per-segment sparse index plus
  `Segment::scan_range` / `Log::scan_range` over half-open intervals.
- **Crash recovery (M4)**：`Segment::recover` / `recover_log_dir` truncate a
  torn or CRC-failing tail back to the last good record boundary.
- **Retention and cursors (M5)**：`drop_before` / `retain_last` /
  `retain_max_bytes` and the resumable `ConsumerCursor`.
- **CLI and docs (M6)**：a native `moonlog` executable and user documentation.
- **Boundary tests (M7)**：extra edge-case coverage and explicit CLI argument
  validation.
- **Persisted metadata (M8)**：per-segment `.index` sidecars and a directory
  `MANIFEST`, so reopening is O(index) instead of O(data), with a full-scan
  fallback when metadata is missing or fails its checksum.
- **Streaming reads (M9)**：`Log::scan` / `scan_range` / `for_each` and a
  streaming cursor `poll`, plus consolidated point-lookup IO.
- **KV view and compaction (M10)**：`KeyIndex`, `Log::get_latest`,
  `Log::snapshot`, and a `compact` command that rewrites the directory with
  live keys only.
- **Durability and byte retention (M11)**：configurable `SyncPolicy`
  (`Never` / `Always`) and byte-budget retention.
- **Concurrency (M12)**：directory-level `flock` advisory locking (exclusive
  writers, shared readers) via `DirLock`, a read snapshot based on
  `next_offset`, and CLI cursor persistence (`CURSOR` file +
  `cursor-commit`).
- **Engineering (M13)**：property/fuzz tests for random truncation and
  in-body corruption recovery, `moon bench` benchmarks, a GitHub Actions CI
  workflow, and expanded API/wasm documentation.