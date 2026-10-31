///|
test "native file log persists across reopen" {
  let dir = "/tmp/moonlog_native_test"
  ignore(@backend_native.ensure_dir(dir))
  let path = dir + "/seg-0.log"
  ignore(@backend_native.remove_file(path))
  let f = @backend_native.NativeFileLog::open(path) catch { _ => panic() }
  let seg : @segment.Segment[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @segment.Segment::new(f, f, (0 : UInt64))
  let _ = seg.append(b"k", b"v", (1 : Int64)) catch { _ => panic() }
  let _ = seg.append(b"k2", b"v2", (2 : Int64)) catch { _ => panic() }
  assert_eq(seg.count(), 2)
  f.close()
  assert_true(f.is_closed())
  let f2 = @backend_native.NativeFileLog::open(path) catch { _ => panic() }
  let seg2 : @segment.Segment[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @segment.Segment::new(f2, f2, (0 : UInt64))
  assert_eq(f2.size, seg.byte_size())
  let recs = seg2.scan() catch { _ => panic() }
  assert_eq(recs.length(), 2)
  assert_eq(recs[0].value, b"v")
  assert_eq(recs[1].value, b"v2")
  assert_eq(recs[1].offset, (1 : UInt64))
  f2.close()
  ignore(@backend_native.remove_file(path))
}

///|
test "native read-only open reads existing data" {
  let dir = "/tmp/moonlog_native_test"
  ignore(@backend_native.ensure_dir(dir))
  let path = dir + "/ro.log"
  ignore(@backend_native.remove_file(path))
  let w = @backend_native.NativeFileLog::open(path) catch { _ => panic() }
  let ws : @segment.Segment[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @segment.Segment::new(w, w, (0 : UInt64))
  ignore(ws.append(b"k", b"v", (0 : Int64)) catch { _ => panic() })
  w.close()
  let r = @backend_native.NativeFileLog::open_readonly(path) catch {
    _ => panic()
  }
  let rs : @segment.Segment[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @segment.Segment::new(r, r, (0 : UInt64))
  let recs = rs.scan() catch { _ => panic() }
  assert_eq(recs.length(), 1)
  assert_eq(recs[0].value, b"v")
  r.close()
  ignore(@backend_native.remove_file(path))
}

///|
test "native log rolls into separate files and scans back" {
  let dir = "/tmp/moonlog_native_test"
  ignore(@backend_native.ensure_dir(dir))
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((100 : Int64), base => {
    let path = dir + "/" + @segment.segment_file_name(base)
    ignore(@backend_native.remove_file(path))
    let f = @backend_native.NativeFileLog::open(path) catch { _ => panic() }
    @segment.Segment::new(f, f, base)
  })
  for i = 0; i < 6; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  assert_eq(log.count(), 6)
  assert_true(log.segment_count() >= 2)
  let recs = log.scan() catch { _ => panic() }
  assert_eq(recs.length(), 6)
  assert_eq(recs[0].offset, (0 : UInt64))
  assert_eq(recs[5].offset, (5 : UInt64))
  let hit = log.get((4 : UInt64)) catch { _ => panic() }
  match hit {
    Some(rec) => assert_eq(rec.value, b"v")
    None => panic()
  }
}

///|
fn clean_dir(dir : String) -> Unit {
  let names = @backend_native.list_dir(dir) catch { _ => return }
  for name in names {
    if name.has_suffix(".log") {
      ignore(@backend_native.remove_file(dir + "/" + name))
    }
  }
}

///|
test "native recover_log_dir ignores a torn tail and keeps appending" {
  let dir = "/tmp/moonlog_recover_tail"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch { _ => panic() }
  })
  ignore(log.append(b"k", b"a", (0 : Int64)) catch { _ => panic() })
  ignore(log.append(b"k", b"b", (1 : Int64)) catch { _ => panic() })
  for seg in log.segments {
    seg.writer.close()
  }
  let path = dir + "/" + @segment.segment_file_name((0 : UInt64))
  let f = @backend_native.NativeFileLog::open(path) catch { _ => panic() }
  ignore(f.append(b"junk") catch { _ => panic() })
  f.close()
  let rlog = @backend_native.recover_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(rlog.count(), 2)
  let recs = rlog.scan() catch { _ => panic() }
  assert_eq(recs.length(), 2)
  assert_eq(recs[1].value, b"b")
  let o = rlog.append(b"k", b"c", (2 : Int64)) catch { _ => panic() }
  assert_eq(o, (2 : UInt64))
  for seg in rlog.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "native recover_log_dir rebuilds every rolled segment" {
  let dir = "/tmp/moonlog_recover_multi"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((100 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch { _ => panic() }
  })
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  let before = log.segment_count()
  for seg in log.segments {
    seg.writer.close()
  }
  let rlog = @backend_native.recover_log_dir(dir, (100 : Int64)) catch {
    _ => panic()
  }
  assert_eq(rlog.count(), 8)
  assert_eq(rlog.segment_count(), before)
  let recs = rlog.scan() catch { _ => panic() }
  assert_eq(recs.length(), 8)
  assert_eq(recs[0].offset, (0 : UInt64))
  assert_eq(recs[7].offset, (7 : UInt64))
  let o = rlog.append(b"k", b"v", (8 : Int64)) catch { _ => panic() }
  assert_eq(o, (8 : UInt64))
  for seg in rlog.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "recover_log_dir on an empty directory yields an empty log" {
  let dir = "/tmp/moonlog_recover_empty"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log = @backend_native.recover_log_dir(dir, (100 : Int64)) catch {
    _ => panic()
  }
  assert_eq(log.count(), 0)
  assert_eq(log.segment_count(), 0)
  let o = log.append(b"k", b"v", (0 : Int64)) catch { _ => panic() }
  assert_eq(o, (0 : UInt64))
  for seg in log.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}
