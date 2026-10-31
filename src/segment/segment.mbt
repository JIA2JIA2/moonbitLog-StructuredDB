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
  mut meta_loaded : Bool
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
  Segment::new_with_index_interval(writer, reader, base_offset, DEFAULT_INDEX_INTERVAL)
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
    meta_loaded: false,
  }
}

///|
/// The sparse-index interval in effect for this segment.
pub fn[W, R] Segment::index_interval(self : Segment[W, R]) -> Int32 {
  self.index.interval
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
  }
  let rec : @core.Record = { offset, timestamp, kind, key, value, }
  let bytes = rec.encode()
  ignore(self.writer.append(bytes))
  self.next_offset = offset + (1 : UInt64)
  self.record_count = self.record_count + 1
  self.size = self.size + bytes.length().to_int64()
  offset
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
  let head = self.reader.read_at(pos, 4)
  let body_len = @core.body_len_at(head, 0) catch { _ => return None }
  let full_len = (4 : Int64) + body_len.to_int64() + (4 : Int64)
  if pos + full_len > total {
    return None
  }
  let data = self.reader.read_at(pos, full_len.to_int())
  let (rec, next) = @core.decode_record(data, 0) catch { _ => return None }
  Some((rec, pos + next.to_int64()))
}

///|
/// Decode every record in this segment, in append order.
pub fn[W, R : @io.LogReader] Segment::scan(
  self : Segment[W, R],
) -> Array[@core.Record] raise @io.IoError {
  let total = self.reader.length()
  let data = self.reader.read_at(0, total.to_int())
  let out : Array[@core.Record] = []
  let mut pos = 0
  while pos < data.length() {
    let (rec, next) = @core.decode_record(data, pos) catch {
      _ => raise @io.IoError::Corrupt(pos.to_int64())
    }
    out.push(rec)
    pos = next
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
      Some((rec, next)) => {
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
  let seg_end = self.base_offset + self.record_count.to_uint64()
  let lo = if from < self.base_offset { self.base_offset } else { from }
  let hi = if to > seg_end { seg_end } else { to }
  if lo >= hi {
    return out
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
      Some((rec, next)) => {
        if rec.offset >= hi {
          go = false
        } else {
          if rec.offset >= lo {
            out.push(rec)
          }
          pos = next
        }
      }
    }
  }
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
  let total = self.reader.length()
  let mut pos : Int64 = 0
  let mut n : Int32 = 0
  let mut go = true
  while go {
    let loaded = self.load_record_at(pos)
    match loaded {
      None => go = false
      Some((_rec, next)) => {
        if self.index.should_index(n) {
          self.index.push(n.to_uint64(), pos)
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
        if self.index.should_index(n) {
          self.index.push(n.to_uint64(), pos)
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