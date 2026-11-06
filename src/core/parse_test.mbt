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

///|
test "bytes_contains finds substrings" {
  assert_true(@core.bytes_contains(b"hello world", b"world"))
  assert_true(@core.bytes_contains(b"hello world", b"lo wo"))
  assert_true(@core.bytes_contains(b"hello", b""))
  assert_true(!@core.bytes_contains(b"hi", b"hello"))
  assert_true(!@core.bytes_contains(b"hello", b"world"))
  assert_true(!@core.bytes_contains(b"", b"x"))
}

///|
test "bytes_contains_ci folds ASCII case" {
  assert_true(@core.bytes_contains_ci(b"Hello World", b"hello"))
  assert_true(@core.bytes_contains_ci(b"service=ERROR upstream", b"error"))
  assert_true(!@core.bytes_contains_ci(b"hello", b"world"))
  assert_true(@core.bytes_contains_ci(b"x", b""))
}
