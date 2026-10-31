///|
/// CRC32 (IEEE 802.3, polynomial 0xEDB88320) computed bit-by-bit.
/// A table-driven version can replace this later for throughput.
fn crc32_range(data : Bytes, start : Int32, end : Int32) -> UInt32 {
  let mut crc : UInt64 = (0xFFFFFFFF : UInt64)
  for i = start; i < end; i = i + 1 {
    crc = crc ^ data.at(i).to_uint64()
    let mut j = 0
    while j < 8 {
      if (crc & (1 : UInt64)) == (1 : UInt64) {
        crc = (0xEDB88320 : UInt64) ^ (crc >> 1)
      } else {
        crc = crc >> 1
      }
      j = j + 1
    }
  }
  (crc ^ (0xFFFFFFFF : UInt64)).to_uint()
}

///|
/// CRC32 of an entire byte buffer.
pub fn crc32(data : Bytes) -> UInt32 {
  crc32_range(data, 0, data.length())
}
