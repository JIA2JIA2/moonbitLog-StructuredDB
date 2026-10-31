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
/// Look up a single record by global offset.
pub fn[W, R : @io.LogReader] Log::get(
  self : Log[W, R],
  offset : UInt64,
) -> @core.Record? raise @io.IoError {
  let mut found : @core.Record? = None
  for seg in self.segments {
    if found is None {
      let base = seg.base_offset
      let end = base + seg.record_count.to_uint64()
      if offset >= base && offset < end {
        found = seg.get(offset)
      }
    }
  }
  found
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
