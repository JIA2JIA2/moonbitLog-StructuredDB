///|
/// A fixed-size Bloom filter over record keys. A `may_contain` result of
/// `false` is conclusive (the key is definitely absent); `true` only means
/// "maybe", so callers must still confirm with a real lookup. Segments use it
/// to skip a full scan when a queried key cannot be present.
///
/// A filter may be `disabled` (e.g. loaded from metadata written before the
/// filter existed). A disabled filter reports `true` for every key — it never
/// rules a segment out.
pub(all) struct BloomFilter {
  bits : Array[Byte]
  hashes : Int32
  enabled : Bool
}

///|
const BLOOM_BIT_COUNT : Int32 = 4096

///|
const BLOOM_HASH_COUNT : Int32 = 3

///|
fn bloom_zeroes(n : Int32) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  while i < n {
    out.push(0)
    i = i + 1
  }
  out
}

///|
pub fn BloomFilter::new() -> BloomFilter {
  {
    bits: bloom_zeroes(BLOOM_BIT_COUNT / 8),
    hashes: BLOOM_HASH_COUNT,
    enabled: true,
  }
}

///|
pub fn BloomFilter::disabled() -> BloomFilter {
  {
    bits: bloom_zeroes(BLOOM_BIT_COUNT / 8),
    hashes: BLOOM_HASH_COUNT,
    enabled: false,
  }
}

///|
/// Bit index for hash round `i`, derived from a base hash by an LCG so the
/// rounds are spread across the bit array.
fn bloom_bit(h : UInt32, i : Int32) -> Int32 {
  let mut v = h.reinterpret_as_int()
  let mut j = 0
  while j < i {
    v = v * 1103515245 + 12345
    j = j + 1
  }
  (v & 0x7FFFFFFF) % BLOOM_BIT_COUNT
}

///|
pub fn BloomFilter::add(self : BloomFilter, key : Bytes) -> Unit {
  let h = @core.crc32(key)
  let mut i = 0
  while i < self.hashes {
    let idx = bloom_bit(h, i)
    let bi = idx / 8
    let mask = 1 << (idx % 8)
    self.bits[bi] = (self.bits[bi].to_int() | mask).to_byte()
    i = i + 1
  }
}

///|
/// Whether `key` *might* be present. `false` is conclusive.
pub fn BloomFilter::may_contain(self : BloomFilter, key : Bytes) -> Bool {
  if !self.enabled {
    return true
  }
  let h = @core.crc32(key)
  let mut i = 0
  while i < self.hashes {
    let idx = bloom_bit(h, i)
    let bi = idx / 8
    let mask = 1 << (idx % 8)
    if (self.bits[bi].to_int() & mask) == 0 {
      return false
    }
    i = i + 1
  }
  true
}

///|
pub fn BloomFilter::to_bytes(self : BloomFilter) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  for b in self.bits {
    buf.write_byte(b)
  }
  buf.to_bytes()
}

///|
/// Rebuild a filter from raw bits. An unexpected length yields a disabled
/// filter, and `enabled = false` forces one regardless.
pub fn BloomFilter::of_bytes(data : Bytes, enabled : Bool) -> BloomFilter {
  if data.length() != BLOOM_BIT_COUNT / 8 {
    return BloomFilter::disabled()
  }
  let bits : Array[Byte] = []
  let mut i = 0
  while i < data.length() {
    bits.push(data.at(i))
    i = i + 1
  }
  { bits, hashes: BLOOM_HASH_COUNT, enabled, }
}
