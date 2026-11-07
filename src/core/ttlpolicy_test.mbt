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
      assert_eq(@core.ttl_days_of(policy, b"orders", Some(b"info")), 90L)
      // Both dimensions hit → the stricter one wins.
      assert_eq(@core.ttl_days_of(policy, b"orders", Some(b"error")), 90L)
      assert_eq(@core.ttl_days_of(policy, b"payments", Some(b"debug")), 3L)
      // No rule hit → default.
      assert_eq(@core.ttl_days_of(policy, b"payments", Some(b"info")), 30L)
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
        @core.ttl_days_of(policy, b"tenant-a/orders", Some(b"info")),
        7L,
      )
      assert_eq(@core.ttl_days_of(policy, b"tenant-a/", None), 7L)
      // Keys outside every prefix fall back to the default.
      assert_eq(@core.ttl_days_of(policy, b"tenant-c/x", None), 30L)
      // Several hits → the stricter one wins.
      let both = @core.parse_ttl_policy(b"prefix t/ 90\nservice t/a 10\n")
      match both {
        Some(policy2) =>
          assert_eq(@core.ttl_days_of(policy2, b"t/a", None), 10L)
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
      assert_eq(@core.ttl_days_of(policy, b"hot", None), 2L)
      assert_eq(@core.ttl_days_of(policy, b"cold", None), -1L)
    }
    None => panic()
  }
  // days=0 means "expired immediately".
  let z = @core.parse_ttl_policy(b"level debug 0\n")
  match z {
    Some(policy) =>
      assert_eq(@core.ttl_days_of(policy, b"k", Some(b"debug")), 0L)
    None => panic()
  }
}
