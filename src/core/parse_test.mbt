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
test "parse_kv_pairs keeps quoted values intact (logfmt)" {
  // A quoted value carries spaces without splitting segments.
  let pairs = @core.parse_kv_pairs(b"message=\"user login failed\" host=n1")
  assert_eq(pairs.length(), 2)
  assert_eq(pairs[0], (b"message", b"user login failed"))
  assert_eq(pairs[1], (b"host", b"n1"))
  // Escaped quotes unescape to `"`; `=` inside quotes stays in the value.
  let esc = @core.parse_kv_pairs(b"msg=\"say \\\"hi\\\" now\" k=a=b")
  assert_eq(esc.length(), 2)
  assert_eq(esc[0], (b"msg", b"say \"hi\" now"))
  assert_eq(esc[1], (b"k", b"a=b"))
  // Backslash escape.
  let bs = @core.parse_kv_pairs(b"msg=\"back\\\\slash x\" tail=1")
  assert_eq(bs[0], (b"msg", b"back\\slash x"))
  assert_eq(bs[1], (b"tail", b"1"))
  // Unterminated quote keeps the rest of the line in one segment.
  let open = @core.parse_kv_pairs(b"msg=\"unclosed rest of line")
  assert_eq(open.length(), 1)
  assert_eq(open[0], (b"msg", b"\"unclosed rest of line"))
  // Bare values (no quotes) are byte-exactly unchanged.
  let bare = @core.parse_kv_pairs(b"level=error trace_id=t9")
  assert_eq(bare[0], (b"level", b"error"))
  assert_eq(bare[1], (b"trace_id", b"t9"))
}

///|
test "level_rank maps numeric OTel severity bands" {
  // 1-8 → debug, 9-12 → info, 13-16 → warn, 17-20 → error, 21-24 → fatal.
  assert_eq(@core.level_rank(b"1"), 0)
  assert_eq(@core.level_rank(b"8"), 0)
  assert_eq(@core.level_rank(b"9"), 1)
  assert_eq(@core.level_rank(b"12"), 1)
  assert_eq(@core.level_rank(b"13"), 2)
  assert_eq(@core.level_rank(b"16"), 2)
  assert_eq(@core.level_rank(b"17"), 3)
  assert_eq(@core.level_rank(b"20"), 3)
  assert_eq(@core.level_rank(b"21"), 4)
  assert_eq(@core.level_rank(b"24"), 4)
  // 0 (undefined) and out-of-range numbers stay unknown.
  assert_eq(@core.level_rank(b"0"), -1)
  assert_eq(@core.level_rank(b"25"), -1)
  assert_eq(@core.level_rank(b"100"), -1)
  // Named levels still map through the string table.
  assert_eq(@core.level_rank(b"warn"), 2)
  assert_eq(@core.level_rank(b"nonsense"), -1)
}

///|
test "level_rank maps syslog severity words to fatal" {
  // crit/critical/alert/emerg/panic used to return -1 (unknown) and be
  // dropped by every level-aware consumer; they rank as fatal (4).
  assert_eq(@core.level_rank(b"critical"), 4)
  assert_eq(@core.level_rank(b"crit"), 4)
  assert_eq(@core.level_rank(b"alert"), 4)
  assert_eq(@core.level_rank(b"emerg"), 4)
  assert_eq(@core.level_rank(b"panic"), 4)
  // err keeps its error rank; unknown words stay unknown.
  assert_eq(@core.level_rank(b"err"), 3)
  assert_eq(@core.level_rank(b"emerge"), -1)
  assert_eq(@core.level_rank(b"criticality"), -1)
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
test "sampling_allows reads level from a plain line without parsed fields" {
  let cfg : @core.SamplingConfig = {
    min_level: 2,
    level_field: b"level",
    sample_rate: 100,
    include_text: b"",
    exclude_text: b"",
  }
  let no_fields : Array[(Bytes, Bytes)] = []
  assert_true(!@core.sampling_allows(b"ts=1 level=debug msg=x", no_fields, cfg))
  assert_true(!@core.sampling_allows(b"ts=1 level=info msg=x", no_fields, cfg))
  assert_true(@core.sampling_allows(b"ts=1 level=warn msg=x", no_fields, cfg))
  assert_true(@core.sampling_allows(b"ts=1 level=error msg=x", no_fields, cfg))
  assert_true(
    @core.sampling_allows(
      b"{\"level\":\"error\",\"msg\":\"x\"}", no_fields, cfg,
    ),
  )
  // Unknown level and a lookalike field name must not be filtered.
  assert_true(@core.sampling_allows(b"ts=1 level=trace msg=x", no_fields, cfg))
  assert_true(@core.sampling_allows(b"mylevel=debug msg=x", no_fields, cfg))
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

///|
test "parse_by_template supports restricted grok patterns" {
  let tpl = b"<ip:[\\d.]+> - <user:\\S+> [<ts:[0-9A-Za-z/:+ -]+>] \"<method:\\w+> <path:\\S+> <proto:\\S+>\" <status:\\d+> <size:\\d+>"
  let line = b"127.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] \"GET /a.gif HTTP/1.0\" 200 2326"
  match @core.parse_by_template(line, tpl) {
    Some(f) => {
      assert_eq(f.length(), 8)
      assert_eq(f[0], (b"ip", b"127.0.0.1"))
      assert_eq(f[1], (b"user", b"frank"))
      assert_eq(f[2], (b"ts", b"10/Oct/2000:13:55:36 -0700"))
      assert_eq(f[3], (b"method", b"GET"))
      assert_eq(f[4], (b"path", b"/a.gif"))
      assert_eq(f[5], (b"proto", b"HTTP/1.0"))
      assert_eq(f[6], (b"status", b"200"))
      assert_eq(f[7], (b"size", b"2326"))
    }
    None => panic()
  }
}

///|
test "parse_by_template non-greedy pattern stops at the first literal" {
  match @core.parse_by_template(b"a\"b\"", b"<msg:\\S+?>\"") {
    Some(f) => assert_eq(f[0], (b"msg", b"a"))
    None => panic()
  }
}

///|
test "json_object_fields flattens nested objects with dotted names" {
  let fields = @core.json_object_fields(
    b"{\"level\":\"error\",\"request\":{\"user_id\":\"u1\",\"path\":\"/x\"},\"code\":500}",
  )
  let mut found = 0
  for pair in fields {
    if pair.0 == b"request.user_id" && pair.1 == b"u1" {
      found = found + 1
    } else if pair.0 == b"request.path" && pair.1 == b"/x" {
      found = found + 1
    } else if pair.0 == b"level" && pair.1 == b"error" {
      found = found + 1
    } else if pair.0 == b"code" && pair.1 == b"500" {
      found = found + 1
    }
  }
  assert_eq(found, 4)
}
