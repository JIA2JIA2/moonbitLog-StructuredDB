///|
/// Kind of an append-only record. `Delete` is a tombstone: it marks a key as
/// removed without rewriting or erasing the original data, preserving the
/// append-only invariant.
pub(all) enum RecordKind {
  Put
  Delete
} derive(Eq, Debug)

///|
pub extend RecordKind with Eq::{equal, not_equal}

///|
pub extend RecordKind with @debug.Debug::{to_repr}

///|
/// A single append-only log record.
///
/// On-disk layout (little endian):
///
///   u32 body_len          -- length of `body` in bytes
///   body:
///     u8  flags           -- 0 = Put, 1 = Delete
///     u64 offset
///     i64 timestamp
///     u32 key_len
///     u32 value_len
///     key[key_len]
///     value[value_len]
///   u32 crc32             -- CRC32 over `body` only
pub(all) struct Record {
  offset : UInt64
  timestamp : Int64
  kind : RecordKind
  key : Bytes
  value : Bytes
} derive(Eq, Debug)

///|
pub extend Record with Eq::{equal, not_equal}

///|
pub extend Record with @debug.Debug::{to_repr}

///|
/// Whether this record is a tombstone (a key deletion marker).
pub fn Record::is_delete(self : Record) -> Bool {
  self.kind is RecordKind::Delete
}

///|
/// Errors raised while decoding a record from a byte buffer.
pub(all) suberror DecodeError {
  Truncated(Int32)
  BadCrc(UInt32, UInt32)
}

///|
fn read_u32_le(data : Bytes, pos : Int32) -> UInt32 {
  data.at(pos).to_uint() |
  (data.at(pos + 1).to_uint() << 8) |
  (data.at(pos + 2).to_uint() << 16) |
  (data.at(pos + 3).to_uint() << 24)
}

///|
fn read_u64_le(data : Bytes, pos : Int32) -> UInt64 {
  read_u32_le(data, pos).to_uint64() |
  (read_u32_le(data, pos + 4).to_uint64() << 32)
}

///|
fn read_i64_le(data : Bytes, pos : Int32) -> Int64 {
  read_u64_le(data, pos).reinterpret_as_int64()
}

///|
fn u32_as_int(x : UInt32) -> Int32 {
  x.to_uint64().to_int()
}

///|
/// Copy the bytes in `[start, end)` into a fresh `Bytes`.
pub fn slice(data : Bytes, start : Int32, end : Int32) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  for i = start; i < end; i = i + 1 {
    buf.write_byte(data.at(i))
  }
  buf.to_bytes()
}

///|
/// Encode a record into its append-only on-disk representation.
pub fn Record::encode(self : Record) -> Bytes {
  let flags : Byte = match self.kind {
    RecordKind::Put => 0
    RecordKind::Delete => 1
  }
  let body = @buffer.Buffer::Buffer()
  body.write_byte(flags)
  body.write_uint64_le(self.offset)
  body.write_int64_le(self.timestamp)
  body.write_uint_le(self.key.length().reinterpret_as_uint())
  body.write_uint_le(self.value.length().reinterpret_as_uint())
  body.write_bytes(self.key)
  body.write_bytes(self.value)
  let body_bytes = body.to_bytes()
  let crc = crc32(body_bytes)
  let out = @buffer.Buffer::Buffer()
  out.write_uint_le(body_bytes.length().reinterpret_as_uint())
  out.write_bytes(body_bytes)
  out.write_uint_le(crc)
  out.to_bytes()
}

///|
/// Read the 4-byte length prefix of the record encoded at `pos`, without
/// decoding the record itself. Lets callers seek record by record.
pub fn body_len_at(data : Bytes, pos : Int32) -> Int32 raise DecodeError {
  let total = data.length()
  if pos < 0 || pos + 4 > total {
    raise DecodeError::Truncated(pos)
  }
  u32_as_int(read_u32_le(data, pos))
}

///|
/// Decode the record starting at `pos`, returning the record and the position
/// immediately after it (so callers can scan a buffer of concatenated records).
pub fn decode_record(
  data : Bytes,
  pos : Int32,
) -> (Record, Int32) raise DecodeError {
  let total = data.length()
  if pos < 0 || pos + 4 > total {
    raise DecodeError::Truncated(pos)
  }
  let body_len = u32_as_int(read_u32_le(data, pos))
  let body_start = pos + 4
  let body_end = body_start + body_len
  if body_end + 4 > total {
    raise DecodeError::Truncated(pos)
  }
  let expected_crc = read_u32_le(data, body_end)
  let actual_crc = crc32_range(data, body_start, body_end)
  if expected_crc != actual_crc {
    raise DecodeError::BadCrc(expected_crc, actual_crc)
  }
  if body_len < 25 {
    raise DecodeError::Truncated(pos)
  }
  let flag = data.at(body_start)
  let kind = if flag == 1 {
    RecordKind::Delete
  } else {
    RecordKind::Put
  }
  let offset = read_u64_le(data, body_start + 1)
  let timestamp = read_i64_le(data, body_start + 9)
  let key_len = u32_as_int(read_u32_le(data, body_start + 17))
  let value_len = u32_as_int(read_u32_le(data, body_start + 21))
  if 25 + key_len + value_len > body_len {
    raise DecodeError::Truncated(pos)
  }
  let key = slice(data, body_start + 25, body_start + 25 + key_len)
  let value = slice(
    data,
    body_start + 25 + key_len,
    body_start + 25 + key_len + value_len,
  )
  let rec : Record = { offset, timestamp, kind, key, value, }
  (rec, body_end + 4)
}