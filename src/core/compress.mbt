///|
/// Run-length encoding for segment data. A run of three or more identical bytes
/// is stored as `0xFF count byte`; a literal `0xFF` is stored as
/// `0xFF 0x00 0xFF`. So `0xFF` never appears as a plain byte and every other
/// byte passes through unchanged.
pub fn rle_compress(data : Bytes) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  let n = data.length()
  let mut i = 0
  while i < n {
    let b = data.at(i)
    let mut j = i + 1
    while j < n && data.at(j) == b && j - i < 255 {
      j = j + 1
    }
    let run = j - i
    if run >= 3 {
      out.write_byte((0xFF : Byte))
      out.write_byte(run.to_byte())
      out.write_byte(b)
    } else {
      let mut k = 0
      while k < run {
        if b == (0xFF : Byte) {
          out.write_byte((0xFF : Byte))
          out.write_byte((0 : Byte))
          out.write_byte((0xFF : Byte))
        } else {
          out.write_byte(b)
        }
        k = k + 1
      }
    }
    i = j
  }
  out.to_bytes()
}

///|
/// Inverse of `rle_compress`. `raw_len` bounds the expected output length and
/// guards against a corrupt or truncated stream.
pub fn rle_decompress(data : Bytes, raw_len : Int64) -> Bytes raise MetaError {
  let out = @buffer.Buffer::Buffer()
  let n = data.length()
  let mut i = 0
  let mut produced : Int64 = 0
  while i < n && produced < raw_len {
    let b = data.at(i)
    if b == (0xFF : Byte) {
      if i + 2 >= n {
        raise MetaError::Truncated(i)
      }
      let count = data.at(i + 1).to_int().to_int64()
      let val = data.at(i + 2)
      if count == 0 {
        out.write_byte(val)
        produced = produced + 1
      } else {
        let mut k : Int64 = 0
        while k < count {
          out.write_byte(val)
          k = k + 1
        }
        produced = produced + count
      }
      i = i + 3
    } else {
      out.write_byte(b)
      produced = produced + 1
      i = i + 1
    }
  }
  out.to_bytes()
}

///|
/// LZSS window size (bytes of history a match may reference).
const LZ_WINDOW : Int32 = 4096

///|
/// Minimum match length worth encoding.
const LZ_MIN_MATCH : Int32 = 3

///|
/// Maximum match length (fits in 4 bits with `LZ_MIN_MATCH` subtracted).
const LZ_MAX_MATCH : Int32 = 18

///|
/// Maximum number of backward candidates probed per position (a soft cap that
/// trades a little ratio for bounded encode time).
const LZ_MAX_CHAIN : Int32 = 256

///|
/// Hash of the three bytes at `pos` into the 4096-bucket chain table.
fn lz_hash3(data : Bytes, pos : Int32) -> Int32 {
  let a = data.at(pos).to_int()
  let b = data.at(pos + 1).to_int()
  let c = data.at(pos + 2).to_int()
  ((a << 4) ^ (b << 8) ^ c) & 4095
}

///|
/// Best match for `data[pos..]` using a hash chain over the 4 KiB window,
/// scanning at most `LZ_MAX_CHAIN` candidates and inserting `pos` afterwards.
/// The previous linear back-scan only looked at the last 64 positions, so
/// repeated log lines further apart never matched and "compression" could
/// even grow the segment. Returns `(distance, length)`; distance 0 means no
/// match of at least `LZ_MIN_MATCH`.
fn lz_find_match(
  data : Bytes,
  pos : Int32,
  n : Int32,
  head : FixedArray[Int32],
  prev : FixedArray[Int32],
) -> (Int32, Int32) {
  let remaining = n - pos
  let max_len = if remaining > LZ_MAX_MATCH { LZ_MAX_MATCH } else { remaining }
  if max_len < LZ_MIN_MATCH {
    return (0, 0)
  }
  let start = if pos > LZ_WINDOW { pos - LZ_WINDOW } else { 0 }
  let h = lz_hash3(data, pos)
  let mut cand = head[h]
  let mut best_len = 0
  let mut best_dist = 0
  let mut tries = 0
  while cand >= start && cand >= 0 && tries < LZ_MAX_CHAIN {
    if data.at(cand) == data.at(pos) {
      let mut l = 1
      while l < max_len && data.at(cand + l) == data.at(pos + l) {
        l = l + 1
      }
      if l > best_len {
        best_len = l
        best_dist = pos - cand
        if l == max_len {
          break
        }
      }
    }
    cand = prev[cand]
    tries = tries + 1
  }
  prev[pos] = head[h]
  head[h] = pos
  if best_len >= LZ_MIN_MATCH {
    (best_dist, best_len)
  } else {
    (0, 0)
  }
}

///|
/// LZSS compression over a 4 KiB window. Output is a sequence of blocks, each
/// an 8-bit flag byte (1 = match, 0 = literal) followed by its tokens: a match
/// is two little-endian bytes holding `(dist-1)` in 12 bits and `(len-3)` in 4.
pub fn lz_compress(data : Bytes) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  let n = data.length()
  // Hash-chain window (3-byte buckets) instead of a 64-entry linear scan.
  let head : FixedArray[Int32] = FixedArray::make(4096, -1)
  let prev : FixedArray[Int32] = FixedArray::make(n, -1)
  let mut i = 0
  while i < n {
    let tokens = @buffer.Buffer::Buffer()
    let mut flag : Int32 = 0
    let mut bit = 0
    while bit < 8 && i < n {
      let (dist, len) = lz_find_match(data, i, n, head, prev)
      if dist > 0 {
        flag = flag | (1 << bit)
        let v = ((dist - 1) & 0xFFF) | ((len - 3) << 12)
        tokens.write_byte((v & 0xFF).to_byte())
        tokens.write_byte(((v >> 8) & 0xFF).to_byte())
        i = i + len
      } else {
        tokens.write_byte(data.at(i))
        i = i + 1
      }
      bit = bit + 1
    }
    let flagbuf = @buffer.Buffer::Buffer()
    flagbuf.write_byte(flag.to_byte())
    out.write_bytes(flagbuf.to_bytes())
    out.write_bytes(tokens.to_bytes())
  }
  out.to_bytes()
}

///|
/// Inverse of `lz_compress`. `raw_len` bounds the expected output length and
/// guards against a corrupt or truncated stream.
pub fn lz_decompress(data : Bytes, raw_len : Int64) -> Bytes raise MetaError {
  let out : Array[Byte] = []
  let n = data.length()
  let mut pos = 0
  let mut produced : Int64 = 0
  while pos < n && produced < raw_len {
    let flags = data.at(pos).to_int()
    pos = pos + 1
    let mut bit = 0
    while bit < 8 && pos < n && produced < raw_len {
      if (flags & (1 << bit)) != 0 {
        if pos + 2 > n {
          raise MetaError::Truncated(pos)
        }
        let v = data.at(pos).to_int() | (data.at(pos + 1).to_int() << 8)
        let dist = (v & 0xFFF) + 1
        let len = ((v >> 12) & 0xF) + 3
        pos = pos + 2
        let start = out.length() - dist
        if start < 0 {
          raise MetaError::Truncated(pos)
        }
        let mut k = 0
        while k < len {
          out.push(out[start + k])
          k = k + 1
          produced = produced + 1
        }
      } else {
        if pos >= n {
          raise MetaError::Truncated(pos)
        }
        out.push(data.at(pos))
        pos = pos + 1
        produced = produced + 1
      }
      bit = bit + 1
    }
  }
  Bytes::from_array(out[:])
}
