///|
/// Build the 256-entry CRC32 lookup table (polynomial 0xEDB88320).
fn build_crc_table() -> Array[UInt64] {
  let table : Array[UInt64] = []
  let mut n = 0
  while n < 256 {
    let mut c : UInt64 = n.to_uint64()
    let mut k = 0
    while k < 8 {
      if (c & (1 : UInt64)) == (1 : UInt64) {
        c = (0xEDB88320 : UInt64) ^ (c >> 1)
      } else {
        c = c >> 1
      }
      k = k + 1
    }
    table.push(c)
    n = n + 1
  }
  table
}

///|
/// CRC32 (IEEE 802.3, polynomial 0xEDB88320) computed through a lookup table
/// built once at module load.
let crc_table : Array[UInt64] = build_crc_table()

///|
/// CRC32 of `data[start, end)`.
pub fn crc32_range(data : Bytes, start : Int32, end : Int32) -> UInt32 {
  let mut crc : UInt64 = (0xFFFFFFFF : UInt64)
  for i = start; i < end; i = i + 1 {
    let idx = ((crc ^ data.at(i).to_uint64()) & (0xFF : UInt64)).to_int()
    crc = crc_table[idx] ^ (crc >> 8)
  }
  (crc ^ (0xFFFFFFFF : UInt64)).to_uint()
}

///|
/// CRC32 of an entire byte buffer.
pub fn crc32(data : Bytes) -> UInt32 {
  crc32_range(data, 0, data.length())
}
