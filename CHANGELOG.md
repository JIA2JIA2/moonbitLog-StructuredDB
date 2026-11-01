# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- **Persisted key index (M47)**：each segment keeps an in-memory key → latest
  offset map (with tombstone flags), persisted to a `.keys` sidecar by
  `flush_meta`. Reopening loads it directly (falling back to a rebuild scan when
  missing or corrupt), so key-index-based reads no longer re-scan segments.

## 0.3.0 - 2026-11-01

### Added

- **Key prefix scan (M33)**：`Log::scan_prefix` returns the latest live record
  for every key matching a byte prefix, sorted by key; exposed as the
  `scan-prefix` CLI command.
- **Segment Bloom filters (M34)**：each segment carries a Bloom filter over its
  keys, persisted in `.index` (metadata v2, v1 still readable as a disabled
  filter). `Log::get_latest_bloom` skips segments that cannot contain a key;
  the `has-key` CLI command uses it.
- **Time-range queries (M35)**：each segment records its min/max timestamp in
  `.index` (metadata v3; v1/v2 read back as "span unknown"). `Log::scan_time_range`
  skips segments that cannot overlap a `[lo, hi)` window; exposed as the
  `scan-time` CLI command.
- **Key range scan (M36)**：`Log::scan_key_range` returns the latest live record
  for every key in the half-open range `[lo, hi)`, sorted by key bytes (an empty
  `hi` is unbounded above); exposed as the `scan-range` CLI command.
- **Binary-safe key index (M37)**：the key index now keys on raw key bytes rather
  than a lossy UTF-8 decoding, so distinct binary keys can no longer collapse
  into one another; `scan_prefix` likewise matches raw bytes.
- **Segment data checksums (M38)**：every rolled-over segment records a CRC32
  over its whole data range in `.index` (metadata v4; older versions read back as
  "unverified"). `Log::verify` reports the first segment whose stored checksum
  does not match via `VerifyReport::first_bad_checksum`.
- **Sorted key index (M39)**：`build_key_index` now keeps its live keys in byte
  order, so `scan_prefix` / `scan_key_range` binary-search the range and
  point-look-up the matching records instead of re-scanning the log and sorting.
- **Batch point lookups (M40)**：`Log::get_many` returns the latest live record
  for each of several keys in one call (sharing a single index scan); exposed as
  the `get-many` CLI command.
- **Reverse scans and tail (M41)**：`Log::scan_reverse` returns a range newest
  first, and `Log::tail` returns the most recent `n` records in append order;
  exposed as the `tail` CLI command.
- **Buffered appends (M42)**：`NativeFileLog` coalesces small appends into fewer
  `pwrite` calls. The buffer is drained before reads, `flush`, `truncate`,
  `close`, and before metadata is written, so the on-disk size matches the
  logical size once a write command returns.
- **Segment compression (M43)**：pure MoonBit RLE (`core.rle_compress` /
  `core.rle_decompress`). The `compress` CLI command RLE-compresses every
  rolled-over segment in place; metadata v5 records the compression flag and the
  uncompressed size, and compressed segments are transparently decompressed into
  a read-only view on open. Older metadata versions read back as uncompressed.
- **Atomic batch append (M44)**：`Log::append_batch_atomic` discards the whole
  batch on failure — dropping segments created by the batch, truncating and
  rebuilding the previously active segment, and restoring the offset space.
- **Observability: per-segment stats (M45)**：`Log::segment_summaries` exposes
  each segment's record count, byte size, compression flag and time span; the
  `stats` CLI command prints them and accepts `json` as a second argument for
  machine-readable output.

## 0.2.0 - 2026-10-31

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
- **Record TTL (M26)**：`Log::get_latest_at` / `Log::scan_live` filter records
  older than a ttl at a given `now`, with `getkey-live` / `prune-expired` CLI
  commands.
- **Named cursor management (M27)**：`list_named_cursors` /
  `remove_named_cursor` and the `cursor-list` / `cursor-drop` CLI commands.
- **Export / import (M28)**：`Log::export_bytes` / `Log::import_bytes` and the
  `export` / `import` CLI commands move records (including tombstones) between
  directories as a self-checking frame stream.
- **Adaptive index interval (M24)**：new segments pick a sparse-index interval
  scaled from `roll_size` via `index_interval_for`, keeping the per-segment
  index size roughly constant.
- **Read path evaluation (M25)**：a read-ahead cache was implemented and
  measured ~3.7× slower than direct `pread` (MoonBit `Bytes` slicing copies
  byte-by-byte), so reads keep using `pread`; a native sequential-scan
  benchmark was added to guard the decision.
- **CI coverage and benchmarks (M29)**：CI now collects native code coverage
  into the run summary and archives benchmark results as an artifact.
- **Architecture docs and release workflow (M30)**：an architecture overview was
  added to the README and a release-triggered workflow verifies and publishes
  the package to mooncakes.io.

### Fixed

- **Flush durability（post-M30 review）**：`Log::flush` now fsyncs **every**
  segment, so `SyncPolicy::Batch` — and `import_bytes` — make rolled-over
  segments durable; previously only the active segment was fsynced, leaving a
  cross-segment batch only partially durable. The CLI `MOONLOG_SYNC` variable
  now also accepts `batch`.
- **CLI durability default（post-M31 review）**：the CLI now defaults to
  `SyncPolicy::Always`, so a write command that returns has fsynced its data;
  `MOONLOG_SYNC` accepts `always` (default), `batch`, and `never` / `0`. The
  README now also documents that `import` reassigns offsets in the target log.

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