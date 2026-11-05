///|
test "parse_kv_pairs extracts name=value segments" {
  let pairs = @core.parse_kv_pairs(b"level=error msg=http timeout=30")
  assert_eq(pairs.length(), 3)
  assert_eq(pairs[0], (b"level", b"error"))
  assert_eq(pairs[1], (b"msg", b"http"))
  assert_eq(pairs[2], (b"timeout", b"30"))
}

///|
test "parse_kv_pairs skips malformed segments and keeps value equals" {
  let pairs = @core.parse_kv_pairs(b"  standalone level=error url=a=b ")
  assert_eq(pairs.length(), 2)
  assert_eq(pairs[0], (b"level", b"error"))
  assert_eq(pairs[1], (b"url", b"a=b"))
}

///|
test "parse_kv_pairs handles empty input and single segment" {
  assert_eq(@core.parse_kv_pairs(b"").length(), 0)
  let pairs = @core.parse_kv_pairs(b"k=v")
  assert_eq(pairs.length(), 1)
  assert_eq(pairs[0], (b"k", b"v"))
}
