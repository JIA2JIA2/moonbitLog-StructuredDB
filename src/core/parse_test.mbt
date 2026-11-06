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
  let warn_fields = @core.parse_kv_pairs(b"level=warn")
  let info_fields = @core.parse_kv_pairs(b"level=info")
  let plain_fields : Array[(Bytes, Bytes)] = []
  assert_true(@core.sampling_allows(b"x level=warn", warn_fields, cfg))
  assert_true(!@core.sampling_allows(b"x level=info", info_fields, cfg))
  // Missing level field: never filtered by severity.
  assert_true(@core.sampling_allows(b"x plain", plain_fields, cfg))
  let inc : @core.SamplingConfig = {
    min_level: -1,
    level_field: b"level",
    sample_rate: 100,
    include_text: b"health",
    exclude_text: b"",
  }
  let health_fields : Array[(Bytes, Bytes)] = []
  let login_fields : Array[(Bytes, Bytes)] = []
  assert_true(@core.sampling_allows(b"health ping", health_fields, inc))
  assert_true(!@core.sampling_allows(b"user login", login_fields, inc))
  let exc : @core.SamplingConfig = {
    min_level: -1,
    level_field: b"level",
    sample_rate: 100,
    include_text: b"",
    exclude_text: b"noisy",
  }
  let noisy_fields : Array[(Bytes, Bytes)] = []
  let quiet_fields : Array[(Bytes, Bytes)] = []
  assert_true(!@core.sampling_allows(b"very noisy line", noisy_fields, exc))
  assert_true(@core.sampling_allows(b"quiet line", quiet_fields, exc))
}

///|
test "shell_quote wraps and escapes single quotes" {
  assert_eq(@core.shell_quote("plain"), "'plain'")
  assert_eq(@core.shell_quote("a'b"), "'a'\\''b'")
  assert_eq(@core.shell_quote(""), "''")
}

///|
test "parse_by_template extracts named placeholders" {
  let parsed = @core.parse_by_template(
    b"127.0.0.1 - frank [10/Oct/2000] \"GET\"", b"<ip> - <user> [<ts>] <rest>",
  )
  match parsed {
    Some(f) => {
      assert_eq(f.length(), 4)
      assert_eq(f[0], (b"ip", b"127.0.0.1"))
      assert_eq(f[1], (b"user", b"frank"))
      assert_eq(f[2], (b"ts", b"10/Oct/2000"))
      assert_eq(f[3], (b"rest", b"\"GET\""))
    }
    None => panic()
  }
}

///|
test "parse_by_template rejects literal mismatch and supports trailing capture" {
  match @core.parse_by_template(b"GET /x", b"POST <path>") {
    Some(_) => panic()
    None => ()
  }
  // Greedy capture: the placeholder runs up to the FIRST occurrence of the
  // next literal, so "500" is part of the captured level here.
  match @core.parse_by_template(b"error 500: oops", b"<level>: <msg>") {
    Some(f) => {
      assert_eq(f[0], (b"level", b"error 500"))
      assert_eq(f[1], (b"msg", b"oops"))
    }
    None => panic()
  }
}

///|
test "json_object_fields flattens top-level object fields" {
  let fields = @core.json_object_fields(
    b"{\"level\":\"error\",\"code\":500,\"ok\":true}",
  )
  let mut found_level = b""
  let mut found_code = b""
  let mut found_ok = b""
  for pair in fields {
    if pair.0 == b"level" {
      found_level = pair.1
    } else if pair.0 == b"code" {
      found_code = pair.1
    } else if pair.0 == b"ok" {
      found_ok = pair.1
    }
  }
  assert_eq(found_level, b"error")
  assert_eq(found_code, b"500")
  assert_eq(found_ok, b"true")
  // Non-object JSON yields no fields; malformed JSON raises (the ingest
  // pipeline catches and keeps nothing).
  assert_eq(@core.json_object_fields(b"[1,2]").length(), 0)
  let raised = try {
    ignore(@core.json_object_fields(b"not json"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}
