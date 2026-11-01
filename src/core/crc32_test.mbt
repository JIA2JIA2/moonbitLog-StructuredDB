///|
test "crc32 matches known vectors" {
  assert_eq(@core.crc32(b"123456789"), (0xCBF43926 : UInt32))
  assert_eq(@core.crc32(b""), (0 : UInt32))
  assert_eq(@core.crc32_range(b"abcdef", 1, 4), @core.crc32(b"bcd"))
}
