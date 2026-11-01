///|
/// A factory that creates a fresh empty segment starting at `base_offset`.
pub type MakeSegment[W, R] = (UInt64) -> @segment.Segment[W, R] raise @io.IoError

///|
/// Durability policy for appends: `Never` leaves flushing to the caller,
/// `Always` fsyncs after every appended record, and `Batch` defers fsync to
/// the end of `append_batch` or an explicit `Log::flush`.
pub(all) enum SyncPolicy {
  Never
  Always
  Batch
} derive(Eq)

///|
pub extend SyncPolicy with Eq::{equal, not_equal}

///|
/// Multi-segment append-only log. Records receive globally monotonic offsets;
/// when the active segment grows past `roll_size` bytes a new segment is
/// created and subsequent records go there. Segments are never modified once
/// rolled over.
pub(all) struct Log[W, R] {
  mut segments : Array[@segment.Segment[W, R]]
  roll_size : Int64
  mut next_offset : UInt64
  make : MakeSegment[W, R]
  sync : SyncPolicy
  mut index_cache : KeyIndex?
  mut index_builds : Int32
  mut cursor_guard : UInt64?
}

///|
pub fn[W, R] Log::new(
  roll_size : Int64,
  make : MakeSegment[W, R],
  sync~ : SyncPolicy = SyncPolicy::Never,
) -> Log[W, R] {
  {
    segments: [],
    roll_size,
    next_offset: 0,
    make,
    sync,
    index_cache: None,
    index_builds: 0,
    cursor_guard: None,
  }
}

///|
/// Assemble a log from already-opened, already-recovered segments in
/// increasing `base_offset` order. The next offset continues from the last
/// segment so that subsequent appends remain contiguous.
pub fn[W, R] Log::recover(
  roll_size : Int64,
  make : MakeSegment[W, R],
  segments : Array[@segment.Segment[W, R]],
  sync~ : SyncPolicy = SyncPolicy::Never,
) -> Log[W, R] {
  let mut next : UInt64 = (0 : UInt64)
  if segments.length() > 0 {
    next = segments[segments.length() - 1].next_offset
  }
  {
    segments,
    roll_size,
    next_offset: next,
    make,
    sync,
    index_cache: None,
    index_builds: 0,
    cursor_guard: None,
  }
}

///|
/// Number of segments currently held by this log.
pub fn[W, R] Log::segment_count(self : Log[W, R]) -> Int32 {
  self.segments.length()
}

///|
/// Total number of records across all segments.
pub fn[W, R] Log::count(self : Log[W, R]) -> Int32 {
  let mut total = 0
  for seg in self.segments {
    total = total + seg.record_count
  }
  total
}

///|
/// Offset that the next appended record will receive.
pub fn[W, R] Log::next_offset(self : Log[W, R]) -> UInt64 {
  self.next_offset
}

///|
/// Set the consumer-cursor guard: segments still holding records at or after
/// `Some(g)` are skipped by retention/prune operations so consumers never lose
/// unread data. `None` disables the guard.
pub fn[W, R] Log::set_cursor_guard(self : Log[W, R], g : UInt64?) -> Unit {
  self.cursor_guard = g
}

///|
/// Whether `seg` still holds records the consumer has not committed past.
fn[W, R] Log::segment_guarded(
  self : Log[W, R],
  seg : @segment.Segment[W, R],
) -> Bool {
  match self.cursor_guard {
    Some(g) => seg.base_offset + seg.record_count.to_uint64() > g
    None => false
  }
}

///|
/// Append a record, rolling to a new segment when the current one is full.
/// Returns the assigned logical offset.
pub fn[W : @io.LogWriter, R] Log::append(
  self : Log[W, R],
  key : Bytes,
  value : Bytes,
  timestamp : Int64,
  kind~ : @core.RecordKind = @core.RecordKind::Put,
) -> UInt64 raise @io.IoError {
  let need_new = if self.segments.length() == 0 {
    true
  } else {
    let active = self.segments[self.segments.length() - 1]
    active.record_count > 0 && active.size >= self.roll_size
  }
  if need_new {
    let seg = (self.make)(self.next_offset)
    self.segments.push(seg)
  }
  let active = self.segments[self.segments.length() - 1]
  let offset = active.append(key, value, timestamp, kind~)
  if self.sync is SyncPolicy::Always {
    active.writer.flush()
    active.mark_fsync_clean()
  }
  self.next_offset = offset + (1 : UInt64)
  self.index_cache = None
  offset
}

///|
/// fsync every segment's writer so that all prior appends become durable,
/// including rolled-over segments that `SyncPolicy::Batch` did not fsync
/// individually. A no-op when the log has no segments.
pub fn[W : @io.LogWriter, R] Log::flush(
  self : Log[W, R],
) -> Unit raise @io.IoError {
  for seg in self.segments {
    if seg.fsync_dirty {
      seg.writer.flush()
      seg.mark_fsync_clean()
    }
  }
}

///|
/// Append several records in one call, returning their assigned offsets in the
/// same order. Records are appended independently and each may roll the active
/// segment; a mid-batch IO failure stops the batch but keeps the records
/// already appended. Under `SyncPolicy::Batch` one `flush()` (an fsync of
/// every segment) is issued at the end of the batch.
pub fn[W : @io.LogWriter, R] Log::append_batch(
  self : Log[W, R],
  records : Array[(Bytes, Bytes, Int64)],
) -> Array[UInt64] raise @io.IoError {
  let offsets : Array[UInt64] = []
  for rec in records {
    let (key, value, timestamp) = rec
    offsets.push(self.append(key, value, timestamp))
  }
  if self.sync is SyncPolicy::Batch {
    self.flush()
  }
  offsets
}

///|
/// Append several records atomically: if any append fails, every record from
/// this batch is discarded. Segments created by the batch are handed to
/// `on_drop` (so the caller can reclaim their files), the previously active
/// segment is truncated back to its pre-batch size and its index, Bloom filter
/// and counters are rebuilt, and the offset space is restored. On success it
/// behaves like `append_batch`.
pub fn[W : @io.LogWriter + @io.LogTruncate, R : @io.LogReader] Log::append_batch_atomic(
  self : Log[W, R],
  records : Array[(Bytes, Bytes, Int64)],
  on_drop : (@segment.Segment[W, R]) -> Unit,
) -> Array[UInt64] raise @io.IoError {
  let start = self.next_offset
  let n0 = self.segments.length()
  let prev_size = if n0 > 0 { self.segments[n0 - 1].size } else { (0 : Int64) }
  let offsets : Array[UInt64] = []
  let ok = try {
    for rec in records {
      let (key, value, timestamp) = rec
      offsets.push(self.append(key, value, timestamp))
    }
    true
  } catch {
    _ => false
  }
  if ok {
    if self.sync is SyncPolicy::Batch {
      self.flush()
    }
    offsets
  } else {
    let mut i = n0
    while i < self.segments.length() {
      on_drop(self.segments[i])
      i = i + 1
    }
    let kept : Array[@segment.Segment[W, R]] = []
    let mut j = 0
    while j < n0 {
      kept.push(self.segments[j])
      j = j + 1
    }
    self.segments = kept
    self.index_cache = None
    if n0 > 0 {
      let seg = self.segments[n0 - 1]
      @io.LogTruncate::truncate(seg.writer, prev_size) catch {
        _ => ()
      }
      ignore(seg.rebuild_index() catch { _ => 0 })
    }
    self.next_offset = start
    ([] : Array[UInt64])
  }
}

///|
/// Locate the segment that owns `offset`, if any. Segments are kept in
/// increasing `base_offset` order, so this binary-searches them.
fn[W, R] Log::find_segment(
  self : Log[W, R],
  offset : UInt64,
) -> @segment.Segment[W, R]? {
  let mut lo = 0
  let mut hi = self.segments.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let seg = self.segments[mid]
    let base = seg.base_offset
    let end = base + seg.record_count.to_uint64()
    if offset < base {
      hi = mid
    } else if offset >= end {
      lo = mid + 1
    } else {
      return Some(seg)
    }
  }
  None
}

///|
/// Look up a single record by global offset.
pub fn[W, R : @io.LogReader] Log::get(
  self : Log[W, R],
  offset : UInt64,
) -> @core.Record? raise @io.IoError {
  match self.find_segment(offset) {
    Some(seg) => seg.get(offset)
    None => None
  }
}

///|
/// Stream records in `[from, to)` across segments to `f`, without building a
/// full array. Segments that cannot intersect the range are skipped.
pub fn[W, R : @io.LogReader] Log::for_each(
  self : Log[W, R],
  from : UInt64,
  to : UInt64,
  f : (@core.Record) -> Unit,
) -> Unit raise @io.IoError {
  if to <= from {
    return
  }
  for seg in self.segments {
    let base = seg.base_offset
    let seg_end = base + seg.record_count.to_uint64()
    if seg_end > from && base < to {
      seg.for_each(from, to, f)
    }
  }
}

///|
/// Decode every record in every segment, in append order.
pub fn[W, R : @io.LogReader] Log::scan(
  self : Log[W, R],
) -> Array[@core.Record] raise @io.IoError {
  let out : Array[@core.Record] = []
  for seg in self.segments {
    let recs = seg.scan()
    for rec in recs {
      out.push(rec)
    }
  }
  out
}

///|
/// Decode records whose global offset lies in the half-open range
/// `[from, to)`, skipping segments that cannot intersect the range.
pub fn[W, R : @io.LogReader] Log::scan_range(
  self : Log[W, R],
  from : UInt64,
  to : UInt64,
) -> Array[@core.Record] raise @io.IoError {
  let out : Array[@core.Record] = []
  self.for_each(from, to, rec => out.push(rec))
  out
}

///|
/// Decode records whose global offset lies in the half-open range `[from, to)`,
/// newest first (descending offset).
pub fn[W, R : @io.LogReader] Log::scan_reverse(
  self : Log[W, R],
  from : UInt64,
  to : UInt64,
) -> Array[@core.Record] raise @io.IoError {
  let recs = self.scan_range(from, to)
  let out : Array[@core.Record] = []
  let mut i = recs.length() - 1
  while i >= 0 {
    out.push(recs[i])
    i = i - 1
  }
  out
}

///|
/// The most recent `n` records in append order (oldest of the window first).
/// Returns fewer when the log holds less than `n`; a non-positive `n` yields
/// nothing.
pub fn[W, R : @io.LogReader] Log::tail(
  self : Log[W, R],
  n : Int32,
) -> Array[@core.Record] raise @io.IoError {
  let out : Array[@core.Record] = []
  if n <= 0 {
    return out
  }
  let total = self.next_offset
  let un = n.to_uint64()
  let from = if total > un { total - un } else { (0 : UInt64) }
  self.for_each(from, total, rec => out.push(rec))
  out
}

///|
/// Records whose timestamp lies in `[lo, hi)`, in log (offset) order and
/// including tombstones. Segments whose persisted time span cannot overlap the
/// range are skipped; a segment without a known span is always scanned.
pub fn[W, R : @io.LogReader] Log::scan_time_range(
  self : Log[W, R],
  lo : Int64,
  hi : Int64,
) -> Array[@core.Record] raise @io.IoError {
  let out : Array[@core.Record] = []
  if hi <= lo {
    return out
  }
  for seg in self.segments {
    let overlaps = if seg.has_time_range() {
      seg.max_timestamp() >= lo && seg.min_timestamp() < hi
    } else {
      true
    }
    if overlaps {
      if seg.is_ts_sorted() {
        let from = seg.lower_bound_ts(lo)
        let to = seg.lower_bound_ts(hi)
        if from < to {
          seg.for_each(from, to, rec => out.push(rec))
        }
      } else {
        let end = seg.base_offset + seg.record_count.to_uint64()
        seg.for_each(seg.base_offset, end, rec => {
          if rec.timestamp >= lo && rec.timestamp < hi {
            out.push(rec)
          }
        })
      }
    }
  }
  out
}

///|
/// Append a tombstone that marks `key` as deleted, without rewriting history.
pub fn[W : @io.LogWriter, R] Log::delete(
  self : Log[W, R],
  key : Bytes,
  timestamp : Int64,
) -> UInt64 raise @io.IoError {
  self.append(key, b"", timestamp, kind=@core.RecordKind::Delete)
}

///|
/// Retention: drop every rolled-over segment that lies entirely before
/// `offset`, invoking `on_drop` (e.g. to delete its backing file) for each.
/// The active (last) segment is never dropped. Returns the number dropped.
pub fn[W, R] Log::drop_before(
  self : Log[W, R],
  offset : UInt64,
  on_drop : (@segment.Segment[W, R]) -> Unit,
) -> Int32 {
  let keep : Array[@segment.Segment[W, R]] = []
  let mut dropped = 0
  let n = self.segments.length()
  for i = 0; i < n; i = i + 1 {
    let seg = self.segments[i]
    let seg_end = seg.base_offset + seg.record_count.to_uint64()
    if i < n - 1 && seg_end <= offset && !self.segment_guarded(seg) {
      on_drop(seg)
      dropped = dropped + 1
    } else {
      keep.push(seg)
    }
  }
  self.segments = keep
  self.index_cache = None
  dropped
}

///|
/// Retention: keep only the newest `keep` segments, dropping older ones via
/// `on_drop`. Returns the number dropped.
pub fn[W, R] Log::retain_last(
  self : Log[W, R],
  keep : Int32,
  on_drop : (@segment.Segment[W, R]) -> Unit,
) -> Int32 {
  let n = self.segments.length()
  let effective = if keep < 1 { 1 } else { keep }
  let drop_count = if n > effective { n - effective } else { 0 }
  let kept : Array[@segment.Segment[W, R]] = []
  let mut dropped = 0
  for i = 0; i < n; i = i + 1 {
    if i < drop_count && !self.segment_guarded(self.segments[i]) {
      on_drop(self.segments[i])
      dropped = dropped + 1
    } else {
      kept.push(self.segments[i])
    }
  }
  self.segments = kept
  self.index_cache = None
  dropped
}

///|
/// Retention by total bytes: drop the oldest rolled-over segments until the
/// remaining bytes are at most `max_bytes`. The active segment is never
/// dropped. Returns the number dropped.
pub fn[W, R] Log::retain_max_bytes(
  self : Log[W, R],
  max_bytes : Int64,
  on_drop : (@segment.Segment[W, R]) -> Unit,
) -> Int32 {
  let n = self.segments.length()
  let mut total : Int64 = 0
  for seg in self.segments {
    total = total + seg.size
  }
  let kept : Array[@segment.Segment[W, R]] = []
  let mut dropped = 0
  for i = 0; i < n; i = i + 1 {
    let seg = self.segments[i]
    if i < n - 1 && total > max_bytes && !self.segment_guarded(seg) {
      on_drop(seg)
      total = total - seg.size
      dropped = dropped + 1
    } else {
      kept.push(seg)
    }
  }
  self.segments = kept
  self.index_cache = None
  dropped
}

///|
/// Whether every record in `seg` has been superseded by a later record for the
/// same key (a newer put, or a tombstone), so dropping the segment loses no
/// live data.
fn[W, R : @io.LogReader] segment_all_superseded(
  seg : @segment.Segment[W, R],
  index : KeyIndex,
) -> Bool raise @io.IoError {
  let end = seg.base_offset + seg.record_count.to_uint64()
  let mut all = true
  seg.for_each(seg.base_offset, end, rec => {
    match index.latest(rec.key) {
      Some(off) => if off <= rec.offset { all = false }
      None => ()
    }
  })
  all
}

///|
/// Drop rolled-over segments every record of which has been superseded by a
/// later record for the same key, so removing them loses no live data. The
/// active (last) segment is never dropped. Returns the number dropped.
pub fn[W, R : @io.LogReader] Log::prune_superseded(
  self : Log[W, R],
  index : KeyIndex,
  on_drop : (@segment.Segment[W, R]) -> Unit,
) -> Int32 raise @io.IoError {
  let kept : Array[@segment.Segment[W, R]] = []
  let mut dropped = 0
  let n = self.segments.length()
  let mut i = 0
  while i < n {
    let seg = self.segments[i]
    if i < n - 1 &&
      !self.segment_guarded(seg) &&
      segment_all_superseded(seg, index) {
      on_drop(seg)
      dropped = dropped + 1
    } else {
      kept.push(seg)
    }
    i = i + 1
  }
  self.segments = kept
  self.index_cache = None
  dropped
}

///|
/// Number of rolled-over segments that `prune_superseded` would drop.
pub fn[W, R : @io.LogReader] Log::count_superseded(
  self : Log[W, R],
  index : KeyIndex,
) -> Int32 raise @io.IoError {
  let n = self.segments.length()
  let mut count = 0
  let mut i = 0
  while i < n {
    if i < n - 1 && segment_all_superseded(self.segments[i], index) {
      count = count + 1
    }
    i = i + 1
  }
  count
}

///|
/// Merge the two oldest segments whenever they are offset-contiguous, repeating
/// until the log holds at most `max_segments` segments or no contiguous pair
/// remains. Logical offsets are preserved (the combined segment starts at the
/// first segment's base). The older segments are handed to `on_drop`. Returns
/// the number of merges performed.
pub fn[W : @io.LogWriter, R : @io.LogReader] Log::merge_segments(
  self : Log[W, R],
  max_segments : Int32,
  on_drop : (@segment.Segment[W, R]) -> Unit,
) -> Int32 raise @io.IoError {
  let mut merged = 0
  while self.segments.length() >= 2 && self.segments.length() > max_segments {
    let a = self.segments[0]
    let b = self.segments[1]
    if b.base_offset != a.base_offset + a.record_count.to_uint64() {
      break
    }
    let ra = a.scan() catch { _ => break }
    let rb = b.scan() catch { _ => break }
    on_drop(a)
    on_drop(b)
    let combined = (self.make)(a.base_offset)
    if combined.byte_size() > (0 : Int64) {
      raise @io.IoError::Corrupt((0 : Int64))
    }
    for rec in ra {
      ignore(combined.append(rec.key, rec.value, rec.timestamp, kind=rec.kind))
    }
    for rec in rb {
      ignore(combined.append(rec.key, rec.value, rec.timestamp, kind=rec.kind))
    }
    let rebuilt : Array[@segment.Segment[W, R]] = [combined]
    let mut i = 2
    while i < self.segments.length() {
      rebuilt.push(self.segments[i])
      i = i + 1
    }
    self.segments = rebuilt
    self.index_cache = None
    merged = merged + 1
  }
  merged
}

///|
/// Retention by timestamp: drop every rolled-over segment whose last record is
/// older than `cutoff`, invoking `on_drop` for each. Assumes timestamps are
/// non-decreasing across the log (the usual append-only event ordering); the
/// active (last) segment is never dropped. Returns the number dropped.
pub fn[W, R : @io.LogReader] Log::retain_before(
  self : Log[W, R],
  cutoff : Int64,
  on_drop : (@segment.Segment[W, R]) -> Unit,
) -> Int32 raise @io.IoError {
  let kept : Array[@segment.Segment[W, R]] = []
  let mut dropped = 0
  let n = self.segments.length()
  for i = 0; i < n; i = i + 1 {
    let seg = self.segments[i]
    let expired = if seg.record_count > 0 {
      let last = seg.base_offset + (seg.record_count - 1).to_uint64()
      match seg.get(last) {
        Some(rec) => rec.timestamp < cutoff
        None => false
      }
    } else {
      true
    }
    if i < n - 1 && expired && !self.segment_guarded(seg) {
      on_drop(seg)
      dropped = dropped + 1
    } else {
      kept.push(seg)
    }
  }
  self.segments = kept
  self.index_cache = None
  dropped
}

///|
/// Result of a full-log integrity sweep.
pub(all) struct VerifyReport {
  segments : Int32
  records : Int32
  first_bad_offset : UInt64?
  first_bad_checksum : UInt64?
}

///|
/// Fast integrity check that decodes no record bodies: verifies segment
/// contiguity, per-segment counter consistency, and the stored whole-segment
/// CRC32 where available. Much cheaper than `verify` on large directories, but
/// it cannot detect corruption inside individual records that have no recorded
/// segment checksum. The report shape matches `verify`.
pub fn[W, R : @io.LogReader] Log::verify_fast(self : Log[W, R]) -> VerifyReport {
  let mut expected : UInt64 = 0
  let mut records : Int32 = 0
  let mut bad_found = false
  let mut bad_at : UInt64 = 0
  let mut bad_ck_found = false
  let mut bad_ck_at : UInt64 = 0
  for seg in self.segments {
    if !bad_found && seg.base_offset != expected {
      bad_found = true
      bad_at = expected
    }
    if seg.has_checksum() {
      let stored = seg.stored_checksum()
      let actual = Some(seg.compute_checksum()) catch { _ => None }
      match actual {
        Some(a) =>
          if a != stored && !bad_ck_found {
            bad_ck_found = true
            bad_ck_at = seg.base_offset
          }
        None =>
          if !bad_ck_found {
            bad_ck_found = true
            bad_ck_at = seg.base_offset
          }
      }
    }
    let count = seg.record_count
    if !bad_found && seg.base_offset + count.to_uint64() != seg.next_offset {
      bad_found = true
      bad_at = seg.next_offset
    }
    expected = seg.next_offset
    records = records + count
  }
  {
    segments: self.segments.length(),
    records,
    first_bad_offset: if bad_found {
      Some(bad_at)
    } else {
      None
    },
    first_bad_checksum: if bad_ck_found {
      Some(bad_ck_at)
    } else {
      None
    },
  }
}

///|
/// Sweep the whole log in order, checking that segments are laid out
/// contiguously and that every record decodes with the expected offset. The
/// first inconsistency (a segment gap, an offset jump, or a decode error) is
/// reported via `first_bad_offset`; a healthy log leaves it empty.
pub fn[W, R : @io.LogReader] Log::verify(self : Log[W, R]) -> VerifyReport {
  let mut expected : UInt64 = 0
  let mut records : Int32 = 0
  let mut bad_found = false
  let mut bad_at : UInt64 = 0
  let mut bad_ck_found = false
  let mut bad_ck_at : UInt64 = 0
  for seg in self.segments {
    if !bad_found && seg.base_offset != expected {
      bad_found = true
      bad_at = expected
    }
    if seg.has_checksum() {
      let stored = seg.stored_checksum()
      let actual = Some(seg.compute_checksum()) catch { _ => None }
      match actual {
        Some(a) =>
          if a != stored && !bad_ck_found {
            bad_ck_found = true
            bad_ck_at = seg.base_offset
          }
        None =>
          if !bad_ck_found {
            bad_ck_found = true
            bad_ck_at = seg.base_offset
          }
      }
    }
    let recs = seg.scan() catch {
      _ => {
        if !bad_found {
          bad_found = true
          bad_at = expected
        }
        []
      }
    }
    for rec in recs {
      if !bad_found && rec.offset != expected {
        bad_found = true
        bad_at = expected
      }
      expected = expected + (1 : UInt64)
      records = records + 1
    }
  }
  {
    segments: self.segments.length(),
    records,
    first_bad_offset: if bad_found {
      Some(bad_at)
    } else {
      None
    },
    first_bad_checksum: if bad_ck_found {
      Some(bad_ck_at)
    } else {
      None
    },
  }
}

///|
/// Serialize every record (including tombstones) as a stream of self-checking
/// record frames. The result can be persisted and later replayed with
/// `import_bytes` into another log directory.
pub fn[W, R : @io.LogReader] Log::export_bytes(
  self : Log[W, R],
) -> Bytes raise @io.IoError {
  let buf = @buffer.Buffer::Buffer()
  self.for_each((0 : UInt64), self.next_offset, rec => {
    buf.write_bytes(rec.encode())
  })
  buf.to_bytes()
}

///|
/// Replay a record stream produced by `export_bytes`, appending each record
/// (put or tombstone) in order. Returns the number of records imported. A
/// truncated or corrupt frame aborts with `IoError::Corrupt`.
pub fn[W : @io.LogWriter, R] Log::import_bytes(
  self : Log[W, R],
  data : Bytes,
) -> Int32 raise @io.IoError {
  let total = data.length()
  let mut pos : Int32 = 0
  let mut n : Int32 = 0
  while pos < total {
    let (rec, next) = @core.decode_record(data, pos) catch {
      _ => raise @io.IoError::Corrupt(pos.to_int64())
    }
    ignore(self.append(rec.key, rec.value, rec.timestamp, kind=rec.kind))
    pos = next
    n = n + 1
  }
  if self.sync is SyncPolicy::Batch {
    self.flush()
  }
  n
}

///|
/// A read-only summary of one segment, for observability.
pub(all) struct SegmentSummary {
  base_offset : UInt64
  records : Int32
  bytes : Int64
  compressed : Bool
  has_span : Bool
  min_ts : Int64
  max_ts : Int64
}

///|
/// Summarize every segment (counts, sizes, compression and time span) without
/// decoding record bodies.
pub fn[W, R] Log::segment_summaries(self : Log[W, R]) -> Array[SegmentSummary] {
  let out : Array[SegmentSummary] = []
  for seg in self.segments {
    out.push({
      base_offset: seg.base_offset,
      records: seg.count(),
      bytes: seg.byte_size(),
      compressed: seg.is_compressed(),
      has_span: seg.has_time_range(),
      min_ts: seg.min_timestamp(),
      max_ts: seg.max_timestamp(),
    })
  }
  out
}
