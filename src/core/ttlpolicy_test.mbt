///|
test "parse ttl policy with default service and level rules" {
  let p = @core.parse_ttl_policy(
    b"# retention policy\ndefault 30\nservice orders 90\n\nlevel error 180\nlevel debug 3\n",
  )
  match p {
    Some(policy) => {
      assert_eq(policy.default_days, (30 : Int64))
      // default is a separate field; only service/level lines are rules.
      assert_eq(policy.rules.length(), 3)
      // Service hit only → the service rule wins (default does not cap it).
      assert_eq(@core.ttl_days_of(policy, b"orders", Some(b"info"), None), 90L)
      // Both dimensions hit → the stricter one wins.
      assert_eq(@core.ttl_days_of(policy, b"orders", Some(b"error"), None), 90L)
      assert_eq(
        @core.ttl_days_of(policy, b"payments", Some(b"debug"), None),
        3L,
      )
      // No rule hit → default.
      assert_eq(
        @core.ttl_days_of(policy, b"payments", Some(b"info"), None),
        30L,
      )
      // Level extraction from a schema-shaped value.
      assert_eq(
        @core.ttl_record_level(b"level=error host=h1 message=boom"),
        Some(b"error"),
      )
      assert_true(@core.ttl_record_level(b"plain text") is None)
    }
    None => panic()
  }
}

///|
test "prefix rules match tenant key namespaces (6.2)" {
  let p = @core.parse_ttl_policy(
    b"default 30\nprefix tenant-a/ 7\nprefix tenant-b/ 365\n",
  )
  match p {
    Some(policy) => {
      assert_eq(policy.rules.length(), 2)
      // Keys under the tenant prefix hit the prefix rule.
      assert_eq(
        @core.ttl_days_of(policy, b"tenant-a/orders", Some(b"info"), None),
        7L,
      )
      assert_eq(@core.ttl_days_of(policy, b"tenant-a/", None, None), 7L)
      // Keys outside every prefix fall back to the default.
      assert_eq(@core.ttl_days_of(policy, b"tenant-c/x", None, None), 30L)
      // Several hits → the stricter one wins.
      let both = @core.parse_ttl_policy(b"prefix t/ 90\nservice t/a 10\n")
      match both {
        Some(policy2) =>
          assert_eq(@core.ttl_days_of(policy2, b"t/a", None, None), 10L)
        None => panic()
      }
    }
    None => panic()
  }
  // Malformed prefix lines reject the whole file, like every other scope.
  assert_true(@core.parse_ttl_policy(b"prefix tenant-a/\n") is None)
  assert_true(@core.parse_ttl_policy(b"prefix tenant-a/ abc\n") is None)
}

///|
test "ttl policy rejects malformed lines and supports default-less files" {
  // A malformed line rejects the whole file (no silent partial policy).
  assert_true(@core.parse_ttl_policy(b"default 30\nservice bad\n") is None)
  assert_true(@core.parse_ttl_policy(b"default abc\n") is None)
  assert_true(@core.parse_ttl_policy(b"bogus 1\n") is None)
  assert_true(@core.parse_ttl_policy(b"service orders\n") is None)
  // Negative days are invalid everywhere.
  assert_true(@core.parse_ttl_policy(b"default -1\n") is None)
  // Default-less file: only rule hits expire, everything else never does.
  let p = @core.parse_ttl_policy(b"service hot 2\n")
  match p {
    Some(policy) => {
      assert_eq(policy.default_days, -1L)
      assert_eq(@core.ttl_days_of(policy, b"hot", None, None), 2L)
      assert_eq(@core.ttl_days_of(policy, b"cold", None, None), -1L)
    }
    None => panic()
  }
  // days=0 means "expired immediately".
  let z = @core.parse_ttl_policy(b"level debug 0\n")
  match z {
    Some(policy) =>
      assert_eq(@core.ttl_days_of(policy, b"k", Some(b"debug"), None), 0L)
    None => panic()
  }
}

///|
test "ttl scope matching is case-insensitive for service and level" {
  let p = @core.parse_ttl_policy(
    b"service Orders 1\nlevel ERROR 2\nprefix t/ 3\n",
  )
  match p {
    Some(policy) => {
      // Service scope: record key `orders` still hits the `Orders` rule.
      assert_eq(@core.ttl_days_of(policy, b"orders", None, None), 1L)
      // Level scope: record level `error`/`Error` hits the `ERROR` rule.
      assert_eq(@core.ttl_days_of(policy, b"k", Some(b"error"), None), 2L)
      assert_eq(@core.ttl_days_of(policy, b"k", Some(b"Error"), None), 2L)
      // Prefix scope stays byte-exact (tenant namespaces).
      assert_eq(@core.ttl_days_of(policy, b"t/a", None, None), 3L)
      assert_eq(@core.ttl_days_of(policy, b"T/a", None, None), -1L)
    }
    None => panic()
  }
  // `Level=` field names are case-insensitive too.
  assert_eq(@core.ttl_record_level(b"Level=error msg=x"), Some(b"error"))
}

///|
test "ttl_record_level covers JSON records and level aliases (3.4)" {
  // SDK-style JSON records: before flattening, `severity_text` was invisible
  // and per-level retention silently missed them.
  assert_eq(
    @core.ttl_record_level(
      b"{\"severity_text\":\"ERROR\",\"service\":\"orders\",\"message\":\"boom\"}",
    ),
    Some(b"ERROR"),
  )
  // KV alias fields resolve through the unified schema (2.2).
  assert_eq(@core.ttl_record_level(b"severity=warn svc=o"), Some(b"warn"))
  assert_eq(@core.ttl_record_level(b"lvl=fatal k=v"), Some(b"fatal"))
  // Plain values without any level slot stay None.
  assert_true(@core.ttl_record_level(b"{\"msg\":\"no level here\"}") is None)
  assert_true(@core.ttl_record_level(b"msg=plain") is None)
}

///|
test "service scope also matches the record's service field (3.4 fourth round)" {
  // With an explicit --key-field (M229) the key is the caller's own id and
  // the service name lives in the value — key-only matching silently fell
  // back to the default for exactly those records.
  let p = @core.parse_ttl_policy(b"default 30\nservice payments 1\n")
  match p {
    Some(policy) => {
      // The value's service field hits the rule even with a foreign key.
      assert_eq(
        @core.ttl_days_of(policy, b"id-1", Some(b"info"), Some(b"payments")),
        1L,
      )
      // Case-insensitive in the value too.
      assert_eq(@core.ttl_days_of(policy, b"id-2", None, Some(b"Payments")), 1L)
      // The historical key shape keeps working.
      assert_eq(@core.ttl_days_of(policy, b"payments", None, None), 1L)
      // Both shapes hitting the same rule stay one rule.
      assert_eq(
        @core.ttl_days_of(policy, b"payments", None, Some(b"PAYMENTS")),
        1L,
      )
      // A different service keeps the default.
      assert_eq(@core.ttl_days_of(policy, b"id-3", None, Some(b"other")), 30L)
      // No service anywhere and no key hit → default.
      assert_eq(@core.ttl_days_of(policy, b"id-4", None, None), 30L)
    }
    None => panic()
  }
}

///|
test "ttl fields cover container-wrapped records and the service slot (3.4)" {
  // CRI/container-wrapped records (the Docker/K8s shape): the pre-round copy
  // only flattened a leading `{`, so wrapped records missed the level rule.
  assert_eq(
    @core.ttl_record_level(
      b"2026-11-25T10:00:00.123456789Z stdout F {\"level\":\"ERROR\",\"msg\":\"x\"}",
    ),
    Some(b"ERROR"),
  )
  // Trailing meta pairs merged into the field set (2.4 policy enrichment).
  assert_eq(@core.ttl_record_level(b"level=info env=prod"), Some(b"info"))
  // The service slot resolves through the same shared contract.
  assert_eq(
    @core.ttl_record_service(b"{\"service\":\"orders\",\"level\":\"warn\"}"),
    Some(b"orders"),
  )
  assert_eq(@core.ttl_record_service(b"svc=payments k=v"), Some(b"payments"))
  assert_eq(
    @core.ttl_record_service(
      b"2026-11-25T10:00:00Z stdout F {\"app\":\"checkout\"}",
    ),
    Some(b"checkout"),
  )
  assert_true(@core.ttl_record_service(b"plain text") is None)
}
