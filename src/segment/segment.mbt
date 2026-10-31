///|
/// A single append-only segment: a contiguous run of records stored in one
/// backend log. `base_offset` is the logical offset assigned to the first
/// record written into this segment.
pub(all) struct Segment[W, R] {
  base_offset : UInt64
  writer : W
  reader : R
  mut next_offset : UInt64
  mut record_count : Int32
  mut size : Int64
}

///|
pub fn[W, R] Segment::new(
  writer : W,
  reader : R,
  base_offset : UInt64,
) -> Segment[W, R] {
  {
    base_offset,
    writer,
    reader,
    next_offset: base_offset,
    record_count: 0,
    size: 0,
  }
}

///|
/// Append one record, assigning it the next logical offset. Returns the
/// offset that was assigned.
pub fn[W : @io.LogWriter, R] Segment::append(
  self : Segment[W, R],
  key : Bytes,
  value : Bytes,
  timestamp : Int64,
) -> UInt64 raise @io.IoError {
  let offset = self.next_offset
  let rec : @core.Record = { offset, timestamp, key, value, }
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
/// Look up a single record by its logical offset.
pub fn[W, R : @io.LogReader] Segment::get(
  self : Segment[W, R],
  offset : UInt64,
) -> @core.Record? raise @io.IoError {
  let recs = self.scan()
  let mut found : @core.Record? = None
  for rec in recs {
    if rec.offset == offset {
      found = Some(rec)
    }
  }
  found
}

///|
/// Canonical file name for a segment, zero padded so lexical order matches
/// numeric order (e.g. `0000000000000007.log`).
pub fn segment_file_name(base_offset : UInt64) -> String {
  let raw = base_offset.to_string()
  let pad = (16 : Int32) - raw.length()
  "0".repeat(pad) + raw + ".log"
}
