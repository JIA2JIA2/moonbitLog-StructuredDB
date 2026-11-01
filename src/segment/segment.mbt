///|
/// A single append-only segment: a contiguous run of records stored in one
/// backend log. `base_offset` is the logical offset assigned to the first
/// record written into this segment.
///
/// The segment keeps an in-memory sparse index alongside the data so that
/// point lookups and range scans can seek near their target instead of
/// decoding the whole segment.
pub(all) struct Segment[W, R] {
  mut base_offset : UInt64
  writer : W
  reader : R
  mut next_offset : UInt64
  mut record_count : Int32
  mut size : Int64
  mut index : SparseIndex
  mut bloom : BloomFilter
  mut min_ts : Int64
  mut max_ts : Int64
  mut time_known : Bool
  mut data_crc : UInt32
  mut crc_known : Bool
  mut compressed : Bool
  mut raw_size : Int64
  mut ts_sorted : Bool
  mut comp_algo : Int32
  mut keys : @hashmap.HashMap[Bytes, (UInt64, Bool)]
  mut meta_loaded : Bool
  mut meta_dirty : Bool
  mut ts_samples : Array[(UInt64, Int64)]
  mut fsync_dirty : Bool
}

///|
/// Default number of records between two sparse-index entries.
const DEFAULT_INDEX_INTERVAL : Int32 = 32

///|
pub fn[W, R] Segment::new(
  writer : W,
  reader : R,
  base_offset : UInt64,
) -> Segment[W, R] {
  Segment::new_with_index_interval(
    writer,
    reader,
    base_offset,
    DEFAULT_INDEX_INTERVAL,
  )
}

///|
/// Create a segment with a custom sparse-index interval (mainly for tests).
pub fn[W, R] Segment::new_with_index_interval(
  writer : W,
  reader : R,
  base_offset : UInt64,
  index_interval : Int32,
) -> Segment[W, R] {
  {
    base_offset,
    writer,
    reader,
    next_offset: base_offset,
    record_count: 0,
    size: 0,
    index: SparseIndex::new(index_interval),
    bloom: BloomFilter::new(),
    min_ts: 0,
    max_ts: 0,
    time_known: false,
    data_crc: 0,
    crc_known: false,
    compressed: false,
    raw_size: 0,
    ts_sorted: true,
    comp_algo: 0,
    keys: @hashmap.HashMap::HashMap([]),
    meta_loaded: false,
    meta_dirty: true,
    ts_samples: [],
    fsync_dirty: true,
  }
}

///|
/// The sparse-index interval in effect for this segment.
pub fn[W, R] Segment::index_interval(self : Segment[W, R]) -> Int32 {
  self.index.interval
}

///|
/// Whether this segment *might* contain `key`, per its Bloom filter. A `false`
/// result is conclusive; `true` only means a real lookup is still required.
pub fn[W, R] Segment::may_contain(self : Segment[W, R], key : Bytes) -> Bool {
  self.bloom.may_contain(key)
}

///|
/// Fold `ts` into the segment's timestamp span.
pub fn[W, R] Segment::note_timestamp(self : Segment[W, R], ts : Int64) -> Unit {
  if !self.time_known {
    self.min_ts = ts
    self.max_ts = ts
    self.time_known = true
  } else {
    if ts < self.max_ts {
      self.ts_sorted = false
    }
    if ts < self.min_ts {
      self.min_ts = ts
    }
    if ts > self.max_ts {
      self.max_ts = ts
    }
  }
}

///|
/// Smallest record timestamp in this segment (valid only when
/// `has_time_range`).
pub fn[W, R] Segment::min_timestamp(self : Segment[W, R]) -> Int64 {
  self.min_ts
}

///|
/// Largest record timestamp in this segment (valid only when
/// `has_time_range`).
pub fn[W, R] Segment::max_timestamp(self : Segment[W, R]) -> Int64 {
  self.max_ts
}

///|
/// Whether the segment's timestamp span is known (false while empty and for
/// metadata written before time ranges were persisted).
pub fn[W, R] Segment::has_time_range(self : Segment[W, R]) -> Bool {
  self.time_known
}

///|
/// Whether this segment's records are ordered by non-decreasing timestamp.
pub fn[W, R] Segment::is_ts_sorted(self : Segment[W, R]) -> Bool {
  self.ts_sorted
}

///|
/// Offset of the first record whose timestamp is >= `ts`. Valid only when the
/// segment is timestamp-sorted (see `is_ts_sorted`); uses the sparse index and
/// binary search over record offsets.
pub fn[W, R : @io.LogReader] Segment::lower_bound_ts(
  self : Segment[W, R],
  ts : Int64,
) -> UInt64 raise @io.IoError {
  if self.ts_samples.length() == 0 {
    // No in-memory samples (e.g. a freshly loaded segment): binary search over
    // record offsets with point probes.
    let mut lo = self.base_offset
    let mut hi = self.base_offset + self.record_count.to_uint64()
    while lo < hi {
      let mid = lo + (hi - lo) / (2 : UInt64)
      let probe = self.get(mid) catch { _ => return lo }
      match probe {
        Some(rec) =>
          if rec.timestamp < ts {
            lo = mid + (1 : UInt64)
          } else {
            hi = mid
          }
        None => hi = mid
      }
    }
    return lo
  }
  // In-memory timestamp samples: binary search without any I/O, then walk at
  // most one sampling interval. Valid because ts_samples mirrors the sparse
  // index and the segment is timestamp-sorted.
  let samples = self.ts_samples
  let m = samples.length()
  let mut lo = 0
  let mut hi = m
  while lo < hi {
    let mid = (lo + hi) / 2
    let (_ri, t) = samples[mid]
    if t < ts {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  let start_record = if lo > 0 {
    let (ri, _t) = samples[lo - 1]
    ri
  } else {
    (0 : UInt64)
  }
  let stop_record = if lo < m {
    let (ri, _t) = samples[lo]
    ri + (1 : UInt64)
  } else {
    self.record_count.to_uint64()
  }
  let from = self.base_offset + start_record
  let to = self.base_offset + stop_record
  let mut result = to
  self.for_each(from, to, rec => {
    if rec.timestamp >= ts && rec.offset < result {
      result = rec.offset
    }
  })
  result
}

///|
/// Whether the segment carries a finalized whole-segment checksum (recorded
/// once it stops growing).
pub fn[W, R] Segment::has_checksum(self : Segment[W, R]) -> Bool {
  self.crc_known
}

///|
/// The persisted whole-segment CRC32; valid only when `has_checksum`.
pub fn[W, R] Segment::stored_checksum(self : Segment[W, R]) -> UInt32 {
  self.data_crc
}

///|
/// Record `crc` as this segment's finalized whole-segment checksum.
pub fn[W, R] Segment::set_checksum(self : Segment[W, R], crc : UInt32) -> Unit {
  self.data_crc = crc
  self.crc_known = true
  self.meta_dirty = true
}

///|
/// Clear the segment's "metadata changed" flag once its sidecars have been
/// persisted, so unchanged segments are not rewritten on every flush.
pub fn[W, R] Segment::mark_meta_clean(self : Segment[W, R]) -> Unit {
  self.meta_dirty = false
}

///|
/// Whether the segment's in-memory metadata differs from its persisted
/// sidecars and they should be rewritten on the next flush.
pub fn[W, R] Segment::needs_meta_write(self : Segment[W, R]) -> Bool {
  self.meta_dirty
}

///|
/// Clear the segment's "needs fsync" flag once its data has been fsynced.
pub fn[W, R] Segment::mark_fsync_clean(self : Segment[W, R]) -> Unit {
  self.fsync_dirty = false
}

///|
/// Recompute the CRC32 over the segment's whole byte range.
pub fn[W, R : @io.LogReader] Segment::compute_checksum(
  self : Segment[W, R],
) -> UInt32 raise @io.IoError {
  let total = self.reader.length()
  if total <= (0 : Int64) {
    return 0
  }
  let data = self.reader.read_at((0 : Int64), total.to_int())
  @core.crc32(data)
}

///|
/// Whether this segment's data is stored compressed on disk.
pub fn[W, R] Segment::is_compressed(self : Segment[W, R]) -> Bool {
  self.compressed
}

///|
/// The compression algorithm used for this segment's data (0 = none, 1 = RLE,
/// 2 = LZSS).
pub fn[W, R] Segment::comp_algo(self : Segment[W, R]) -> Int32 {
  self.comp_algo
}

///|
/// Record that this segment is now stored compressed with `algo`, holding
/// `raw_size` bytes of uncompressed data.
pub fn[W, R] Segment::mark_compressed(
  self : Segment[W, R],
  raw_size : Int64,
  algo : Int32,
) -> Unit {
  self.compressed = true
  self.raw_size = raw_size
  self.comp_algo = algo
  self.meta_dirty = true
}

///|
/// Append one record, assigning it the next logical offset. Returns the
/// offset that was assigned.
pub fn[W : @io.LogWriter, R] Segment::append(
  self : Segment[W, R],
  key : Bytes,
  value : Bytes,
  timestamp : Int64,
  kind~ : @core.RecordKind = @core.RecordKind::Put,
) -> UInt64 raise @io.IoError {
  let offset = self.next_offset
  if self.index.should_index(self.record_count) {
    self.index.push(self.record_count.to_uint64(), self.size)
    self.ts_samples.push((self.record_count.to_uint64(), timestamp))
  }
  let rec : @core.Record = { offset, timestamp, kind, key, value, }
  let bytes = rec.encode()
  ignore(self.writer.append(bytes))
  self.bloom.add(key)
  self.keys.set(key, (offset, kind is @core.RecordKind::Delete))
  self.note_timestamp(timestamp)
  self.next_offset = offset + (1 : UInt64)
  self.record_count = self.record_count + 1
  self.size = self.size + bytes.length().to_int64()
  self.crc_known = false
  self.meta_dirty = true
  self.fsync_dirty = true
  offset
}

///|
/// Call `f` for each key in this segment with the offset of its latest record
/// in the segment and whether that record is a tombstone, without decoding
/// record bodies.
pub fn[W, R] Segment::each_key(
  self : Segment[W, R],
  f : (Bytes, UInt64, Bool) -> Unit,
) -> Unit {
  self.keys.each(fn(_k, v) {
    let (off, del) = v
    f(_k, off, del)
  })
}

///|
/// Number of distinct keys recorded in this segment.
pub fn[W, R] Segment::key_count(self : Segment[W, R]) -> Int32 {
  self.keys.length()
}

///|
/// Number of records appended to this segment.
pub fn[W, R] Segment::count(self : Segment[W, R]) -> Int32 {
  self.record_count
}

///|
/// Total number of bytes written to this segment.
pub fn[W, R] Segment::byte_size(self : Segment[W, R]) -> Int64 {
  self.size
}

///|
/// Read raw bytes at a physical file offset.
pub fn[W, R : @io.LogReader] Segment::read_raw(
  self : Segment[W, R],
  offset : Int64,
  len : Int32,
) -> Bytes raise @io.IoError {
  self.reader.read_at(offset, len)
}

///|
/// Decode the single record that starts at `pos`, returning it together with
/// the position just after it. Only the 4-byte length prefix is read first, so
/// callers can walk records without materialising the whole segment. Returns
/// `None` when `pos` is at (or a truncated / corrupted tail begins before) the
/// end of the readable bytes.
fn[W, R : @io.LogReader] Segment::load_record_at(
  self : Segment[W, R],
  pos : Int64,
) -> (@core.Record, Int64)? raise @io.IoError {
  let total = self.reader.length()
  if pos < (0 : Int64) || pos + (4 : Int64) > total {
    return None
  }
  let remaining = total - pos
  let want = if remaining > (4096 : Int64) { (4096 : Int64) } else { remaining }
  let chunk = self.reader.read_at(pos, want.to_int())
  let body_len = @core.body_len_at(chunk, 0) catch { _ => return None }
  let full_len = (4 : Int64) + body_len.to_int64() + (4 : Int64)
  if pos + full_len > total {
    return None
  }
  let data = if full_len <= want {
    chunk
  } else {
    self.reader.read_at(pos, full_len.to_int())
  }
  let (rec, next) = @core.decode_record(data, 0) catch { _ => return None }
  Some((rec, pos + next.to_int64()))
}

///|
/// Stream every record in `[from, to)` (clamped to this segment) to `f`, one at
/// a time, without materialising the segment in memory.
pub fn[W, R : @io.LogReader] Segment::for_each(
  self : Segment[W, R],
  from : UInt64,
  to : UInt64,
  f : (@core.Record) -> Unit,
) -> Unit raise @io.IoError {
  let seg_end = self.base_offset + self.record_count.to_uint64()
  let lo = if from < self.base_offset { self.base_offset } else { from }
  let hi = if to > seg_end { seg_end } else { to }
  if lo >= hi {
    return
  }
  let rel = lo - self.base_offset
  let mut pos : Int64 = match self.index.floor(rel) {
    Some(e) => e.position
    None => (0 : Int64)
  }
  let mut go = true
  while go {
    let loaded = self.load_record_at(pos)
    match loaded {
      None => go = false
      Some((rec, next)) =>
        if rec.offset >= hi {
          go = false
        } else {
          if rec.offset >= lo {
            f(rec)
          }
          pos = next
        }
    }
  }
}

///|
/// Decode every record actually present in this segment, in append order.
/// Walks records from the start of the readable bytes to the end, so it does
/// not depend on the in-memory `record_count` (which a freshly opened segment
/// may not have yet). Memory tracks the result, not the segment size.
pub fn[W, R : @io.LogReader] Segment::scan(
  self : Segment[W, R],
) -> Array[@core.Record] raise @io.IoError {
  let out : Array[@core.Record] = []
  let mut pos : Int64 = 0
  let mut go = true
  while go {
    let loaded = self.load_record_at(pos)
    match loaded {
      None => go = false
      Some((rec, next)) => {
        out.push(rec)
        pos = next
      }
    }
  }
  out
}

///|
/// Look up a single record by its logical offset. Uses the sparse index to
/// seek near the target, then walks at most `index_interval` records.
pub fn[W, R : @io.LogReader] Segment::get(
  self : Segment[W, R],
  offset : UInt64,
) -> @core.Record? raise @io.IoError {
  if offset < self.base_offset {
    return None
  }
  let rel = offset - self.base_offset
  if rel >= self.record_count.to_uint64() {
    return None
  }
  let mut pos : Int64 = match self.index.floor(rel) {
    Some(e) => e.position
    None => (0 : Int64)
  }
  let mut result : @core.Record? = None
  let mut go = true
  while go {
    let loaded = self.load_record_at(pos)
    match loaded {
      None => go = false
      Some((rec, next)) =>
        if rec.offset == offset {
          result = Some(rec)
          go = false
        } else if rec.offset > offset {
          go = false
        } else {
          pos = next
        }
    }
  }
  result
}

///|
/// Decode records whose logical offset lies in the half-open range
/// `[from, to)`, clamped to this segment's own range.
pub fn[W, R : @io.LogReader] Segment::scan_range(
  self : Segment[W, R],
  from : UInt64,
  to : UInt64,
) -> Array[@core.Record] raise @io.IoError {
  let out : Array[@core.Record] = []
  self.for_each(from, to, rec => out.push(rec))
  out
}

///|
/// Rebuild the sparse index (and derived counters) by decoding the segment's
/// bytes from the beginning. Returns the number of records discovered. Useful
/// after reopening a segment whose in-memory index was not persisted.
pub fn[W, R : @io.LogReader] Segment::rebuild_index(
  self : Segment[W, R],
) -> Int32 raise @io.IoError {
  self.index.reset()
  self.bloom = BloomFilter::new()
  self.keys = @hashmap.HashMap::HashMap([])
  self.time_known = false
  self.ts_sorted = true
  self.meta_dirty = true
  self.ts_samples = []
  let total = self.reader.length()
  let mut pos : Int64 = 0
  let mut n : Int32 = 0
  let mut go = true
  while go {
    let loaded = self.load_record_at(pos)
    match loaded {
      None => go = false
      Some((rec, next)) => {
        self.bloom.add(rec.key)
        self.keys.set(rec.key, (rec.offset, rec.is_delete()))
        self.note_timestamp(rec.timestamp)
        if self.index.should_index(n) {
          self.index.push(n.to_uint64(), pos)
          self.ts_samples.push((n.to_uint64(), rec.timestamp))
        }
        n = n + 1
        pos = next
      }
    }
  }
  self.record_count = n
  self.size = total
  self.next_offset = self.base_offset + n.to_uint64()
  n
}

///|
/// Crash recovery for a single segment: walk the bytes from the start,
/// counting records that decode cleanly with a valid CRC. The first truncated
/// or corrupt record ends the walk (a crash only ever leaves a torn tail), and
/// the segment is truncated back to the last good boundary. `base_offset` is
/// corrected from the first record encountered so the caller need not parse it
/// out of the file name. Returns the number of recovered records.
pub fn[W : @io.LogTruncate, R : @io.LogReader] Segment::recover(
  self : Segment[W, R],
) -> Int32 raise @io.IoError {
  self.index.reset()
  self.bloom = BloomFilter::new()
  self.keys = @hashmap.HashMap::HashMap([])
  self.time_known = false
  self.ts_sorted = true
  self.meta_dirty = true
  self.ts_samples = []
  self.fsync_dirty = true
  let total = self.reader.length()
  let mut pos : Int64 = 0
  let mut n : Int32 = 0
  let mut first : UInt64 = self.base_offset
  let mut last : UInt64 = self.base_offset
  let mut any = false
  let mut go = true
  while go {
    let loaded = self.load_record_at(pos)
    match loaded {
      None => go = false
      Some((rec, next)) => {
        if !any {
          first = rec.offset
          any = true
        }
        last = rec.offset
        self.bloom.add(rec.key)
        self.keys.set(rec.key, (rec.offset, rec.is_delete()))
        self.note_timestamp(rec.timestamp)
        if self.index.should_index(n) {
          self.index.push(n.to_uint64(), pos)
          self.ts_samples.push((n.to_uint64(), rec.timestamp))
        }
        n = n + 1
        pos = next
      }
    }
  }
  if pos < total {
    self.writer.truncate(pos)
  }
  if any {
    self.base_offset = first
    self.next_offset = last + (1 : UInt64)
  } else {
    self.next_offset = self.base_offset
  }
  self.record_count = n
  self.size = pos
  n
}

///|
/// Canonical file name for a segment, zero padded so lexical order matches
/// numeric order (e.g. `0000000000000007.log`).
pub fn segment_file_name(base_offset : UInt64) -> String {
  let raw = base_offset.to_string()
  let pad = (16 : Int32) - raw.length()
  "0".repeat(pad) + raw + ".log"
}
