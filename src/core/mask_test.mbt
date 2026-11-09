///|
test "mask_sensitive hides mobile idcard and named secrets" {
  assert_eq(
    @core.mask_sensitive(b"phone=13812345678", []),
    b"phone=138****5678",
  )
  assert_eq(
    @core.mask_sensitive(b"user 13812345678 logged in", []),
    b"user 138****5678 logged in",
  )
  // Non-mobile 11-digit runs and 12-digit numbers stay intact.
  assert_eq(
    @core.mask_sensitive(b"ref=23456789011 x=138123456789", []),
    b"ref=23456789011 x=138123456789",
  )
  assert_eq(
    @core.mask_sensitive(b"idcard=11010119900307777X", []),
    b"idcard=110***********777X",
  )
  assert_eq(
    @core.mask_sensitive(b"idcard=110101900307777", []),
    b"idcard=110********7777",
  )
  assert_eq(
    @core.mask_sensitive(b"token=sk-live-abc123", []),
    b"token=[REDACTED]",
  )
  assert_eq(
    @core.mask_sensitive(b"API_KEY=abcd1234", []),
    b"API_KEY=[REDACTED]",
  )
  assert_eq(
    @core.mask_sensitive(b"password=hunter2 ok=1", []),
    b"password=[REDACTED] ok=1",
  )
}

///|
test "mask_sensitive hides bearer jwt and long hex" {
  assert_eq(
    @core.mask_sensitive(b"Authorization=Bearer eyJhbGciOiJ.eyJzdWIi.sig", []),
    b"Authorization=[REDACTED] [REDACTED]",
  )
  assert_eq(
    @core.mask_sensitive(b"Bearer sk-live-abcdef123 tail", []),
    b"Bearer [REDACTED] tail",
  )
  assert_eq(
    @core.mask_sensitive(b"jwt=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxw", []),
    b"jwt=[REDACTED]",
  )
  assert_eq(
    @core.mask_sensitive(
      b"sha=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      [],
    ),
    b"sha=[REDACTED]",
  )
  // Short hex, UUID segments and 19-digit epoch nanoseconds stay intact.
  assert_eq(
    @core.mask_sensitive(
      b"id=deadbeef req=550e8400-e29b-41d4-a716-446655440000",
      [],
    ),
    b"id=deadbeef req=550e8400-e29b-41d4-a716-446655440000",
  )
  assert_eq(
    @core.mask_sensitive(b"ns=1762400000123456789", []),
    b"ns=1762400000123456789",
  )
}

///|
test "mask_sensitive honors extra names and preserves other bytes" {
  assert_eq(
    @core.mask_sensitive(b"order_no=10086 ok=1", [b"order_no"]),
    b"order_no=[REDACTED] ok=1",
  )
  assert_eq(
    @core.mask_sensitive(b"Order_No=10086", [b"order_no"]),
    b"Order_No=[REDACTED]",
  )
  // Empty value segment stays as-is; unrelated text is verbatim.
  assert_eq(
    @core.mask_sensitive(b"token= level=error msg=ok 123", []),
    b"token= level=error msg=ok 123",
  )
  assert_eq(@core.mask_sensitive(b"plain text", []), b"plain text")
  assert_eq(@core.mask_sensitive(b"", []), b"")
}

///|
test "mask_sensitive handles JSON fields and provider secret prefixes" {
  assert_eq(
    @core.mask_sensitive(
      b"{\"token\":\"sk-abcdefghijklmnop\",\"password\":\"p@ss\"}",
      [],
    ),
    b"{\"token\":\"[REDACTED]\",\"password\":\"[REDACTED]\"}",
  )
  assert_eq(
    @core.mask_sensitive(b"{\"token\": \"abc def\"}", []),
    b"{\"token\": \"[REDACTED]\"}",
  )
  assert_eq(
    @core.mask_sensitive(b"note=sk-abcdefghijklmnop", []),
    b"note=[REDACTED]",
  )
  assert_eq(
    @core.mask_sensitive(b"key=AKIAABCDEFGHIJKLMNOP", []),
    b"key=[REDACTED]",
  )
  assert_eq(
    @core.mask_sensitive(b"gh=ghp_abcdefghijklmnopqrstuvwx", []),
    b"gh=[REDACTED]",
  )
  // Ordinary hyphenated identifiers are untouched.
  assert_eq(
    @core.mask_sensitive(b"task=disk-usage-report-2026", []),
    b"task=disk-usage-report-2026",
  )
}
