///|
/// Persisted per-segment metadata: counters plus a copy of the sparse index.
/// Encoding it lets a segment be reopened without re-decoding its data bytes.
///
/// Layout (little endian), with a trailing CRC32 over everything before it:
///
///   u32 magic      ("MLSG")
///   u32 version
///   u64 base_offset
///   u64 next_offset
///   u32 record_count
///   i64 size
///   u32 interval
///   u32 entry_count
///   entries[entry_count]: { u64 record_index, i64 position }
///   (v2+) bloom ; (v3+) min_ts/max_ts/time_known ; (v4+) data_crc/crc_known
///   (v5+) compressed/raw_size ; u32 crc32
pub(all) struct SegmentMeta {
  base_offset : UInt64
  next_offset : UInt64
  record_count : UInt32
  size : Int64
  interval : Int32
  entries : Array[IndexEntry]
  bloom : BloomFilter
  min_ts : Int64
  max_ts : Int64
  time_known : Bool
  data_crc : UInt32
  crc_known : Bool
  compressed : Bool
  raw_size : Int64
}

///|
const SEGMENT_META_MAGIC : UInt32 = 0x4D4C5347

///|
const SEGMENT_META_VERSION : UInt32 = 5

///|
const SEGMENT_META_HEADER : Int32 = 44

///|
fn meta_u32(data : Bytes, pos : Int32) -> UInt32 {
  data.at(pos).to_uint() |
  (data.at(pos + 1).to_uint() << 8) |
  (data.at(pos + 2).to_uint() << 16) |
  (data.at(pos + 3).to_uint() << 24)
}

///|
fn meta_u64(data : Bytes, pos : Int32) -> UInt64 {
  meta_u32(data, pos).to_uint64() | (meta_u32(data, pos + 4).to_uint64() << 32)
}

///|
fn meta_i64(data : Bytes, pos : Int32) -> Int64 {
  meta_u64(data, pos).reinterpret_as_int64()
}

///|
fn meta_i32(data : Bytes, pos : Int32) -> Int32 {
  meta_u32(data, pos).reinterpret_as_int()
}

///|
fn meta_i32_count(n : Int32) -> UInt32 {
  n.reinterpret_as_uint()
}

///|
pub fn SegmentMeta::encode(self : SegmentMeta) -> Bytes {
  let body = @buffer.Buffer::Buffer()
  body.write_uint_le(SEGMENT_META_MAGIC)
  body.write_uint_le(SEGMENT_META_VERSION)
  body.write_uint64_le(self.base_offset)
  body.write_uint64_le(self.next_offset)
  body.write_uint_le(self.record_count)
  body.write_int64_le(self.size)
  body.write_uint_le(meta_i32_count(self.interval))
  body.write_uint_le(meta_i32_count(self.entries.length()))
  for e in self.entries {
    body.write_uint64_le(e.record_index)
    body.write_int64_le(e.position)
  }
  let bloom = self.bloom.to_bytes()
  body.write_uint_le(meta_i32_count(bloom.length()))
  body.write_bytes(bloom)
  body.write_int64_le(self.min_ts)
  body.write_int64_le(self.max_ts)
  body.write_uint_le(if self.time_known { 1 } else { 0 })
  body.write_uint_le(self.data_crc)
  body.write_uint_le(if self.crc_known { 1 } else { 0 })
  body.write_uint_le(if self.compressed { 1 } else { 0 })
  body.write_int64_le(self.raw_size)
  let bytes = body.to_bytes()
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(bytes)
  out.write_uint_le(@core.crc32(bytes))
  out.to_bytes()
}

///|
pub fn decode_segment_meta(data : Bytes) -> SegmentMeta raise @core.MetaError {
  let total = data.length()
  if total < SEGMENT_META_HEADER + 4 {
    raise @core.MetaError::Truncated(total)
  }
  if meta_u32(data, 0) != SEGMENT_META_MAGIC {
    raise @core.MetaError::BadMagic
  }
  let version = meta_u32(data, 4)
  if version < 1 || version > SEGMENT_META_VERSION {
    raise @core.MetaError::BadVersion(version)
  }
  let body_end = total - 4
  let expected = meta_u32(data, body_end)
  let actual = @core.crc32_range(data, 0, body_end)
  if expected != actual {
    raise @core.MetaError::BadCrc(expected, actual)
  }
  let base_offset = meta_u64(data, 8)
  let next_offset = meta_u64(data, 16)
  let record_count = meta_u32(data, 24)
  let size = meta_i64(data, 28)
  let interval = meta_i32(data, 36)
  let entry_count = meta_u32(data, 40)
  let entries : Array[IndexEntry] = []
  let mut pos = SEGMENT_META_HEADER
  let mut i = 0
  let n = entry_count.reinterpret_as_int()
  while i < n {
    if pos + 16 > body_end {
      raise @core.MetaError::Truncated(pos)
    }
    let record_index = meta_u64(data, pos)
    let position = meta_i64(data, pos + 8)
    entries.push({ record_index, position, })
    pos = pos + 16
    i = i + 1
  }
  let mut bloom = BloomFilter::disabled()
  if version >= 2 {
    if pos + 4 > body_end {
      raise @core.MetaError::Truncated(pos)
    }
    let blen = meta_u32(data, pos).reinterpret_as_int()
    let bstart = pos + 4
    if bstart + blen > body_end {
      raise @core.MetaError::Truncated(pos)
    }
    bloom = BloomFilter::of_bytes(
      @core.slice(data, bstart, bstart + blen),
      true,
    )
    pos = bstart + blen
  }
  let mut min_ts : Int64 = 0
  let mut max_ts : Int64 = 0
  let mut time_known = false
  if version >= 3 {
    if pos + 20 > body_end {
      raise @core.MetaError::Truncated(pos)
    }
    min_ts = meta_i64(data, pos)
    max_ts = meta_i64(data, pos + 8)
    time_known = meta_u32(data, pos + 16) == 1
    pos = pos + 20
  }
  let mut data_crc : UInt32 = 0
  let mut crc_known = false
  if version >= 4 {
    if pos + 8 > body_end {
      raise @core.MetaError::Truncated(pos)
    }
    data_crc = meta_u32(data, pos)
    crc_known = meta_u32(data, pos + 4) == 1
    pos = pos + 8
  }
  let mut compressed = false
  let mut raw_size : Int64 = 0
  if version >= 5 {
    if pos + 12 > body_end {
      raise @core.MetaError::Truncated(pos)
    }
    compressed = meta_u32(data, pos) == 1
    raw_size = meta_i64(data, pos + 4)
  }
  {
    base_offset,
    next_offset,
    record_count,
    size,
    interval,
    entries,
    bloom,
    min_ts,
    max_ts,
    time_known,
    data_crc,
    crc_known,
    compressed,
    raw_size,
  }
}

///|
/// Snapshot the segment's counters and sparse index for persistence.
pub fn[W, R] Segment::to_meta(self : Segment[W, R]) -> SegmentMeta {
  {
    base_offset: self.base_offset,
    next_offset: self.next_offset,
    record_count: self.record_count.reinterpret_as_uint(),
    size: self.size,
    interval: self.index.interval,
    entries: self.index.entries,
    bloom: self.bloom,
    min_ts: self.min_ts,
    max_ts: self.max_ts,
    time_known: self.time_known,
    data_crc: self.data_crc,
    crc_known: self.crc_known,
    compressed: self.compressed,
    raw_size: self.raw_size,
  }
}

///|
/// Restore counters and the sparse index from persisted metadata, marking the
/// segment as loaded from metadata (so recovery can be skipped).
pub fn[W, R] Segment::apply_meta(
  self : Segment[W, R],
  meta : SegmentMeta,
) -> Unit {
  self.base_offset = meta.base_offset
  self.next_offset = meta.next_offset
  self.record_count = meta.record_count.reinterpret_as_int()
  self.size = meta.size
  self.index = SparseIndex::new(meta.interval)
  for e in meta.entries {
    self.index.push(e.record_index, e.position)
  }
  self.bloom = meta.bloom
  self.min_ts = meta.min_ts
  self.max_ts = meta.max_ts
  self.time_known = meta.time_known
  self.data_crc = meta.data_crc
  self.crc_known = meta.crc_known
  self.compressed = meta.compressed
  self.raw_size = meta.raw_size
  self.meta_loaded = true
}
