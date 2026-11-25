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
  // Extraction normalizes the number onto the OTel band word form, so
  // `severity_number=17` and `severity_text=ERROR` store the same schema
  // shape and `--level error` matches literally as well as by rank.
  let fields = @core.parse_kv_pairs(
    b"severity_number=17 service=orders host=n1 trace_id=t9 message=boom",
  )
  let f = @core.schema_from_fields(fields, (0 : Int64))
  match f.level {
    Some(v) => assert_eq(v, b"error")
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

///|
test "OTel JSON nested shapes normalize all six fields" {
  let fields = @core.json_object_fields(
    b"{\"timeUnixNano\":\"1732531200000000000\",\"severityText\":\"ERROR\",\"severityNumber\":17,\"body\":{\"stringValue\":\"db connection timeout\"},\"resource\":{\"service\":{\"name\":\"checkout\"},\"host\":{\"name\":\"pod-7x\"}},\"traceId\":\"abc123\"}",
  )
  let f = @core.schema_from_fields(fields, (0 : Int64))
  match f.ts {
    Some(t) => assert_eq(t, (1732531200000 : Int64))
    None => panic()
  }
  match f.level {
    Some(v) => assert_eq(v, b"ERROR")
    None => panic()
  }
  match f.service {
    Some(v) => assert_eq(v, b"checkout")
    None => panic()
  }
  match f.host {
    Some(v) => assert_eq(v, b"pod-7x")
    None => panic()
  }
  match f.trace_id {
    Some(v) => assert_eq(v, b"abc123")
    None => panic()
  }
  match f.message {
    Some(v) => assert_eq(v, b"db connection timeout")
    None => panic()
  }
}

///|
test "ECS nested shapes resolve log.level, error.message, error.trace.id" {
  let fields = @core.json_object_fields(
    b"{\"@timestamp\":\"2026-11-25T10:00:01.500Z\",\"log\":{\"level\":\"warn\"},\"service\":{\"name\":\"billing\"},\"host\":{\"name\":\"node-2\"},\"error\":{\"message\":\"pool exhausted\",\"trace\":{\"id\":\"tr-ecs-9\"}}}",
  )
  let f = @core.schema_from_fields(fields, (0 : Int64))
  match f.ts {
    Some(t) => assert_eq(t, (1795600801500 : Int64))
    None => panic()
  }
  match f.level {
    Some(v) => assert_eq(v, b"warn")
    None => panic()
  }
  match f.service {
    Some(v) => assert_eq(v, b"billing")
    None => panic()
  }
  match f.host {
    Some(v) => assert_eq(v, b"node-2")
    None => panic()
  }
  match f.trace_id {
    Some(v) => assert_eq(v, b"tr-ecs-9")
    None => panic()
  }
  match f.message {
    Some(v) => assert_eq(v, b"pool exhausted")
    None => panic()
  }
}

///|
test "journald kv lines normalize through the schema rounds" {
  let fields = @core.parse_kv_pairs(
    b"__REALTIME_TIMESTAMP=1732531200000123 _HOSTNAME=node-1 SYSLOG_IDENTIFIER=sshd PRIORITY=3 MESSAGE=Failed password",
  )
  let f = @core.schema_from_fields(fields, (0 : Int64))
  match f.ts {
    // journald __REALTIME_TIMESTAMP is microsecond precision; normalize_ts
    // scales it down to epoch milliseconds.
    Some(t) => assert_eq(t, (1732531200000 : Int64))
    None => panic()
  }
  match f.service {
    Some(v) => assert_eq(v, b"sshd")
    None => panic()
  }
  match f.host {
    Some(v) => assert_eq(v, b"node-1")
    None => panic()
  }
  match f.level {
    Some(v) => assert_eq(v, b"error")
    None => panic()
  }
  match f.message {
    Some(v) => assert_eq(v, b"Failed")
    None => panic()
  }
  assert_true(f.trace_id is None)
}

///|
test "level rounds prefer word forms over numbers regardless of order" {
  let a = @core.schema_from_fields(
    @core.parse_kv_pairs(b"severity_number=17 severity_text=ERROR"),
    (0 : Int64),
  )
  match a.level {
    Some(v) => assert_eq(v, b"ERROR")
    None => panic()
  }
  let b = @core.schema_from_fields(
    @core.parse_kv_pairs(b"severity_text=ERROR severity_number=17"),
    (0 : Int64),
  )
  match b.level {
    Some(v) => assert_eq(v, b"ERROR")
    None => panic()
  }
}

///|
test "OTel numeric severities normalize to band words" {
  fn num_level(v : Bytes) -> Bytes? {
    @core.schema_from_fields(
      [@core.parse_kv_pairs(b"severity_number=" + v)[0]],
      (0 : Int64),
    ).level
  }
  match num_level(b"1") {
    Some(v) => assert_eq(v, b"debug")
    None => panic()
  }
  match num_level(b"9") {
    Some(v) => assert_eq(v, b"info")
    None => panic()
  }
  match num_level(b"24") {
    Some(v) => assert_eq(v, b"fatal")
    None => panic()
  }
  assert_true(num_level(b"0") is None)
  assert_true(num_level(b"30") is None)
}

///|
test "syslog PRIORITY maps to the rank word form" {
  fn prio_level(v : Bytes) -> Bytes? {
    @core.schema_from_fields(
      [@core.parse_kv_pairs(b"priority=" + v)[0]],
      (0 : Int64),
    ).level
  }
  match prio_level(b"0") {
    Some(v) => assert_eq(v, b"fatal")
    None => panic()
  }
  match prio_level(b"2") {
    Some(v) => assert_eq(v, b"fatal")
    None => panic()
  }
  match prio_level(b"3") {
    Some(v) => assert_eq(v, b"error")
    None => panic()
  }
  match prio_level(b"4") {
    Some(v) => assert_eq(v, b"warn")
    None => panic()
  }
  match prio_level(b"6") {
    Some(v) => assert_eq(v, b"info")
    None => panic()
  }
  match prio_level(b"7") {
    Some(v) => assert_eq(v, b"debug")
    None => panic()
  }
  assert_true(prio_level(b"8") is None)
  assert_true(prio_level(b"12") is None)
}

///|
test "observedTimeUnixNano is a ts fallback, event time wins" {
  let only = @core.schema_from_fields(
    @core.parse_kv_pairs(b"observedTimeUnixNano=1732531200000000000"),
    (0 : Int64),
  )
  match only.ts {
    Some(t) => assert_eq(t, (1732531200000 : Int64))
    None => panic()
  }
  let both = @core.schema_from_fields(
    @core.parse_kv_pairs(
      b"timeUnixNano=1732531200000000000 observedTimeUnixNano=1732531300000000000",
    ),
    (0 : Int64),
  )
  match both.ts {
    Some(t) => assert_eq(t, (1732531200000 : Int64))
    None => panic()
  }
}

///|
test "non-container prefixes do not peel" {
  assert_eq(@core.canonical_field(b"user.message"), -1)
  assert_eq(@core.canonical_field(b"myapp.servicename"), -1)
  assert_eq(@core.canonical_field(b"pod.name"), -1)
  let f = @core.schema_from_fields(
    @core.parse_kv_pairs(b"user.message=hello myapp.servicename=svc"),
    (0 : Int64),
  )
  assert_true(f.message is None)
  assert_true(f.service is None)
}

///|
test "canonical slots for container-prefixed aliases" {
  assert_eq(@core.canonical_field(b"resource.service.name"), 2)
  assert_eq(@core.canonical_field(b"resource.host.name"), 3)
  assert_eq(@core.canonical_field(b"error.message"), 5)
  assert_eq(@core.canonical_field(b"error.trace.id"), 4)
  assert_eq(@core.canonical_field(b"log.level"), 1)
  assert_eq(@core.canonical_field(b"kubernetes.labels.app"), 2)
  assert_eq(@core.canonical_field(b"body.stringValue"), 5)
  assert_eq(@core.canonical_field(b"timeUnixNano"), 0)
  assert_eq(@core.canonical_field(b"__REALTIME_TIMESTAMP"), 0)
  assert_eq(@core.canonical_field(b"SYSLOG_IDENTIFIER"), 2)
  // syslog PRIORITY deliberately stays outside the slot map: its 0-7 scale
  // collides with the OTel 1-24 rank used by TTL rules.
  assert_eq(@core.canonical_field(b"priority"), -1)
}

///|
test "cross-service joint filter hits OTel shapes" {
  let raw = b"{\"timeUnixNano\":\"1732531200000000000\",\"severityText\":\"ERROR\",\"body\":{\"stringValue\":\"db connection timeout\"},\"resource\":{\"service\":{\"name\":\"checkout\"},\"host\":{\"name\":\"pod-7x\"}},\"traceId\":\"abc123\"}"
  let fields = @core.json_object_fields(raw)
  assert_true(
    @core.schema_matches(
      fields,
      b"log",
      raw,
      Some(b"error"),
      Some(b"checkout"),
      Some(b"pod-7x"),
      Some(b"ABC123"),
      Some(b"timeout"),
    ),
  )
  assert_true(
    !@core.schema_matches(
      fields,
      b"log",
      raw,
      Some(b"error"),
      Some(b"checkout"),
      Some(b"other-host"),
      None,
      None,
    ),
  )
}
