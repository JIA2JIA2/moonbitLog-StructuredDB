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
