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

///|
test "level_rank is case-insensitive over words and numeric bands" {
  assert_eq(@core.level_rank(b"DEBUG"), 0)
  assert_eq(@core.level_rank(b"Info"), 1)
  assert_eq(@core.level_rank(b"WARN"), 2)
  assert_eq(@core.level_rank(b"Error"), 3)
  assert_eq(@core.level_rank(b"FATAL"), 4)
  assert_eq(@core.level_rank(b"CRIT"), 4)
  assert_eq(@core.level_rank(b"17"), 3)
  assert_eq(@core.level_rank(b"trace"), -1)
}

///|
test "sampling_allows auto-detects level aliases, nested fields and heads" {
  let cfg : @core.SamplingConfig = {
    min_level: 2,
    level_field: b"",
    sample_rate: 100,
    include_text: b"",
    exclude_text: b"",
  }
  let no_fields : Array[(Bytes, Bytes)] = []
  // Parsed field names: aliases and case-insensitive field/value.
  for alias in [b"level", b"lvl", b"severity", b"severity_text", b"Level"] {
    let debug_fields : Array[(Bytes, Bytes)] = [(alias, b"DEBUG")]
    assert_true(!@core.sampling_allows(b"{}", debug_fields, cfg))
  }
  // Flattened JSON nest: `log.level`.
  let nested_debug : Array[(Bytes, Bytes)] = [(b"log.level", b"DEBUG")]
  assert_true(!@core.sampling_allows(b"{}", nested_debug, cfg))
  let nested_warn : Array[(Bytes, Bytes)] = [(b"log.level", b"WARN")]
  assert_true(@core.sampling_allows(b"{}", nested_warn, cfg))
  // Leading plain-text token (bare, bracketed, after a timestamp, lowercase).
  assert_true(!@core.sampling_allows(b"DEBUG app started", no_fields, cfg))
  assert_true(!@core.sampling_allows(b"info ok", no_fields, cfg))
  assert_true(@core.sampling_allows(b"[WARN] disk full", no_fields, cfg))
  assert_true(@core.sampling_allows(b"INFO: ok", no_fields, cfg) == false)
  assert_true(
    @core.sampling_allows(b"2026-01-01T00:00:00Z ERROR boom", no_fields, cfg),
  )
  // Prose that merely starts with a level word is kept (never drop data on a
  // guess above the threshold).
  assert_true(@core.sampling_allows(b"Error rate is high", no_fields, cfg))
}

///|
test "sampling_allows honours an explicit level field only" {
  let cfg : @core.SamplingConfig = {
    min_level: 2,
    level_field: b"severity",
    sample_rate: 100,
    include_text: b"",
    exclude_text: b"",
  }
  let debug : Array[(Bytes, Bytes)] = [(b"severity", b"DEBUG")]
  let other : Array[(Bytes, Bytes)] = [(b"level", b"DEBUG")]
  assert_true(!@core.sampling_allows(b"", debug, cfg))
  // A different field must not be picked up when --level-field is explicit.
  assert_true(@core.sampling_allows(b"", other, cfg))
}

///|
test "sampling_reason separates level and rate drops" {
  let level_cfg : @core.SamplingConfig = {
    min_level: 2,
    level_field: b"",
    sample_rate: 100,
    include_text: b"",
    exclude_text: b"",
  }
  match @core.sampling_reason(b"level=DEBUG", [], level_cfg) {
    Some(@core.SampleDrop::BelowLevel) => ()
    _ => panic()
  }
  let rate_cfg : @core.SamplingConfig = {
    min_level: 2,
    level_field: b"",
    sample_rate: 0,
    include_text: b"",
    exclude_text: b"",
  }
  match @core.sampling_reason(b"level=ERROR", [], rate_cfg) {
    Some(@core.SampleDrop::Rate) => ()
    _ => panic()
  }
  let rule_cfg : @core.SamplingConfig = {
    min_level: -1,
    level_field: b"",
    sample_rate: 100,
    include_text: b"health",
    exclude_text: b"",
  }
  match @core.sampling_reason(b"user login", [], rule_cfg) {
    Some(@core.SampleDrop::Include) => ()
    _ => panic()
  }
}

///|
fn field_of(fields : Array[(Bytes, Bytes)], name : Bytes) -> Bytes {
  let mut out : Bytes = b"<missing>"
  for pair in fields {
    if pair.0 == name {
      out = pair.1
    }
  }
  out
}

///|
test "parse_by_template supports multi-token Grok-style patterns" {
  let tpl = b"<ts:\\d+-\\d+-\\d+ \\d+:\\d+:\\d+,\\d+> <level> [<thread>] <logger> - <msg>"
  match
    @core.parse_by_template(
      b"2026-11-25 10:00:00,123 INFO [main] svc - ok", tpl,
    ) {
    Some(fields) => {
      assert_eq(field_of(fields, b"ts"), b"2026-11-25 10:00:00,123")
      assert_eq(field_of(fields, b"level"), b"INFO")
      assert_eq(field_of(fields, b"thread"), b"main")
      assert_eq(field_of(fields, b"logger"), b"svc")
      assert_eq(field_of(fields, b"msg"), b"ok")
    }
    None => panic()
  }
  // A dotted IP is one multi-token pattern, not a stop at the first dot.
  match
    @core.parse_by_template(
      b"10.0.0.2 200", b"<ip:\\d+\\.\\d+\\.\\d+\\.\\d+> <status:\\d+>",
    ) {
    Some(fields) => {
      assert_eq(field_of(fields, b"ip"), b"10.0.0.2")
      assert_eq(field_of(fields, b"status"), b"200")
    }
    None => panic()
  }
}

///|
test "parse_by_template accepts '-' as a missing field value" {
  let tpl = b"<ip:\\d+\\.\\d+\\.\\d+\\.\\d+> <status:\\d+> <bytes:\\d+> <tail>"
  match @core.parse_by_template(b"10.0.0.2 401 - tail", tpl) {
    Some(fields) => assert_eq(field_of(fields, b"bytes"), b"-")
    None => panic()
  }
  match @core.parse_by_template(b"200 -", b"<status:\\d+> <bytes:\\d+>") {
    Some(fields) => assert_eq(field_of(fields, b"bytes"), b"-")
    None => panic()
  }
}

///|
test "json_object_fields tolerates wrapper prefixes and suffixes" {
  let f1 = @core.json_object_fields(
    b"2026-11-25T10:00:00.123Z {\"level\":\"info\",\"msg\":\"x\"}",
  )
  assert_eq(f1.length(), 2)
  assert_eq(field_of(f1, b"level"), b"info")
  let f2 = @core.json_object_fields(b"{\"a\":1} trailing")
  assert_eq(f2.length(), 1)
  assert_eq(field_of(f2, b"a"), b"1")
  // Braces inside strings must not end the object early.
  let f3 = @core.json_object_fields(
    b"prefix {\"msg\":\"a } b\",\"n\":2} suffix",
  )
  assert_eq(f3.length(), 2)
  assert_eq(field_of(f3, b"msg"), b"a } b")
  // Genuinely malformed input still reports a parse error.
  let bad : Array[(Bytes, Bytes)]? = Some(
    @core.json_object_fields(b"no json here"),
  ) catch {
    _ => None
  }
  assert_eq(bad is None, true)
}

///|
test "value_fields is the shared extraction contract across shapes" {
  // JSON body.
  assert_eq(
    @core.value_fields(b"{\"level\":\"error\",\"service\":\"orders\"}").length(),
    2,
  )
  // Container-wrapped JSON (CRI/Docker): the pre-filter used to see empty
  // columns here and `query --indexed` skipped segments that held matches.
  let wrapped = @core.value_fields(
    b"2026-11-25T10:00:00.123456789Z stdout F {\"level\":\"error\",\"service\":\"checkout\"}",
  )
  assert_eq(wrapped.length(), 2)
  // Trailing --meta kv pairs merge; a JSON field wins over a same-named
  // trailing pair (the JSON value is authoritative).
  let meta = @core.value_fields(
    b"{\"level\":\"warn\",\"env\":\"dev\"} env=prod region=cn",
  )
  assert_eq(meta.length(), 3)
  for pair in meta {
    if pair.0 == b"env" {
      assert_eq(pair.1, b"dev")
    }
  }
  // Plain kv records keep their shape.
  assert_eq(@core.value_fields(b"level=info service=api").length(), 2)
  // Quoted fragments of the JSON body cannot leak as fake field names.
  let leak = @core.value_fields(b"{\"note\":\"a=b y=z\"}")
  for pair in leak {
    if pair.0 == b"note" {
      assert_eq(pair.1, b"a=b y=z")
    }
  }
  assert_eq(leak.length(), 1)
}
