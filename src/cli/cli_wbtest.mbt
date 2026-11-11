// Internal tests for the 6.4 third-pass selfmon window primitives:
// the `{"ts":` fast extraction and the backward window-boundary locator.
// Both only skip rows; a foreign or hand-edited row must degrade to the
// conservative full scan, never to a wrong count.

///|
test "selfmon_line_ts extracts machine rows and rejects foreign ones (6.4)" {
  // Machine rows (audit_log / selfmon_report_error layout): no spaces.
  assert_eq(
    selfmon_line_ts(b"{\"ts\":1794429443160,\"actor\":\"local\"}"),
    1794429443160L,
  )
  assert_eq(selfmon_line_ts(b"{\"ts\":7,\"cmd\":\"query\"}"), 7L)
  // A hand-edited row with a space after the colon is not machine format.
  assert_eq(selfmon_line_ts(b"{\"ts\": 1794429443160,\"a\":1}"), -1L)
  // Not a ts-led object at all.
  assert_eq(selfmon_line_ts(b"{\"cmd\":\"query\",\"ts\":5}"), -1L)
  assert_eq(selfmon_line_ts(b"garbage"), -1L)
  // Short rows and a prefix without digits.
  assert_eq(selfmon_line_ts(b"{\"ts\":"), -1L)
  assert_eq(selfmon_line_ts(b"{\"ts\":x}"), -1L)
  assert_eq(selfmon_line_ts(b""), -1L)
}

///|
test "selfmon_window_boundary locates the in-window tail (6.4)" {
  // Append-order rows (old -> new) like the real AUDIT trail.
  let row = fn(ts : Int64) -> Bytes {
    @utf8.encode(
      "{\"ts\":" +
      ts.to_string() +
      ",\"actor\":\"local\",\"action\":\"query\",\"decision\":\"allow\",\"target\":\"x\",\"prev\":\"00000000\"}",
    )
  }
  // 10 old rows then 3 in-window rows: boundary is the first in-window row.
  let mut data : Bytes = b""
  for i in 0..<10 {
    data = data + row(1000L + i.to_int64()) + b"\n"
  }
  for i in 0..<3 {
    data = data + row(5000L + i.to_int64()) + b"\n"
  }
  let rowlen = row(1000L).length() + 1
  assert_eq(selfmon_window_boundary(data, 5000L), 10 * rowlen)
  // Whole file in window: the first row alone decides — boundary 0.
  assert_eq(selfmon_window_boundary(data, 0L), 0)
  assert_eq(selfmon_window_boundary(data, 1000L), 0)
  // Nothing in window: boundary points at the last (oldest) row; the
  // forward parse then filters it out by ts.
  assert_eq(selfmon_window_boundary(data, 999999L), 13 * rowlen)
  // Empty and newline-only inputs scan nothing.
  assert_eq(selfmon_window_boundary(b"", 0L), 0)
  assert_eq(selfmon_window_boundary(b"\n\n\n", 0L), 0)
  // A foreign row at the tail (no {"ts": prefix) degrades to a full scan.
  let foreign = data + b"not-json-at-all\n"
  assert_eq(selfmon_window_boundary(foreign, 5000L), 0)
  // A hand-edited first row (space after the colon) also degrades.
  let mut spaced : Bytes = b""
  for i in 0..<5 {
    spaced = spaced +
      @utf8.encode(
        "{\"ts\": " + (1000L + i.to_int64()).to_string() + ",\"a\":1}\n",
      )
  }
  assert_eq(selfmon_window_boundary(spaced, 1001L), 0)
}
