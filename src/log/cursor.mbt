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

///|
/// Magic header of the persisted cursor file ("MLCU").
const CURSOR_MAGIC : UInt32 = 0x4D4C4355

///|
fn cf_u32(data : Bytes, pos : Int32) -> UInt32 {
  data.at(pos).to_uint() |
  (data.at(pos + 1).to_uint() << 8) |
  (data.at(pos + 2).to_uint() << 16) |
  (data.at(pos + 3).to_uint() << 24)
}

///|
fn cf_u64(data : Bytes, pos : Int32) -> UInt64 {
  cf_u32(data, pos).to_uint64() | (cf_u32(data, pos + 4).to_uint64() << 32)
}

///|
/// Serialize a committed cursor position into a self-checking blob:
///
///   u32 magic ("MLCU")
///   u64 position
///   u32 crc32 (over the preceding 12 bytes)
pub fn encode_cursor(position : UInt64) -> Bytes {
  let body = @buffer.Buffer::Buffer()
  body.write_uint_le(CURSOR_MAGIC)
  body.write_uint64_le(position)
  let bytes = body.to_bytes()
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(bytes)
  out.write_uint_le(@core.crc32(bytes))
  out.to_bytes()
}

///|
/// Decode a persisted cursor blob, validating its magic and CRC.
pub fn decode_cursor(data : Bytes) -> UInt64 raise @core.MetaError {
  if data.length() < 4 + 8 + 4 {
    raise @core.MetaError::Truncated(data.length())
  }
  if cf_u32(data, 0) != CURSOR_MAGIC {
    raise @core.MetaError::BadMagic
  }
  let expected = cf_u32(data, 12)
  let actual = @core.crc32_range(data, 0, 12)
  if expected != actual {
    raise @core.MetaError::BadCrc(expected, actual)
  }
  cf_u64(data, 4)
}
