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

///|
test "level_rank maps common levels and passes unknown through" {
  assert_eq(@core.level_rank(b"debug"), 0)
  assert_eq(@core.level_rank(b"info"), 1)
  assert_eq(@core.level_rank(b"warn"), 2)
  assert_eq(@core.level_rank(b"warning"), 2)
  assert_eq(@core.level_rank(b"error"), 3)
  assert_eq(@core.level_rank(b"fatal"), 4)
  assert_eq(@core.level_rank(b"unknown"), -1)
}

///|
test "fnv1a_hash is deterministic and content-sensitive" {
  assert_eq(@core.fnv1a_hash(b"hello"), @core.fnv1a_hash(b"hello"))
  assert_true(@core.fnv1a_hash(b"hello") != @core.fnv1a_hash(b"hellp"))
  assert_true(@core.fnv1a_hash(b"") != (0 : UInt32))
}

///|
test "sample_passes keeps rate 100 and drops rate 0 deterministically" {
  assert_true(@core.sample_passes(b"anything", 100))
  assert_true(!@core.sample_passes(b"anything", 0))
  let line = b"sampled line 123"
  assert_eq(@core.sample_passes(line, 50), @core.sample_passes(line, 50))
}

///|
test "sampling_allows applies level include exclude and rate" {
  let cfg : @core.SamplingConfig = {
    min_level: 2,
    level_field: b"level",
    sample_rate: 100,
    include_text: b"",
    exclude_text: b"",
  }
  assert_true(@core.sampling_allows(b"x level=warn", b"level=warn", cfg))
  assert_true(!@core.sampling_allows(b"x level=info", b"level=info", cfg))
  // Missing level field: never filtered by severity.
  assert_true(@core.sampling_allows(b"x plain", b"plain", cfg))
  let inc : @core.SamplingConfig = {
    min_level: -1,
    level_field: b"level",
    sample_rate: 100,
    include_text: b"health",
    exclude_text: b"",
  }
  assert_true(@core.sampling_allows(b"health ping", b"health ping", inc))
  assert_true(!@core.sampling_allows(b"user login", b"user login", inc))
  let exc : @core.SamplingConfig = {
    min_level: -1,
    level_field: b"level",
    sample_rate: 100,
    include_text: b"",
    exclude_text: b"noisy",
  }
  assert_true(
    !@core.sampling_allows(b"very noisy line", b"very noisy line", exc),
  )
  assert_true(@core.sampling_allows(b"quiet line", b"quiet line", exc))
}

///|
test "shell_quote wraps and escapes single quotes" {
  assert_eq(@core.shell_quote("plain"), "'plain'")
  assert_eq(@core.shell_quote("a'b"), "'a'\\''b'")
  assert_eq(@core.shell_quote(""), "''")
}
