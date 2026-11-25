///|
test "crc32 fixed-array range agrees with the byte path" {
  let payload = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  // Prefix/suffix bytes prove the range bounds are honoured, not just [0,len).
  let arr = FixedArray::make(payload.length() + 6, b'X')
  arr.blit_from_bytes(3, payload, 0, payload.length())
  for offset in [0, 1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 31, 33, 60] {
    if offset < payload.length() {
      let len = payload.length() - offset
      assert_eq(
        crc32_fixed_range(arr, 3 + offset, 3 + offset + len),
        crc32(slice(payload, offset, payload.length())),
      )
    }
  }
}
