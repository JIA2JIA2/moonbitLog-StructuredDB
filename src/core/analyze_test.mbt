///|
test "normalize_log_template collapses numbers hex and quoted spans" {
  assert_eq(
    @core.normalize_log_template(b"user 123 login from 10.0.0.7"),
    b"user <num> login from <num>.<num>.<num>.<num>",
  )
  assert_eq(@core.normalize_log_template(b"req 0x1F done"), b"req <hex> done")
  assert_eq(
    @core.normalize_log_template(b"msg \"hello world\" x"),
    b"msg <str> x",
  )
  assert_eq(@core.normalize_log_template(b"plain text"), b"plain text")
}

///|
test "normalize_log_template folds key=value bare values and single quotes" {
  // Bare-word values of key=value tokens are variable content: the same
  // error shape with different hosts/services must merge into one template.
  assert_eq(
    @core.normalize_log_template(
      b"level=error service=orders host=alpha err=connection",
    ),
    b"level=error service=<v> host=<v> err=<v>",
  )
  assert_eq(
    @core.normalize_log_template(
      b"level=error service=billing host=beta err=timeout",
    ),
    b"level=error service=<v> host=<v> err=<v>",
  )
  // Enum words keep their value so levels stay distinguishable.
  assert_eq(
    @core.normalize_log_template(b"level=warn ok=true"),
    b"level=warn ok=true",
  )
  // Single-quoted spans collapse like double-quoted ones.
  assert_eq(
    @core.normalize_log_template(b"no such column: 'email' in q 42"),
    b"no such column: <str> in q <num>",
  )
  assert_eq(
    @core.normalize_log_template(b"no such column: 'name' in q 43"),
    b"no such column: <str> in q <num>",
  )
  // Non-enum numeric value folds; bare value token without = stays literal.
  assert_eq(
    @core.normalize_log_template(b"status=500 upstream=api-v2"),
    b"status=<v> upstream=<v>",
  )
  assert_eq(@core.normalize_log_template(b"a= b == plain"), b"a= b == plain")
}

///|
test "format_utc renders minute hour and day precision" {
  assert_eq(@core.format_utc((0 : Int64), "hour"), "1970-01-01 00:00")
  assert_eq(@core.format_utc((86400000 : Int64), "day"), "1970-01-02")
  assert_eq(
    @core.format_utc((1793836800000 : Int64), "minute"),
    "2026-11-05 00:00",
  )
  assert_eq(@core.format_utc((1793836800000 : Int64), "day"), "2026-11-05")
}
