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

///|
test "canonical_field squashes case and separators (OTel aliases)" {
  assert_eq(@core.canonical_field(b"service.name"), 2)
  assert_eq(@core.canonical_field(b"service-name"), 2)
  assert_eq(@core.canonical_field(b"serviceName"), 2)
  assert_eq(@core.canonical_field(b"SERVICE_NAME"), 2)
  assert_eq(@core.canonical_field(b"svc"), 2)
  assert_eq(@core.canonical_field(b"trace.id"), 4)
  assert_eq(@core.canonical_field(b"host.name"), 3)
  assert_eq(@core.canonical_field(b"node"), 3)
  assert_eq(@core.canonical_field(b"severity_text"), 1)
  assert_eq(@core.canonical_field(b"body"), 5)
  assert_eq(@core.canonical_field(b"@timestamp"), 0)
  assert_eq(@core.canonical_field(b"request.user_id"), -1)
}

///|
test "schema_from_fields accepts OTel nested field names" {
  let fields = @core.parse_kv_pairs(
    b"@timestamp=2026-11-09T10:00:00Z severity_text=ERROR service.name=orders host.name=node-1 trace.id=t9 body=boom",
  )
  let f = @core.schema_from_fields(fields, (0 : Int64))
  match f.ts {
    Some(_) => ()
    None => panic()
  }
  match f.level {
    Some(v) => assert_eq(v, b"ERROR")
    None => panic()
  }
  match f.service {
    Some(v) => assert_eq(v, b"orders")
    None => panic()
  }
  match f.host {
    Some(v) => assert_eq(v, b"node-1")
    None => panic()
  }
  match f.trace_id {
    Some(v) => assert_eq(v, b"t9")
    None => panic()
  }
  match f.message {
    Some(v) => assert_eq(v, b"boom")
    None => panic()
  }
}

///|
test "schema_matches compares values case-insensitively and level synonyms" {
  let fields = @core.parse_kv_pairs(
    b"level=warn service=Orders host=Node-1 trace_id=T9 msg=boom",
  )
  assert_true(
    @core.schema_matches(
      fields,
      b"orders",
      b"level=warn",
      Some(b"WARNING"),
      Some(b"ORDERS"),
      Some(b"node-1"),
      Some(b"t9"),
      None,
    ),
  )
}

///|
test "severity_number maps onto the level slot with OTel bands" {
  // The field name squashes to a level alias.
  assert_eq(@core.canonical_field(b"severity_number"), 1)
  assert_eq(@core.canonical_field(b"SeverityNumber"), 1)
  // Extraction keeps the raw numeric value; band matching turns it into a
  // rank, so `severity_number=17` equals `error` but not `warn`.
  let fields = @core.parse_kv_pairs(
    b"severity_number=17 service=orders host=n1 trace_id=t9 message=boom",
  )
  let f = @core.schema_from_fields(fields, (0 : Int64))
  match f.level {
    Some(v) => assert_eq(v, b"17")
    None => panic()
  }
  assert_true(
    @core.schema_matches(
      fields,
      b"orders",
      b"severity_number=17",
      Some(b"error"),
      None,
      None,
      None,
      None,
    ),
  )
  assert_true(
    !@core.schema_matches(
      fields,
      b"orders",
      b"severity_number=17",
      Some(b"warn"),
      None,
      None,
      None,
      None,
    ),
  )
}

///|
test "schema_value quotes values with spaces so re-parse round-trips" {
  // A message with spaces is stored logfmt-quoted…
  let f = @core.schema_from_fields(
    @core.parse_kv_pairs(
      b"level=error trace_id=t9 message=\"user login failed\"",
    ),
    (0 : Int64),
  )
  let v = @core.schema_value(f)
  assert_eq(v, b"level=error trace_id=t9 message=\"user login failed\"")
  // …and the stored value re-parses to the exact original message.
  let back = @core.parse_kv_pairs(v)
  let f2 = @core.schema_from_fields(back, (0 : Int64))
  match f2.message {
    Some(m) => assert_eq(m, b"user login failed")
    None => panic()
  }
  // Embedded quotes and backslashes survive the round-trip too.
  let f3 = @core.schema_from_fields(
    @core.parse_kv_pairs(b"message=\"say \\\"hi\\\" now\""),
    (0 : Int64),
  )
  let v3 = @core.schema_value(f3)
  assert_eq(v3, b"message=\"say \\\"hi\\\" now\"")
  let back3 = @core.parse_kv_pairs(v3)
  match @core.schema_from_fields(back3, (0 : Int64)).message {
    Some(m) => assert_eq(m, b"say \"hi\" now")
    None => panic()
  }
  // Values without spaces stay bare.
  let f4 = @core.schema_from_fields(
    @core.parse_kv_pairs(b"message=boom"),
    (0 : Int64),
  )
  assert_eq(@core.schema_value(f4), b"message=boom")
}
