///|
test "crc32 matches known vectors" {
  assert_eq(@core.crc32(b"123456789"), (0xCBF43926 : UInt32))
  assert_eq(@core.crc32(b""), (0 : UInt32))
  assert_eq(@core.crc32_range(b"abcdef", 1, 4), @core.crc32(b"bcd"))
}

///|
fn repeat_a(n : Int32) -> Bytes {
  FixedArray::make(n, b'a').unsafe_reinterpret_as_bytes()
}

///|
test "crc32 slicing matches published vectors around the word boundary" {
  // The eight-byte slicing loop, its byte tail, and the empty/one-byte paths
  // are all exercised; expectations come from zlib.crc32.
  let vectors : Array[(Int32, UInt32)] = [
    (0, (0x00000000 : UInt32)),
    (1, (0xE8B7BE43 : UInt32)),
    (7, (0x5B8B2074 : UInt32)),
    (8, (0xBF848046 : UInt32)),
    (9, (0x77B7DE66 : UInt32)),
    (15, (0x63973C71 : UInt32)),
    (16, (0xCFD668D5 : UInt32)),
    (17, (0x1EC14E70 : UInt32)),
    (31, (0x04BF8DB6 : UInt32)),
    (32, (0xCAB11777 : UInt32)),
    (33, (0x261CEBCB : UInt32)),
    (100, (0xAF707A64 : UInt32)),
    (161, (0x60F75140 : UInt32)),
    (1000, (0x9A38DA03 : UInt32)),
  ]
  for v in vectors {
    let (n, want) = v
    assert_eq(@core.crc32(repeat_a(n)), want)
  }
  assert_eq(@core.crc32(b"abcdefgh"), (0xAEEF2A50 : UInt32))
}
