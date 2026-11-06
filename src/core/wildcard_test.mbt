///|
test "wildcard substring semantics (4.1)" {
  // '*' spans arbitrary content.
  assert_true(@core.wildcard_contains(b"msg=error_code here", b"error*", false))
  assert_true(@core.wildcard_contains(b"GET /api/users", b"/api/*", false))
  assert_true(@core.wildcard_contains(b"a=b c=d e=f", b"a=* e=*", false))
  // '?' consumes exactly one byte: "err?r" needs exactly one byte between
  // "err" and "r" (the wrapping '*' only extends the ends).
  assert_true(@core.wildcard_contains(b"level=errX", b"err?", false))
  assert_true(@core.wildcard_contains(b"level=error", b"err?r", false))
  assert_true(!@core.wildcard_contains(b"level=error", b"err??r", false))
  // Case folding only under ignore_case.
  assert_true(@core.wildcard_contains(b"connection TIMEOUT", b"*timeout", true))
  assert_true(
    !@core.wildcard_contains(b"connection TIMEOUT", b"*timeout", false),
  )
  // No wildcards behaves like the plain substring search.
  assert_true(@core.wildcard_contains(b"timeout=30", b"time", false))
  assert_true(!@core.wildcard_contains(b"timeout=30", b"times", false))
  // Mixed '*' and '?' with backtracking across matches.
  assert_true(
    @core.wildcard_contains(b"user=abc id=123 done", b"user=* id=1??", false),
  )
}

///|
test "wildcard works byte-wise for Chinese patterns (4.1)" {
  let hit = @utf8.encode("数据库连接失败")
  assert_true(@core.wildcard_contains(hit, @utf8.encode("数据库"), false))
  assert_true(@core.wildcard_contains(hit, @utf8.encode("连接失败"), false))
  assert_true(
    @core.wildcard_contains(hit, @utf8.encode("数据*失败"), false),
  )
  // '?' is byte-level: one Chinese character is 3 UTF-8 bytes.
  assert_true(@core.wildcard_contains(hit, @utf8.encode("连接???败"), false))
  assert_true(!@core.wildcard_contains(hit, @utf8.encode("数据被"), false))
}
