///|
/// Directory-level manifest describing the log layout without scanning any
/// segment data.
///
/// Layout (little endian), with a trailing CRC32 over everything before it:
///
///   u32 magic      ("MLMN")
///   u32 version
///   i64 roll_size
///   u64 next_offset
///   u32 seg_count
///   segments[seg_count]: { u64 base_offset; i64 byte_size }
///   u32 crc32
///
/// Each segment carries its byte size so a reopened log can verify that every
/// segment file still matches what was written; a mismatch (e.g. a truncated
/// or tampered segment) makes the reader fall back to a full recovery scan.
pub(all) struct Manifest {
  roll_size : Int64
  next_offset : UInt64
  segment_bases : Array[UInt64]
  segment_sizes : Array[Int64]
}

///|
const MANIFEST_MAGIC : UInt32 = 0x4D4C4D4E

///|
const MANIFEST_VERSION : UInt32 = 2

///|
fn mf_u32(data : Bytes, pos : Int32) -> UInt32 {
  data.at(pos).to_uint() |
  (data.at(pos + 1).to_uint() << 8) |
  (data.at(pos + 2).to_uint() << 16) |
  (data.at(pos + 3).to_uint() << 24)
}

///|
fn mf_u64(data : Bytes, pos : Int32) -> UInt64 {
  mf_u32(data, pos).to_uint64() | (mf_u32(data, pos + 4).to_uint64() << 32)
}

///|
fn mf_i64(data : Bytes, pos : Int32) -> Int64 {
  mf_u64(data, pos).reinterpret_as_int64()
}

///|
fn mf_count(n : Int32) -> UInt32 {
  n.reinterpret_as_uint()
}

///|
pub fn Manifest::encode(self : Manifest) -> Bytes {
  let body = @buffer.Buffer::Buffer()
  body.write_uint_le(MANIFEST_MAGIC)
  body.write_uint_le(MANIFEST_VERSION)
  body.write_int64_le(self.roll_size)
  body.write_uint64_le(self.next_offset)
  body.write_uint_le(mf_count(self.segment_bases.length()))
  let mut i = 0
  while i < self.segment_bases.length() {
    body.write_uint64_le(self.segment_bases[i])
    body.write_int64_le(self.segment_sizes[i])
    i = i + 1
  }
  let bytes = body.to_bytes()
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(bytes)
  out.write_uint_le(@core.crc32(bytes))
  out.to_bytes()
}

///|
pub fn decode_manifest(data : Bytes) -> Manifest raise @core.MetaError {
  let total = data.length()
  if total < 4 + 4 + 8 + 8 + 4 + 4 {
    raise @core.MetaError::Truncated(total)
  }
  if mf_u32(data, 0) != MANIFEST_MAGIC {
    raise @core.MetaError::BadMagic
  }
  let version = mf_u32(data, 4)
  if version != MANIFEST_VERSION {
    raise @core.MetaError::BadVersion(version)
  }
  let body_end = total - 4
  let expected = mf_u32(data, body_end)
  let actual = @core.crc32_range(data, 0, body_end)
  if expected != actual {
    raise @core.MetaError::BadCrc(expected, actual)
  }
  let roll_size = mf_i64(data, 8)
  let next_offset = mf_u64(data, 16)
  let seg_count = mf_u32(data, 24)
  let bases : Array[UInt64] = []
  let sizes : Array[Int64] = []
  let mut pos = 28
  let mut i = 0
  let n = seg_count.reinterpret_as_int()
  while i < n {
    if pos + 16 > body_end {
      raise @core.MetaError::Truncated(pos)
    }
    bases.push(mf_u64(data, pos))
    sizes.push(mf_i64(data, pos + 8))
    pos = pos + 16
    i = i + 1
  }
  {
    roll_size,
    next_offset,
    segment_bases: bases,
    segment_sizes: sizes,
  }
}