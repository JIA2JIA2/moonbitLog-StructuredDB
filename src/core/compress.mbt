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
