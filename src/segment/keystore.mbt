///|
/// Persisted per-segment key index: for each key recorded in a segment, the
/// offset of its latest record in that segment plus a tombstone flag. It lets a
/// closed segment's keys be reloaded without re-decoding its data.
///
/// Layout (little endian), with a trailing CRC32 over everything before it:
///
///   u32 magic ("MLSK")
///   u32 version
///   u32 count
///   entries[count]: { u32 key_len, key bytes, u64 offset, u32 tombstone }
///   u32 crc32
const KEYSTORE_MAGIC : UInt32 = 0x4D4C534B

///|
const KEYSTORE_VERSION : UInt32 = 1

///|
const KEYSTORE_HEADER : Int32 = 12

///|
/// Serialize this segment's key -> latest-offset index.
pub fn[W, R] Segment::encode_keys(self : Segment[W, R]) -> Bytes {
  let body = @buffer.Buffer::Buffer()
  body.write_uint_le(KEYSTORE_MAGIC)
  body.write_uint_le(KEYSTORE_VERSION)
  body.write_uint_le(self.keys.length().reinterpret_as_uint())
  self.keys.each(fn(k, v) {
    let (off, del) = v
    body.write_uint_le(k.length().reinterpret_as_uint())
    body.write_bytes(k)
    body.write_uint64_le(off)
    body.write_uint_le(if del { 1 } else { 0 })
  })
  let bytes = body.to_bytes()
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(bytes)
  out.write_uint_le(@core.crc32(bytes))
  out.to_bytes()
}

///|
/// Replace this segment's key index with the contents of a buffer produced by
/// `encode_keys`, validating magic, version and CRC.
pub fn[W, R] Segment::load_keys(
  self : Segment[W, R],
  data : Bytes,
) -> Unit raise @core.MetaError {
  let total = data.length()
  if total < KEYSTORE_HEADER + 4 {
    raise @core.MetaError::Truncated(total)
  }
  if meta_u32(data, 0) != KEYSTORE_MAGIC {
    raise @core.MetaError::BadMagic
  }
  let version = meta_u32(data, 4)
  if version < 1 || version > KEYSTORE_VERSION {
    raise @core.MetaError::BadVersion(version)
  }
  let body_end = total - 4
  let expected = meta_u32(data, body_end)
  let actual = @core.crc32_range(data, 0, body_end)
  if expected != actual {
    raise @core.MetaError::BadCrc(expected, actual)
  }
  let count = meta_u32(data, 8).reinterpret_as_int()
  let map = @hashmap.HashMap::HashMap([])
  let mut pos = KEYSTORE_HEADER
  let mut i = 0
  while i < count {
    if pos + 4 > body_end {
      raise @core.MetaError::Truncated(pos)
    }
    let klen = meta_u32(data, pos).reinterpret_as_int()
    let kstart = pos + 4
    if kstart + klen + 12 > body_end {
      raise @core.MetaError::Truncated(pos)
    }
    let key = @core.slice(data, kstart, kstart + klen)
    let off = meta_u64(data, kstart + klen)
    let del = meta_u32(data, kstart + klen + 8) == 1
    map.set(key, (off, del))
    pos = kstart + klen + 12
    i = i + 1
  }
  self.keys = map
}
