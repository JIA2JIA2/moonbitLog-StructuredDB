///|
/// A consumer cursor over a log: a committed read position plus a `poll`
/// operation that pulls one batch at a time. The offset only advances to the
/// last record actually returned, so a crash before the position is persisted
/// simply replays the batch — consumers can treat cursor persistence as their
/// own commit point.
pub(all) struct ConsumerCursor {
  mut offset : UInt64
}

///|
pub fn ConsumerCursor::new(start : UInt64) -> ConsumerCursor {
  { offset: start, }
}

///|
/// The offset the next `poll` will start from.
pub fn ConsumerCursor::position(self : ConsumerCursor) -> UInt64 {
  self.offset
}

///|
/// Move the cursor (e.g. after loading a persisted position).
pub fn ConsumerCursor::seek(self : ConsumerCursor, offset : UInt64) -> Unit {
  self.offset = offset
}

///|
/// Read up to `limit` records starting at the cursor and advance past the ones
/// returned. Never reads beyond what has been appended.
pub fn[W, R : @io.LogReader] ConsumerCursor::poll(
  self : ConsumerCursor,
  log : Log[W, R],
  limit : Int32,
) -> Array[@core.Record] raise @io.IoError {
  let out : Array[@core.Record] = []
  if limit <= 0 {
    return out
  }
  let end = self.offset + limit.to_uint64()
  let recs = log.scan_range(self.offset, end)
  for rec in recs {
    out.push(rec)
  }
  if out.length() > 0 {
    self.offset = out[out.length() - 1].offset + (1 : UInt64)
  }
  out
}