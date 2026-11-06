///|
test "normalize_ts scales numeric precision to milliseconds" {
  assert_eq(@core.normalize_ts(b"1762400000", (7 : Int64)), 1762400000000L)
  assert_eq(@core.normalize_ts(b"1762400000000", (7 : Int64)), 1762400000000L)
  assert_eq(
    @core.normalize_ts(b"1762400000000000", (7 : Int64)),
    1762400000000L,
  )
  assert_eq(
    @core.normalize_ts(b"1762400000000000000", (7 : Int64)),
    1762400000000L,
  )
  assert_eq(@core.normalize_ts(b"-100", (7 : Int64)), -100000L)
  assert_eq(@core.normalize_ts(b"", (7 : Int64)), (7 : Int64))
  assert_eq(@core.normalize_ts(b"abc", (7 : Int64)), (7 : Int64))
  assert_eq(@core.normalize_ts(b"-", (7 : Int64)), (7 : Int64))
}

///|
test "parse_iso8601_ms anchors and zone offsets" {
  assert_eq(@core.parse_iso8601_ms(b"1970-01-01T00:00:00Z", (7 : Int64)), 0L)
  assert_eq(
    @core.parse_iso8601_ms(b"1970-01-02T00:00:00Z", (7 : Int64)),
    86400000L,
  )
  let z = 1793966400000L
  // Same event across timezones normalizes to one epoch value.
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06T12:00:00Z", (7 : Int64)), z)
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06T20:00:00+08:00", (7 : Int64)),
    z,
  )
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06T20:00:00+0800", (7 : Int64)), z)
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06T07:00:00-05:00", (7 : Int64)),
    z,
  )
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06T07:00:00-0500", (7 : Int64)), z)
  // Lowercase z and a space separator are accepted; no suffix means UTC.
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06T12:00:00z", (7 : Int64)), z)
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06 12:00:00", (7 : Int64)), z)
  // Fractional seconds truncate to milliseconds.
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06T12:00:00.5Z", (7 : Int64)),
    z + 500L,
  )
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06T12:00:00.123456Z", (7 : Int64)),
    z + 123L,
  )
  // Invalid shapes fall back.
  assert_eq(
    @core.parse_iso8601_ms(b"2026-13-06T12:00:00Z", (7 : Int64)),
    (7 : Int64),
  )
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06", (7 : Int64)), (7 : Int64))
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06T12:00:00X", (7 : Int64)),
    (7 : Int64),
  )
  assert_eq(
    @core.parse_iso8601_ms(b"2026/11/06T12:00:00Z", (7 : Int64)),
    (7 : Int64),
  )
}

///|
test "normalize_ts routes ISO-8601 with any zone" {
  assert_eq(
    @core.normalize_ts(b"2026-11-06T20:00:00+08:00", (7 : Int64)),
    1793966400000L,
  )
  assert_eq(
    @core.normalize_ts(b"2026-11-06T12:00:00.250Z", (7 : Int64)),
    1793966400250L,
  )
  assert_eq(@core.normalize_ts(b"12/06/2026", (7 : Int64)), (7 : Int64))
}
