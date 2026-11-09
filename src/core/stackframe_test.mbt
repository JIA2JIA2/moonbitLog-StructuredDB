///|
test "is_stack_frame recognizes java python and chain lines (5.2)" {
  // Java frames
  assert_true(@core.is_stack_frame(b"at com.app.Db.lookup(Db.java:42)"))
  assert_true(@core.is_stack_frame(b"  at com.app.Main.run(Main.java:10)"))
  // Python frame
  assert_true(@core.is_stack_frame(b"File \"/app/x.py\", line 42, in foo"))
  // Exception chain line continues the same stack cluster.
  assert_true(@core.is_stack_frame(b"Caused by: java.io.IOException: disk"))
  assert_true(@core.is_stack_frame(b"Suppressed: java.io.IOException: disk"))
  // Plain messages and headers are not frames.
  assert_true(!@core.is_stack_frame(b"java.lang.NullPointerException: boom"))
  assert_true(!@core.is_stack_frame(b"ERROR db down at 10:00"))
  // "at " without a parenthesized location is not a Java frame.
  assert_true(!@core.is_stack_frame(b"at the edge of the world"))
  // Empty / tiny values.
  assert_true(!@core.is_stack_frame(b""))
  assert_true(!@core.is_stack_frame(b"at "))
}

///|
test "is_stack_frame recognizes go rust net and jvm shapes (5.2)" {
  // Go runtime backtrace.
  assert_true(@core.is_stack_frame(b"goroutine 1 [running]:"))
  assert_true(@core.is_stack_frame(b"created by main.main"))
  assert_true(@core.is_stack_frame(b"main.handler(0xc0000140a0)"))
  assert_true(@core.is_stack_frame(b"\t/app/main.go:12 +0x1d"))
  // Rust backtrace.
  assert_true(@core.is_stack_frame(b"   0: std::panicking::begin_panic"))
  assert_true(@core.is_stack_frame(b"             at ./src/main.rs:12:5"))
  // .NET / Node frames.
  assert_true(
    @core.is_stack_frame(
      b"   at App.UserService.Get(Int32 id) in /src/UserService.cs:line 42",
    ),
  )
  assert_true(
    @core.is_stack_frame(b"   at Object.<anonymous> (/app/server.js:10:15)"),
  )
  // JVM omitted-frames tail.
  assert_true(@core.is_stack_frame(b"\t... 23 more"))
  // Non-frames that resemble the new shapes.
  assert_true(!@core.is_stack_frame(b"0: plain message"))
  assert_true(!@core.is_stack_frame(b"at 10:00"))
  assert_true(!@core.is_stack_frame(b"goroutine without brackets"))
}
