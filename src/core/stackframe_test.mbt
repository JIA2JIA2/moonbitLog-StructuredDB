///|
test "is_stack_frame recognizes java python and chain lines (5.2)" {
  // Java frames
  assert_true(@core.is_stack_frame(b"at com.app.Db.lookup(Db.java:42)"))
  assert_true(@core.is_stack_frame(b"  at com.app.Main.run(Main.java:10)"))
  // Python frame
  assert_true(@core.is_stack_frame(b"File \"/app/x.py\", line 42, in foo"))
  // Exception chain line continues the same stack cluster.
  assert_true(@core.is_stack_frame(b"Caused by: java.io.IOException: disk"))
  // Plain messages and headers are not frames.
  assert_true(!@core.is_stack_frame(b"java.lang.NullPointerException: boom"))
  assert_true(!@core.is_stack_frame(b"ERROR db down at 10:00"))
  // "at " without a parenthesized location is not a Java frame.
  assert_true(!@core.is_stack_frame(b"at the edge of the world"))
  // Empty / tiny values.
  assert_true(!@core.is_stack_frame(b""))
  assert_true(!@core.is_stack_frame(b"at "))
}
