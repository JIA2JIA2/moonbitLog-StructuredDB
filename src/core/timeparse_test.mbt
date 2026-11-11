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
  // A bare date parses as midnight UTC (2.3 third round) — the day is a
  // complete value, far closer to the event than the ingest time.
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06", (7 : Int64)), z - 43200000L)
  assert_eq(@core.parse_iso8601_ms(b"2026/11/06", (7 : Int64)), z - 43200000L)
  // Non-date shapes of the same length still fall back.
  assert_eq(@core.parse_iso8601_ms(b"12/06/2026", (7 : Int64)), (7 : Int64))
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06T12:00:00X", (7 : Int64)),
    (7 : Int64),
  )
  // Slash-separated dates are a common log shape (M150).
  assert_eq(@core.parse_iso8601_ms(b"2026/11/06T12:00:00Z", (7 : Int64)), z)
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

///|
test "parse_iso8601_ms accepts comma fractions, UTC/GMT and minutes-only" {
  let z = 1793966400000L
  // Java/log4j comma milliseconds.
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06 12:00:00,123", (7 : Int64)),
    z + 123L,
  )
  // UTC / GMT suffix (case-insensitive, separated by a space).
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06 12:00:00 UTC", (7 : Int64)), z)
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06 12:00:00 gmt", (7 : Int64)), z)
  // Seconds are optional.
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06 12:00", (7 : Int64)), z)
  // Hour-only zone offset.
  assert_eq(@core.parse_iso8601_ms(b"2026-11-06T20:00:00+08", (7 : Int64)), z)
  // Two-digit fraction is 120 ms, not 12 ms.
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06T12:00:00.12Z", (7 : Int64)),
    z + 120L,
  )
  // Unknown zone tags still fail.
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06 12:00:00 XYZ", (7 : Int64)),
    (7 : Int64),
  )
}

///|
test "space-separated numeric zone offsets parse (2.3 third round)" {
  let z = 1793966400000L
  // `±HH:MM` after a space — the syslog-style `date time +08:00` shape.
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06 20:00:00 +08:00", (7 : Int64)),
    z,
  )
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06 07:00:00 -05:00", (7 : Int64)),
    z,
  )
  // `±HHMM` without the colon.
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06 20:00:00 +0800", (7 : Int64)),
    z,
  )
  // Fractional seconds survive the space-separated offset (12:00 +08:00 is
  // 04:00 UTC).
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06 12:00:00.123 +08:00", (7 : Int64)),
    z - 28799877L,
  )
  // Unknown zone tags after a space still fail.
  assert_eq(
    @core.parse_iso8601_ms(b"2026-11-06 12:00:00 XYZ", (7 : Int64)),
    (7 : Int64),
  )
}

///|
test "rfc2822 dates parse across zones (mail/HTTP Date shape)" {
  // 2026-11-06T12:00:00Z == Fri, 06 Nov 2026 12:00:00 +0000.
  let z = 1793966400000L
  assert_eq(
    @core.parse_rfc2822_ms(b"Fri, 06 Nov 2026 12:00:00 +0000", (7 : Int64)),
    z,
  )
  assert_eq(
    @core.parse_rfc2822_ms(b"Fri, 06 Nov 2026 20:00:00 +0800", (7 : Int64)),
    z,
  )
  assert_eq(
    @core.parse_rfc2822_ms(b"Fri, 06 Nov 2026 07:00:00 -0500", (7 : Int64)),
    z,
  )
  // No weekday, no seconds, GMT tag — all accepted.
  assert_eq(@core.parse_rfc2822_ms(b"06 Nov 2026 12:00 GMT", (7 : Int64)), z)
  assert_eq(@core.parse_rfc2822_ms(b"6 Nov 2026 12:00 UTC", (7 : Int64)), z)
  // Month names are case-insensitive.
  assert_eq(@core.parse_rfc2822_ms(b"06 NOV 2026 12:00 +0000", (7 : Int64)), z)
  // Unknown month and letter-less shapes fall back.
  assert_eq(
    @core.parse_rfc2822_ms(b"06 Foo 2026 12:00 +0000", (7 : Int64)),
    (7 : Int64),
  )
  assert_eq(@core.parse_rfc2822_ms(b"1794391200", (7 : Int64)), (7 : Int64))
  // normalize_ts routes letter-led values to RFC 2822.
  assert_eq(
    @core.normalize_ts(b"Fri, 06 Nov 2026 20:00:00 +0800", (7 : Int64)),
    z,
  )
}

///|
test "epoch seconds with a fractional part keep milliseconds" {
  // Python time.time() / JS Date.now()/1000 shape.
  assert_eq(@core.normalize_ts(b"1794391200.512", (7 : Int64)), 1794391200512L)
  // 1-digit fraction right-pads (500 ms), 6 digits truncate.
  assert_eq(@core.normalize_ts(b"1794391200.5", (7 : Int64)), 1794391200500L)
  assert_eq(
    @core.normalize_ts(b"1794391200.512345", (7 : Int64)),
    1794391200512L,
  )
  // Two digits = 120 ms, not 12 ms.
  assert_eq(@core.normalize_ts(b"1794391200.12", (7 : Int64)), 1794391200120L)
  // Millisecond-scale integers with a fraction are not a seconds shape.
  assert_eq(@core.normalize_ts(b"1794391200512.0", (7 : Int64)), (7 : Int64))
  // Two dots and letter tails still fall back.
  assert_eq(@core.normalize_ts(b"1794391200.51.2", (7 : Int64)), (7 : Int64))
  assert_eq(@core.normalize_ts(b"1794391200.512abc", (7 : Int64)), (7 : Int64))
}
