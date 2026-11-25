///|
/// Build the 256-entry CRC32 lookup table (polynomial 0xEDB88320).
fn build_crc_table() -> FixedArray[UInt32] {
  let table = FixedArray::make(256, (0 : UInt32))
  let mut n = 0
  while n < 256 {
    let mut c : UInt32 = n.reinterpret_as_uint()
    let mut k = 0
    while k < 8 {
      if (c & (1 : UInt32)) == (1 : UInt32) {
        c = (0xEDB88320 : UInt32) ^ (c >> 1)
      } else {
        c = c >> 1
      }
      k = k + 1
    }
    table.unsafe_set(n, c)
    n = n + 1
  }
  table
}

///|
/// Base CRC32 table (polynomial 0xEDB88320), built once at module load.
let crc_table : FixedArray[UInt32] = build_crc_table()

///|
/// Eight slicing tables: `sliced[k * 256 + i]` is the CRC advance for byte `i`
/// at byte position `k` of an eight-byte word. Slicing by eight retires eight
/// input bytes per round with independent table probes instead of eight
/// serial rounds, which is the dominant cost of `Record::encode` on the bulk
/// append path.
fn build_crc_table_sliced() -> FixedArray[UInt32] {
  let out = FixedArray::make(8 * 256, (0 : UInt32))
  let mut i = 0
  while i < 256 {
    out.unsafe_set(i, crc_table.unsafe_get(i))
    i = i + 1
  }
  let mut k = 1
  while k < 8 {
    let mut j = 0
    while j < 256 {
      let prev = out.unsafe_get((k - 1) * 256 + j)
      out.unsafe_set(
        k * 256 + j,
        crc_table.unsafe_get((prev & (0xFF : UInt32)).reinterpret_as_int()) ^
        (prev >> 8),
      )
      j = j + 1
    }
    k = k + 1
  }
  out
}

///|
let crc_table_sliced : FixedArray[UInt32] = build_crc_table_sliced()

///|
/// CRC32 of `data[start, end)`. The eight-byte slicing loop also exists for
/// `FixedArray[Byte]` in `crc32_fixed_range` — keep the two in sync.
pub fn crc32_range(data : Bytes, start : Int32, end : Int32) -> UInt32 {
  let mut crc : UInt32 = (0xFFFFFFFF : UInt32)
  let mut i = start
  let bulk_end = start + (end - start) / 8 * 8
  while i < bulk_end {
    let lo = data.at(i).to_uint() |
      (data.at(i + 1).to_uint() << 8) |
      (data.at(i + 2).to_uint() << 16) |
      (data.at(i + 3).to_uint() << 24)
    let hi = data.at(i + 4).to_uint() |
      (data.at(i + 5).to_uint() << 8) |
      (data.at(i + 6).to_uint() << 16) |
      (data.at(i + 7).to_uint() << 24)
    crc = crc ^ lo
    crc = crc_table_sliced.unsafe_get(
        7 * 256 + (crc & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        6 * 256 + ((crc >> 8) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        5 * 256 + ((crc >> 16) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        4 * 256 + ((crc >> 24) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        3 * 256 + (hi & (0xFF : UInt32)).reinterpret_as_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        2 * 256 + ((hi >> 8) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        1 * 256 + ((hi >> 16) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        0 * 256 + ((hi >> 24) & (0xFF : UInt32)).to_int(),
      )
    i = i + 8
  }
  while i < end {
    crc = crc_table.unsafe_get(
        ((crc ^ data.at(i).to_uint()) & (0xFF : UInt32)).to_int(),
      ) ^
      (crc >> 8)
    i = i + 1
  }
  crc ^ (0xFFFFFFFF : UInt32)
}

///|
/// CRC32 of a `FixedArray[Byte]` slice. `Record::encode` already owns the
/// destination array, so reading it through `unsafe_get` avoids the byte-view
/// bounds checks on the dominant append-path CRC.
fn crc32_fixed_range(
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
) -> UInt32 {
  let mut crc : UInt32 = (0xFFFFFFFF : UInt32)
  let mut i = start
  let bulk_end = start + (end - start) / 8 * 8
  while i < bulk_end {
    let lo = data.unsafe_get(i).to_uint() |
      (data.unsafe_get(i + 1).to_uint() << 8) |
      (data.unsafe_get(i + 2).to_uint() << 16) |
      (data.unsafe_get(i + 3).to_uint() << 24)
    let hi = data.unsafe_get(i + 4).to_uint() |
      (data.unsafe_get(i + 5).to_uint() << 8) |
      (data.unsafe_get(i + 6).to_uint() << 16) |
      (data.unsafe_get(i + 7).to_uint() << 24)
    crc = crc ^ lo
    crc = crc_table_sliced.unsafe_get(
        7 * 256 + (crc & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        6 * 256 + ((crc >> 8) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        5 * 256 + ((crc >> 16) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        4 * 256 + ((crc >> 24) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        3 * 256 + (hi & (0xFF : UInt32)).reinterpret_as_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        2 * 256 + ((hi >> 8) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        1 * 256 + ((hi >> 16) & (0xFF : UInt32)).to_int(),
      ) ^
      crc_table_sliced.unsafe_get(
        0 * 256 + ((hi >> 24) & (0xFF : UInt32)).to_int(),
      )
    i = i + 8
  }
  while i < end {
    crc = crc_table.unsafe_get(
        ((crc ^ data.unsafe_get(i).to_uint()) & (0xFF : UInt32)).to_int(),
      ) ^
      (crc >> 8)
    i = i + 1
  }
  crc ^ (0xFFFFFFFF : UInt32)
}

///|
/// CRC32 of an entire byte buffer.
pub fn crc32(data : Bytes) -> UInt32 {
  crc32_range(data, 0, data.length())
}
