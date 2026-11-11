///|
test "parse_quota_line reads all fields and defaults" {
  match
    @core.parse_quota_line(
      b"role=tenant-a write-bytes=1000 storage-bytes=2000 query-concurrent=2 retain-days=7",
    ) {
    Some(r) => {
      assert_eq(r.role, b"tenant-a")
      assert_eq(r.write_bytes, 1000L)
      assert_eq(r.storage_bytes, 2000L)
      assert_eq(r.query_concurrent, 2)
      assert_eq(r.retain_days, 7L)
    }
    None => panic()
  }
  // Omitted fields keep their "unlimited"/"off" defaults.
  match @core.parse_quota_line(b"role=tenant-b") {
    Some(r) => {
      assert_eq(r.role, b"tenant-b")
      assert_eq(r.write_bytes, -1L)
      assert_eq(r.storage_bytes, -1L)
      assert_eq(r.query_concurrent, 0)
      assert_eq(r.retain_days, -1L)
    }
    None => panic()
  }
}

///|
test "parse_quota_line rejects malformed input" {
  match @core.parse_quota_line(b"write-bytes=100") {
    Some(_) => panic()
    None => ()
  }
  match @core.parse_quota_line(b"role= write-bytes=100") {
    Some(_) => panic()
    None => ()
  }
  match @core.parse_quota_line(b"role=x write-bytes=abc") {
    Some(_) => panic()
    None => ()
  }
  match @core.parse_quota_line(b"role=x storage-bytes=-") {
    Some(_) => panic()
    None => ()
  }
  match @core.parse_quota_line(b"role=x query-concurrent=1.5") {
    Some(_) => panic()
    None => ()
  }
  // Negative limits are accepted and mean "unlimited".
  match @core.parse_quota_line(b"role=x write-bytes=-5") {
    Some(r) => assert_eq(r.write_bytes, -5L)
    None => panic()
  }
}

///|
test "quota_for_role prefers the exact role then default" {
  let rules : Array[@core.QuotaRule] = [
    {
      role: b"default",
      write_bytes: 10L,
      storage_bytes: -1L,
      query_concurrent: 1,
      retain_days: -1L,
    },
    {
      role: b"tenant-a",
      write_bytes: 20L,
      storage_bytes: 30L,
      query_concurrent: 2,
      retain_days: 5L,
    },
  ]
  match @core.quota_for_role(rules, b"tenant-a") {
    Some(r) => assert_eq(r.write_bytes, 20L)
    None => panic()
  }
  // An identified role with no line of its own is unlimited — the anonymous
  // `default` line must not throttle an operator's admin/other role.
  match @core.quota_for_role(rules, b"tenant-z") {
    Some(_) => panic()
    None => ()
  }
  // Anonymous callers (no RBAC / unmatched token) fall back to `default`.
  match @core.quota_for_role(rules, b"") {
    Some(r) => assert_eq(r.write_bytes, 10L)
    None => panic()
  }
  // No match and no default line: no quota at all.
  let named_only : Array[@core.QuotaRule] = [
    {
      role: b"tenant-a",
      write_bytes: 20L,
      storage_bytes: 30L,
      query_concurrent: 2,
      retain_days: 5L,
    },
  ]
  match @core.quota_for_role(named_only, b"other") {
    Some(_) => panic()
    None => ()
  }
}

///|
test "write window resets on age-out and gates by bytes" {
  let u : @core.QuotaUsage = { window_start: 1000, used: 800, }
  // Still inside the window (window spans [start, start+3600000)).
  let cur = @core.quota_window_current(u, 3_600_999L)
  assert_eq(cur.used, 800L)
  assert_eq(cur.window_start, 1000L)
  // Aged out (window_start + 3600000 <= now): the budget refills.
  let fresh = @core.quota_window_current(u, 3_601_000L)
  assert_eq(fresh.used, 0L)
  assert_eq(fresh.window_start, 3_601_000L)
  assert_true(@core.quota_write_allows(cur, 1000L, 200L))
  assert_false(@core.quota_write_allows(cur, 1000L, 201L))
  // A negative limit means unlimited.
  assert_true(@core.quota_write_allows(cur, -1L, 100_000L))
}

///|
test "quota usage encode/parse roundtrip" {
  let u : @core.QuotaUsage = { window_start: 1700000000000L, used: 123456L, }
  match @core.parse_quota_usage(@core.encode_quota_usage(u)) {
    Some(u2) => {
      assert_eq(u2.window_start, 1700000000000L)
      assert_eq(u2.used, 123456L)
    }
    None => panic()
  }
  match @core.parse_quota_usage(b"garbage") {
    Some(_) => panic()
    None => ()
  }
  match @core.parse_quota_usage(b"window_start=1") {
    Some(_) => panic()
    None => ()
  }
}

///|
test "retain-days overrides become prefix rules for scoped roles only" {
  let rules : Array[@core.QuotaRule] = [
    {
      role: b"tenant-a",
      write_bytes: -1L,
      storage_bytes: -1L,
      query_concurrent: 0,
      retain_days: 7L,
    },
    {
      role: b"tenant-b",
      write_bytes: -1L,
      storage_bytes: -1L,
      query_concurrent: 0,
      retain_days: -1L,
    },
    {
      role: b"tenant-c",
      write_bytes: -1L,
      storage_bytes: -1L,
      query_concurrent: 0,
      retain_days: 30L,
    },
  ]
  let scopes : Array[(Bytes, Bytes)] = [
    (b"tenant-a", b"tenant-a/"),
    (b"tenant-b", b"tenant-b/"),
  ]
  let out = @core.quota_retain_prefix_rules(rules, scopes)
  // tenant-a has days and a scope; tenant-b has a scope but no override;
  // tenant-c has days but no scope (unscoped roles cannot own a prefix).
  assert_eq(out.length(), 1)
  assert_eq(out[0].0, b"prefix")
  assert_eq(out[0].1, b"tenant-a/")
  assert_eq(out[0].2, 7L)
}
