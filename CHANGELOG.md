# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.7.0 - 2026-11-01

### Added

- **Cursor-aware segment reclamation (M72)**：maintenance commands enumerate
  all consumer cursors and skip segments that still hold unconsumed records;
  `compact` / `compact-expired` / `import` renumber offsets and now warn that
  cursors must be reset. Documented under「游标与段回收语义（M72）」.
- **Selective fsync (M73)**：`Segment.fsync_dirty` tracks segments with data not
  yet fsynced; `Log::flush` / `SyncPolicy::Always` only fsync those, so a
  many-segment directory no longer pays an fsync per segment per write.
  **Behaviour change**: `flush()` is now idempotent — calling it again without
  new appends is a no-op.
- **`fsck fast` (M74)**：`Log::verify_fast` checks segment contiguity, counter
  consistency and the stored whole-segment CRC32 without decoding record
  bodies; exposed as `fsck <dir> fast`. It cannot detect corruption inside
  individual records — `fsck <dir>` (full) remains the thorough check.
- **Operations guide (M75)**：README gains an operations section (fd limits vs
  segment count, maintenance cadence, cursor/reclamation semantics).

## 0.6.0 - 2026-11-01

### Added

- **Native crash-injection property test (M67)**：the randomized-op property
  test now also runs against the file backend, periodically simulating a torn
  tail (truncating the last segment's data file after fsync) and rebuilding the
  model from the surviving record count.
- **Point-lookup folding (M68)**：`snapshot` / `scan_live` collect the live view
  through the key index (one point lookup per live key, then sorted by offset)
  instead of a second full scan, which pays off once many records have been
  superseded or deleted.
- **In-memory timestamp samples (M69)**：`Segment` keeps a ts sample array
  alongside the sparse index (filled by append/rebuild), so
  `Segment::lower_bound_ts` locates the target with a binary search over
  samples (no I/O) plus at most one interval walk; freshly loaded segments
  without samples fall back to the point-probe binary search.
- **`maintain` command (M70)**：one-shot maintenance that merges contiguous
  rolled-over segments down to a target count, drops fully-superseded segments,
  optionally folds away expired records (`<ttl>`), and finishes with an fsck
  report.

## 0.5.0 - 2026-11-01

### Added

- **Property test (M62)**：a deterministic (fixed-seed xorshift64) randomized
  sequence of puts/deletes/reads is checked against an in-memory model while
  segments roll, followed by a full `verify` — guarding the live view and
  integrity against regressions beyond fixed test cases.
- **Expire-aware compaction (M63)**：`Log::compact_expired(now, ttl, on_drop)`
  folds the log like `compact` but also drops keys whose latest record is a
  tombstone or an expired put, closing the loop on TTL space reclamation;
  exposed as the `compact-expired <dir> <ttl>` CLI command. Offsets are
  renumbered (same as `compact`).
- **Compare-and-swap (M64)**：`Log::compare_and_swap(key, expected, value, ts)`
  appends only when the current live value matches `expected` (or, with
  `expected = None`, only when the key has no live record); exposed as the
  `put-if <dir> <key> <expected|-> <value>` CLI command.
- **Sidecar write amplification (M65)**：segments track a `meta_dirty` flag;
  `flush_meta` now rewrites `.index`/`.keys` only for changed segments (new or
  rolled segments, checksum/compression updates) instead of every segment on
  every write command.

## 0.4.0 - 2026-11-01

### Added

- **Persisted key index (M47)**：each segment keeps an in-memory key → latest
  offset map (with tombstone flags), persisted to a `.keys` sidecar by
  `flush_meta`. Reopening loads it directly (falling back to a rebuild scan when
  missing or corrupt), so key-index-based reads no longer re-scan segments.
- **Table-driven CRC32 (M48)**：`crc32` now uses a 256-entry lookup table built
  once at load instead of a bit-by-bit loop.
- **In-segment time index (M49)**：segments track whether their timestamps are
  non-decreasing (persisted in metadata v6); `scan_time_range` binary-searches
  sorted segments for the `[lo, hi)` offset window and falls back to a linear
  filter for unsorted ones.
- **LZSS segment compression (M50)**：`core.lz_compress` / `lz_decompress`
  (4 KiB window) complement RLE. The `compress` CLI command takes an optional
  `rle` / `lzss` (default) argument, and metadata v7 records which algorithm a
  segment uses so it is decompressed correctly on reopen.
- **Superseded-segment GC (M51)**：`Log::prune_superseded` drops rolled-over
  segments every record of which a later record supersedes (same-key put or
  tombstone), reclaiming space without renumbering offsets; exposed as the
  `prune-superseded` CLI command.
- **Lock timeouts (M52)**：`DirLock::acquire_timeout` retries a busy `flock` for a
  bounded time (new `nanosleep` stub) so concurrent writers queue instead of
  failing fast; the CLI waits up to `MOONLOG_LOCK_TIMEOUT` ms (default 5000).
- **CLI dry-run and batched keys (M53)**：`compress` and `prune-superseded`
  accept `dry-run` (reporting counts via `count_compressible_segments` /
  `Log::count_superseded` without changing anything); `get-many` also accepts
  `--keys <file>` to read newline-separated keys.
- **Complexity guard for key index (M54)**：a `CountReader` test asserts
  `build_key_index` reads no record bodies, pinning the O(keys) cost added in
  M47 against regressions.
- **Native example (M55)**：`examples/native_demo` demonstrates the file backend
  end to end (open, append/delete, live view, key-range scan, per-segment stats).
- **Metadata compatibility tests (M56)**：tests build segment-meta buffers for
  every historical layout (v1–v7) and assert the current reader decodes each,
  guarding backward compatibility.
- **Crash-consistency tests (M57)**：tests corrupt the `.index` sidecar and
  delete the manifest / `.index` / `.keys` files, then assert `open_log_dir`
  still recovers the records and rebuilds the key index from segment data alone.
- **Segment merging (M58)**：`Log::merge_segments` merges offset-contiguous
  rolled-over segments into fewer segments while preserving logical offsets;
  exposed as the `merge <dir> <max-segments>` CLI command.
- **Cached key index (M59)**：`Log::build_key_index` memoizes its result and
  invalidates it on any mutation (append/delete/retention/prune/merge/compact),
  so repeated KV queries in one process rebuild the index at most once per
  change. `Log::index_build_count` exposes the actual build count.
- **More complexity guards (M60)**：tests assert `scan_range` reads only its
  requested window and `scan_time_range` skips segments that cannot overlap,
  complementing the M54 key-index guard.

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