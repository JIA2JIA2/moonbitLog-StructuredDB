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

///|
test "parse_ts_arg accepts epoch ms and ISO-8601 (M216)" {
  // Plain integers stay epoch milliseconds (historical format).
  assert_eq(parse_ts_arg("since", "0"), 0L)
  assert_eq(parse_ts_arg("since", "1794458520000"), 1794458520000L)
  // ISO-8601 date-time with Z; bare dates are midnight UTC (2.3).
  assert_eq(parse_ts_arg("since", "2026-11-12T08:02:00Z"), 1794470520000L)
  assert_eq(parse_ts_arg("until", "2026-11-12"), 1794441600000L)
  // Junk still fails with the option-naming error.
  let mut raised = false
  ignore(parse_ts_arg("since", "not-a-time")) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "parse_duration_ms: plain numbers stay raw, time-unit suffixes scale to ms (5.5 sixth round)" {
  // Plain numbers keep their raw value (dashboards treat the field as ms).
  assert_eq(parse_duration_ms("42"), Some(42.0))
  assert_eq(parse_duration_ms("0.5"), Some(0.5))
  assert_eq(parse_duration_ms("-7.25"), Some(-7.25))
  // Unit suffixes scale into milliseconds; sub-ms units divide so the
  // result is the correctly-rounded nearest double (950 * 0.001 would
  // drift into 0.9500000000000001, 950 / 1000.0 is exactly 0.95).
  assert_eq(parse_duration_ms("42ms"), Some(42.0))
  assert_eq(parse_duration_ms("1.2s"), Some(1200.0))
  assert_eq(parse_duration_ms("1.5 s"), Some(1500.0))
  assert_eq(parse_duration_ms("250us"), Some(0.25))
  // Both micro-sign spellings (U+00B5 micro sign, U+03BC greek mu).
  assert_eq(parse_duration_ms("950µs"), Some(0.95))
  assert_eq(parse_duration_ms("950μs"), Some(0.95))
  assert_eq(parse_duration_ms("1200ns"), Some(0.0012))
  // Whitespace around the number survives.
  assert_eq(parse_duration_ms(" 42ms "), Some(42.0))
  assert_eq(parse_duration_ms("42 ms"), Some(42.0))
  // Unknown suffixes and bare units stay dropped — guessing a dimension
  // ("KB"? a bare "m" for minutes?) would poison the quantiles worse than
  // omitting the sample.
  assert_eq(parse_duration_ms("42MS"), None)
  assert_eq(parse_duration_ms("42 seconds"), None)
  assert_eq(parse_duration_ms("42KB"), None)
  assert_eq(parse_duration_ms("ms"), None)
  assert_eq(parse_duration_ms("s"), None)
  assert_eq(parse_duration_ms("abc"), None)
  assert_eq(parse_duration_ms(""), None)
}

///|
test "audit_prev_hash re-reads the tail when another process grew the file (6.3 fourth pass)" {
  let dir = "/tmp/moonlog-wbtest-audit-h3"
  remove_tree(dir)
  audit_log(dir, "local", "query", "allow", "t1")
  let base = audit_path(dir)
  let first = audit_prev_hash(base)
  // Simulate another process (the HTTP gateway or an operator CLI) appending
  // to the same AUDIT: the file grew under us, so the cached tail is stale
  // and linking to it would make the next verify report a chain nobody
  // broke. The size probe must force a re-read.
  let foreign = @utf8.encode(
    "{\"ts\":1,\"actor\":\"other\",\"action\":\"query\",\"decision\":\"allow\",\"target\":\"x\",\"prev\":\"00000000\"}\n",
  )
  ignore(@backend_native.append_file(base, foreign) catch { _ => () })
  let second = audit_prev_hash(base)
  assert_true(first != second)
  assert_eq(
    second,
    crc32_hex(@core.crc32(@core.slice(foreign, 0, foreign.length() - 1))),
  )
  // Unchanged size: the cache stays the O(1) path and returns the same hex.
  assert_eq(audit_prev_hash(base), second)
  remove_tree(dir)
}

///|
test "audit_chain_stats reports row count and last-row crc (6.3 fourth pass)" {
  let dir = "/tmp/moonlog-wbtest-audit-stats"
  remove_tree(dir)
  audit_log(dir, "local", "query", "allow", "t1")
  audit_log(dir, "local", "stats", "allow", "t2")
  audit_log(dir, "local", "backup", "allow", "t3")
  let base = audit_path(dir)
  let (broken, rows, tail) = audit_chain_stats(base)
  assert_eq(broken, -1)
  assert_eq(rows, 3L)
  // The last-row crc equals the row pinned by an anchor at the file's
  // current extent (the anchor's byte offset marks that row's end).
  let size = @backend_native.file_size(base)
  assert_eq(
    tail,
    audit_anchor_pinned_crc(@backend_native.read_file(base), size),
  )
  // An offset past the end (or zero) pins nothing — an anchor claiming bytes
  // the file no longer has is exactly the truncation evidence.
  assert_eq(
    audit_anchor_pinned_crc(@backend_native.read_file(base), size + 1L),
    "",
  )
  assert_eq(audit_anchor_pinned_crc(@backend_native.read_file(base), 0L), "")
  remove_tree(dir)
}

///|
test "audit pin log: bump appends pins that track the trail (6.3 fourth pass)" {
  let dir = "/tmp/moonlog-wbtest-audit-anchor"
  remove_tree(dir)
  // First append: one pin at the file's extent right after the append.
  audit_log(dir, "local", "query", "allow", "t1")
  let base = audit_path(dir)
  let (_, rows, tail) = audit_chain_stats(base)
  let pins = audit_anchor_pins(base)
  assert_eq(pins.length(), 1)
  assert_eq(pins[0].0, @backend_native.file_size(base))
  assert_eq(pins[0].1, tail)
  assert_eq(rows, 1L)
  // A second append appends a second pin: sizes strictly grow, each pin
  // re-derives against the trail.
  audit_log(dir, "local", "stats", "allow", "t2")
  let pins2 = audit_anchor_pins(base)
  assert_eq(pins2.length(), 2)
  assert_true(pins2[1].0 > pins2[0].0)
  let data2 = @backend_native.read_file(base)
  for i in 0..<pins2.length() {
    assert_eq(audit_anchor_pinned_crc(data2, pins2[i].0), pins2[i].1)
  }
  // The pin log travels with the trail under its AUDIT.* name.
  assert_true(@backend_native.file_exists(base + ".head"))
  remove_tree(dir)
}

///|
test "audit pin log flags tail truncation, rewrite and survives later appends (6.3 fourth pass)" {
  let dir = "/tmp/moonlog-wbtest-audit-tamper"
  remove_tree(dir)
  audit_log(dir, "local", "query", "allow", "t1")
  audit_log(dir, "local", "stats", "allow", "t2")
  let base = audit_path(dir)
  let data = @backend_native.read_file(base)
  let (all_rows, _) = split_complete_lines(data, true)
  assert_eq(all_rows.length(), 2)
  let pins = audit_anchor_pins(base)
  assert_eq(pins.length(), 2)
  // Shape 1 — truncate the last row: the chain stays intact (this is the
  // blind spot M210's line-level and chain checks share) but the second pin
  // reaches past the file end.
  let mut kept : Bytes = b""
  for i in 0..<(all_rows.length() - 1) {
    kept = kept + all_rows[i] + b"\n"
  }
  @backend_native.write_file(base, kept) catch {
    _ => ()
  }
  let data1 = @backend_native.read_file(base)
  let (broken1, rows1, _) = audit_chain_stats(base)
  assert_eq(broken1, -1)
  assert_eq(rows1, 1L)
  assert_true(data1.length() < pins[1].0.to_int())
  assert_eq(audit_anchor_pinned_crc(data1, pins[1].0), "")
  // Shape 2 — rewrite the last row keeping its row count and prev link,
  // then let the next legitimate event append on top: the chain re-verifies
  // (its next append links to the rewritten row) and a single overwrite
  // anchor would be washed out — but the pin log is append-only, so pin #2
  // still pins the pre-tamper extent and fails the re-derivation.
  @backend_native.write_file(base, data) catch {
    _ => ()
  }
  let data2 = @backend_native.read_file(base)
  let (rows_all, _) = split_complete_lines(data2, true)
  let s = @utf8.decode_lossy(rows_all[1])
  let tampered_line = s[0:s.length() - 1].to_owned() + ",\"tampered\":true}"
  let rewritten = @utf8.decode_lossy(rows_all[0]) + "\n" + tampered_line + "\n"
  @backend_native.write_file(base, @utf8.encode(rewritten)) catch {
    _ => ()
  }
  audit_log(dir, "local", "backup", "allow", "t3")
  let (broken2, rows2, _) = audit_chain_stats(base)
  assert_eq(broken2, -1)
  assert_eq(rows2, 3L)
  let pins2 = audit_anchor_pins(base)
  assert_eq(pins2.length(), 3)
  let data3 = @backend_native.read_file(base)
  // Pin #1 (over row 1, untouched) still verifies...
  assert_eq(audit_anchor_pinned_crc(data3, pins2[0].0), pins2[0].1)
  // ...while pin #2 (over the pre-tamper row 2) no longer re-derives: the
  // tampered row replaced the pinned one, exactly the evidence the chain
  // cannot produce on its own.
  assert_true(audit_anchor_pinned_crc(data3, pins2[1].0) != pins2[1].1)
  remove_tree(dir)
}

///|
test "selfmon percentage thresholds reject out-of-range values (6.4 fourth pass)" {
  let cfg : @hashmap.HashMap[String, Int64] = @hashmap.HashMap::HashMap([])
  // A hand-typed DISK_WARN_PCT=150 can never fire (used tops out at 100) —
  // it used to take effect verbatim and silently disarm the disk dimension.
  cfg.set("DISK_WARN_PCT", 150L)
  assert_eq(selfmon_threshold_pct(cfg, "DISK_WARN_PCT", 80L), 80L)
  // Negatives are rejected by the loader already; the wrapper holds the
  // same floor for env-var-sourced values.
  cfg.set("DISK_WARN_PCT", -5L)
  assert_eq(selfmon_threshold_pct(cfg, "DISK_WARN_PCT", 80L), 80L)
  // A legal value survives untouched.
  cfg.set("DISK_WARN_PCT", 95L)
  assert_eq(selfmon_threshold_pct(cfg, "DISK_WARN_PCT", 80L), 95L)
  // Failure-rate warn shares the domain (the gauge caps at 100).
  cfg.set("FAIL_RATE_WARN_PCT", 120L)
  assert_eq(selfmon_threshold_pct(cfg, "FAIL_RATE_WARN_PCT", 50L), 50L)
  // cursor polling is a data read: its failures belong in the numerator and
  // its allows in the denominator — the one audited read command that was
  // missing from the whitelist, so cursor breakage read as "too healthy".
  assert_true(selfmon_is_query_cmd("cursor"))
  assert_true(selfmon_is_query_cmd("cursor-lag"))
  assert_false(selfmon_is_query_cmd("export-jsonl"))
}

///|
test "selfmon snapshot reader counts corrupt snapshot files (6.4 fourth pass)" {
  let dir = "/tmp/moonlog-wbtest-selfmon-snap"
  remove_tree(dir)
  ignore(@backend_native.ensure_dir(dir + "/SELFMON"))
  // No snapshot at all: no writer has reported — ok, zero corrupt.
  let (w0, ts0, _, _, _, c0) = selfmon_latest_snapshot(dir)
  assert_eq(w0, "")
  assert_eq(ts0, -1L)
  assert_eq(c0, 0)
  // A crash mid-write leaves a truncated snapshot: the file exists but
  // cannot be parsed — corrupt, not "no writer".
  @backend_native.write_file(dir + "/SELFMON/http.json", b"{\"ts\":") catch {
    _ => ()
  }
  let (_, ts1, _, _, _, c1) = selfmon_latest_snapshot(dir)
  assert_eq(ts1, -1L)
  assert_eq(c1, 1)
  // Parses but carries no timestamp: not usable either.
  @backend_native.write_file(
    dir + "/SELFMON/http.json",
    b"{\"writer\":\"http\",\"pending\":7}",
  ) catch {
    _ => ()
  }
  let (_, ts2, _, _, _, c2) = selfmon_latest_snapshot(dir)
  assert_eq(ts2, -1L)
  assert_eq(c2, 1)
  // One intact snapshot alongside a corrupt one: the gauge works from the
  // intact file and the corrupt count is reported alongside.
  let now = now_ms()
  @backend_native.write_file(
    dir + "/SELFMON/http.json",
    @utf8.encode(
      "{\"ts\":" +
      now.to_string() +
      ",\"writer\":\"http\",\"pending\":12,\"head_lag_ms\":30,\"backlog_alerts\":0}",
    ),
  ) catch {
    _ => ()
  }
  @backend_native.write_file(dir + "/SELFMON/http2.json", b"garbage") catch {
    _ => ()
  }
  let (w3, ts3, p3, _, _, c3) = selfmon_latest_snapshot(dir)
  assert_eq(w3, "http")
  assert_eq(ts3, now)
  assert_eq(p3, 12L)
  assert_eq(c3, 1)
  remove_tree(dir)
}

///|
test "selfmon error trim keeps unparseable rows (6.4 fourth pass)" {
  let dir = "/tmp/moonlog-wbtest-selfmon-trim"
  remove_tree(dir)
  ignore(@backend_native.ensure_dir(dir))
  let now = now_ms()
  // One in-window good row, one crash-truncated row (no readable ts), one
  // out-of-window good row.
  let body = "{\"ts\":" +
    now.to_string() +
    ",\"cmd\":\"query\",\"error\":\"boom\"}\n{\"ts\" truncated mid crash\n{\"ts\":123,\"cmd\":\"query\",\"error\":\"old\"}\n"
  @backend_native.write_file(dir + "/SELFMON_ERRORS", @utf8.encode(body)) catch {
    _ => ()
  }
  selfmon_trim_errors(dir, now - 1000L, 1L)
  let kept = @utf8.decode_lossy(
    @backend_native.read_file(dir + "/SELFMON_ERRORS"),
  )
  assert_true(kept.contains("boom"))
  assert_true(kept.contains("truncated"))
  assert_false(kept.contains("old"))
  remove_tree(dir)
}
