///|
test "canonical_field maps the six slots with aliases" {
  assert_eq(@core.canonical_field(b"ts"), 0)
  assert_eq(@core.canonical_field(b"@timestamp"), 0)
  assert_eq(@core.canonical_field(b"severity"), 1)
  assert_eq(@core.canonical_field(b"service_name"), 2)
  assert_eq(@core.canonical_field(b"app"), 2)
  assert_eq(@core.canonical_field(b"hostname"), 3)
  assert_eq(@core.canonical_field(b"traceId"), 4)
  assert_eq(@core.canonical_field(b"msg"), 5)
  assert_eq(@core.canonical_field(b"unknown"), -1)
}

///|
test "schema_from_fields extracts six fields with alias and first-wins" {
  let fields = @core.parse_kv_pairs(
    b"severity=error service_name=orders host=h1 traceId=t9 msg=boom @timestamp=1000 extra=x",
  )
  let f = @core.schema_from_fields(fields, (7 : Int64))
  match f.ts {
    // "1000" is below the 1e11 threshold, so normalize_ts reads it as
    // 1000 seconds → 1,000,000 ms.
    Some(t) => assert_eq(t, (1000000 : Int64))
    None => panic()
  }
  match f.level {
    Some(l) => assert_eq(l, b"error")
    None => panic()
  }
  match f.service {
    Some(s) => assert_eq(s, b"orders")
    None => panic()
  }
  match f.host {
    Some(h) => assert_eq(h, b"h1")
    None => panic()
  }
  match f.trace_id {
    Some(t) => assert_eq(t, b"t9")
    None => panic()
  }
  match f.message {
    Some(m) => assert_eq(m, b"boom")
    None => panic()
  }
  // Empty set: everything absent, ts stays None (fallback only applies
  // when a ts field exists but cannot be parsed).
  let empty = @core.schema_from_fields([], (7 : Int64))
  match empty.ts {
    None => ()
    Some(_) => panic()
  }
  // Unparsable ts value falls back.
  let bad = @core.schema_from_fields(
    @core.parse_kv_pairs(b"@timestamp=abc"),
    (7 : Int64),
  )
  match bad.ts {
    Some(t) => assert_eq(t, (7 : Int64))
    None => panic()
  }
}

///|
test "schema_value re-serializes in canonical order skipping absent fields" {
  let fields = @core.parse_kv_pairs(
    b"level=error trace_id=t9 msg=boom service=orders",
  )
  let f = @core.schema_from_fields(fields, (0 : Int64))
  assert_eq(@core.schema_value(f), b"level=error trace_id=t9 message=boom")
  // Only host present.
  let h = @core.schema_from_fields(
    @core.parse_kv_pairs(b"host=h1"),
    (0 : Int64),
  )
  assert_eq(@core.schema_value(h), b"host=h1")
}

///|
test "schema_matches applies AND across fields key and contains" {
  let fields = @core.parse_kv_pairs(
    b"level=error service=orders host=h1 trace_id=t9 msg=boom",
  )
  // All conditions hold.
  assert_true(
    @core.schema_matches(
      fields,
      b"orders",
      b"level=error host=h1 trace_id=t9 msg=boom",
      Some(b"error"),
      Some(b"orders"),
      Some(b"h1"),
      Some(b"t9"),
      Some(b"boom"),
    ),
  )
  // One mismatching field fails the AND.
  assert_true(
    !@core.schema_matches(
      fields,
      b"orders",
      b"level=error host=h1 trace_id=t9 msg=boom",
      Some(b"warn"),
      Some(b"orders"),
      None,
      None,
      None,
    ),
  )
  // service matches via key even without the field present.
  let no_svc : Array[(Bytes, Bytes)] = []
  assert_true(
    @core.schema_matches(
      no_svc,
      b"orders",
      b"anything",
      None,
      Some(b"orders"),
      None,
      None,
      None,
    ),
  )
  // contains is ASCII case-insensitive over the raw value.
  assert_true(
    @core.schema_matches(
      fields,
      b"orders",
      b"level=error host=h1 trace_id=t9 msg=boom",
      None,
      None,
      None,
      None,
      Some(b"BOOM"),
    ),
  )
}
