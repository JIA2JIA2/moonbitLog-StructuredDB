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

///|
test "drill audit and batches reconciliation (6.5)" {
  let bak = "/tmp/moonlog-wbtest-drill-bak"
  let rst = "/tmp/moonlog-wbtest-drill-rst"
  remove_tree(bak)
  remove_tree(rst)
  ignore(@backend_native.ensure_dir(bak))
  ignore(@backend_native.ensure_dir(rst))
  // No audit trail and no batch ledger on either side: absent.
  assert_eq(drill_audit_check(bak, rst), "absent")
  assert_eq(drill_batches_check(bak, rst), "absent")
  assert_eq(drill_audit_stats(bak), (0, 0L))
  // Identical audit set (live AUDIT + one rotation) on both sides: ok.
  let row1 = b"{\"ts\":1,\"actor\":\"local\",\"action\":\"query\"}\n"
  let row2 = b"{\"ts\":0,\"actor\":\"local\",\"action\":\"stats\"}\n"
  @backend_native.write_file(bak + "/AUDIT", row1) catch {
    _ => ()
  }
  @backend_native.write_file(bak + "/AUDIT.1", row2) catch {
    _ => ()
  }
  @backend_native.write_file(rst + "/AUDIT", row1) catch {
    _ => ()
  }
  @backend_native.write_file(rst + "/AUDIT.1", row2) catch {
    _ => ()
  }
  assert_eq(drill_audit_check(bak, rst), "ok")
  assert_eq(
    drill_audit_stats(bak),
    (2, (row1.length() + row2.length()).to_int64()),
  )
  // A rotation only the backup carries: mismatch (the history was lossy).
  @backend_native.write_file(bak + "/AUDIT.2", b"{\"ts\":2}\n") catch {
    _ => ()
  }
  assert_eq(drill_audit_check(bak, rst), "mismatch")
  // A rewritten live trail: mismatch (byte-for-byte reconciliation).
  @backend_native.write_file(rst + "/AUDIT", b"{\"ts\":9}\n") catch {
    _ => ()
  }
  assert_eq(drill_audit_check(bak, rst), "mismatch")
  // Batch ledger: identical on both sides is ok, one-sided is a mismatch.
  @backend_native.write_file(bak + "/BATCHES", b"batch-77\n") catch {
    _ => ()
  }
  @backend_native.write_file(rst + "/BATCHES", b"batch-77\n") catch {
    _ => ()
  }
  assert_eq(drill_batches_check(bak, rst), "ok")
  ignore(@backend_native.remove_file(rst + "/BATCHES"))
  assert_eq(drill_batches_check(bak, rst), "mismatch")
  remove_tree(bak)
  remove_tree(rst)
}

///|
test "drill audit chain walk flags a rewritten trail (6.5)" {
  let dir = "/tmp/moonlog-wbtest-drill-chain"
  remove_tree(dir)
  // audit_log appends a linked trail: row N's prev is the CRC32 of row N-1.
  audit_log(dir, "local", "query", "allow", "t1")
  audit_log(dir, "local", "stats", "allow", "t2")
  audit_log(dir, "local", "backup", "allow", "t3")
  assert_eq(drill_audit_names(dir).length(), 1)
  assert_true(drill_audit_chain_ok(dir))
  // Rewriting the middle row keeps that row's own prev link valid but
  // breaks the link of the row after it — exactly the tampering shape the
  // chain exists to catch (row-level JSON checks stay green).
  let data = @backend_native.read_file(dir + "/AUDIT")
  let (rows, _) = split_complete_lines(data, true)
  assert_eq(rows.length(), 3)
  let mut tampered : Bytes = b""
  for i in 0..<rows.length() {
    tampered = tampered + rows[i] + (if i == 1 { b" " } else { b"" }) + b"\n"
  }
  @backend_native.write_file(dir + "/AUDIT", tampered) catch {
    _ => ()
  }
  assert_false(drill_audit_chain_ok(dir))
  remove_tree(dir)
}

///|
test "restore gates on manifest-declared segments (6.5)" {
  let src = "/tmp/moonlog-wbtest-restore-gate-src"
  let bak = "/tmp/moonlog-wbtest-restore-gate-bak"
  let rst = "/tmp/moonlog-wbtest-restore-gate-rst"
  remove_tree(src)
  remove_tree(bak)
  remove_tree(rst)
  // Build a real multi-segment directory (small roll size forces rolls).
  ignore(@backend_native.ensure_dir(src))
  let log = @backend_native.open_log_dir(src, 200)
  for i in 0..<8 {
    ignore(
      log.append(
        @utf8.encode("key" + i.to_string()),
        @utf8.encode("payload-0123456789-0123456789-" + i.to_string()),
        1000L + i.to_int64(),
      ),
    )
  }
  log.flush()
  @backend_native.flush_meta(src, log)
  close_log(log)
  let copied = @backend_native.backup_log_dir(src, bak)
  assert_true(copied >= 2)
  // A complete backup restores fine and keeps the segment count.
  assert_eq(@backend_native.restore_log_dir(bak, rst), copied)
  remove_tree(rst)
  let segs : Array[String] = []
  for name in @backend_native.list_dir(bak) {
    if name.has_suffix(".log") {
      segs.push(name)
    }
  }
  let victim = bak + "/" + segs[segs.length() - 1]
  let original = @backend_native.read_file(victim)
  // A truncated segment (crash between the manifest copy and the segment
  // copy) is rejected on size instead of restoring silently short.
  @backend_native.write_file(
    victim,
    @core.slice(original, 0, original.length() - 3),
  ) catch {
    _ => ()
  }
  let mut raised = false
  ignore(@backend_native.restore_log_dir(bak, rst)) catch {
    _ => raised = true
  }
  assert_true(raised)
  @backend_native.write_file(victim, original) catch {
    _ => ()
  }
  // A missing segment is rejected too.
  ignore(@backend_native.remove_file(victim))
  raised = false
  ignore(@backend_native.restore_log_dir(bak, rst)) catch {
    _ => raised = true
  }
  assert_true(raised)
  @backend_native.write_file(victim, original) catch {
    _ => ()
  }
  // The gate is not over-strict: the intact backup still restores.
  assert_eq(@backend_native.restore_log_dir(bak, rst), copied)
  remove_tree(src)
  remove_tree(bak)
  remove_tree(rst)
}

///|
test "tier policy roundtrips an explicit warm 0 (M214)" {
  let dir = "/tmp/moonlog-wbtest-tier-warm0"
  remove_tree(dir)
  ignore(@backend_native.ensure_dir(dir))
  let cold = "/tmp/moonlog-wbtest-tier-warm0-cold"
  // First setup without --warm: load default of 1 (backwards compatible).
  save_tier_policy(dir, cold, requested_warm((None : String?)))
  assert_eq(load_tier_policy(dir), (cold, 1L))
  // An explicit --warm 0 must persist as 0 — the old save dropped the
  // second line at 0, silently degrading every rolled segment to warm.
  save_tier_policy(dir, cold, requested_warm(Some("0")))
  assert_eq(load_tier_policy(dir), (cold, 0L))
  // Updating without --warm keeps the persisted 0.
  save_tier_policy(dir, cold, requested_warm((None : String?)))
  assert_eq(load_tier_policy(dir), (cold, 0L))
  // Explicit positive values and the off reset keep working.
  save_tier_policy(dir, cold, requested_warm(Some("3")))
  assert_eq(load_tier_policy(dir), (cold, 3L))
  save_tier_policy(dir, "off", requested_warm(Some("0")))
  assert_eq(load_tier_policy(dir), ("", 0L))
  remove_tree(dir)
  remove_tree(cold)
}
