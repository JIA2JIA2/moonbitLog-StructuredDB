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
test "format_utc renders minute hour and day precision" {
  assert_eq(@core.format_utc((0 : Int64), "hour"), "1970-01-01 00:00")
  assert_eq(@core.format_utc((86400000 : Int64), "day"), "1970-01-02")
  assert_eq(
    @core.format_utc((1793836800000 : Int64), "minute"),
    "2026-11-05 00:00",
  )
  assert_eq(@core.format_utc((1793836800000 : Int64), "day"), "2026-11-05")
}
