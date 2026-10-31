///|
/// A factory that creates a fresh empty segment starting at `base_offset`.
pub type MakeSegment[W, R] = (UInt64) -> @segment.Segment[W, R] raise @io.IoError

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
}

///|
pub fn[W, R] Log::new(roll_size : Int64, make : MakeSegment[W, R]) -> Log[W, R] {
  { segments: [], roll_size, next_offset: 0, make, }
}

///|
/// Assemble a log from already-opened, already-recovered segments in
/// increasing `base_offset` order. The next offset continues from the last
/// segment so that subsequent appends remain contiguous.
pub fn[W, R] Log::recover(
  roll_size : Int64,
  make : MakeSegment[W, R],
  segments : Array[@segment.Segment[W, R]],
) -> Log[W, R] {
  let mut next : UInt64 = (0 : UInt64)
  if segments.length() > 0 {
    next = segments[segments.length() - 1].next_offset
  }
  { segments, roll_size, next_offset: next, make, }
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
/// Append a record, rolling to a new segment when the current one is full.
/// Returns the assigned logical offset.
pub fn[W : @io.LogWriter, R] Log::append(
  self : Log[W, R],
  key : Bytes,
  value : Bytes,
  timestamp : Int64,
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
  let offset = active.append(key, value, timestamp)
  self.next_offset = offset + (1 : UInt64)
  offset
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
  if to <= from {
    return out
  }
  for seg in self.segments {
    let base = seg.base_offset
    let seg_end = base + seg.record_count.to_uint64()
    if seg_end > from && base < to {
      let recs = seg.scan_range(from, to)
      for rec in recs {
        out.push(rec)
      }
    }
  }
  out
}