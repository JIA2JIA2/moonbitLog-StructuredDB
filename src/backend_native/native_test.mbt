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
    ignore(@backend_native.remove_file(dir + "/" + name))
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
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
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
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
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

///|
fn remove_meta_files(dir : String) -> Unit {
  let names = @backend_native.list_dir(dir) catch { _ => return }
  for name in names {
    if !name.has_suffix(".log") {
      ignore(@backend_native.remove_file(dir + "/" + name))
    }
  }
}

///|
test "open_log_dir uses persisted meta on the fast path" {
  let dir = "/tmp/moonlog_open_fast"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 5; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  assert_true(@backend_native.file_exists(dir + "/MANIFEST"))
  let reopened = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(reopened.count(), 5)
  for seg in reopened.segments {
    assert_true(seg.meta_loaded)
  }
  let recs = reopened.scan() catch { _ => panic() }
  assert_eq(recs.length(), 5)
  assert_eq(recs[4].offset, (4 : UInt64))
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "open_log_dir falls back to recovery without meta" {
  let dir = "/tmp/moonlog_open_fallback"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 4; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  remove_meta_files(dir)
  assert_true(!@backend_native.file_exists(dir + "/MANIFEST"))
  let reopened = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(reopened.count(), 4)
  for seg in reopened.segments {
    assert_true(!seg.meta_loaded)
  }
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "open_log_dir accepts an Always sync policy" {
  let dir = "/tmp/moonlog_sync_always"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new(
    (1_000_000 : Int64),
    base => {
      @backend_native.open_segment_in_dir(dir, base) catch {
        _ => panic()
      }
    },
    sync=@log.SyncPolicy::Always,
  )
  for i = 0; i < 3; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let reopened = @backend_native.open_log_dir(
    dir,
    (1_000_000 : Int64),
    sync=@log.SyncPolicy::Always,
  ) catch {
    _ => panic()
  }
  assert_eq(reopened.count(), 3)
  let recs = reopened.scan() catch { _ => panic() }
  assert_eq(recs.length(), 3)
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "dir lock serializes writers and reopens after release" {
  let dir = "/tmp/moonlog_lock_test"
  ignore(@backend_native.ensure_dir(dir))
  let lock = @backend_native.DirLock::acquire(dir, true) catch { _ => panic() }
  assert_true(lock.held)
  let blocked = try {
    let second = @backend_native.DirLock::acquire(dir, true)
    second.release()
    false
  } catch {
    _ => true
  }
  assert_true(blocked)
  lock.release()
  assert_true(!lock.held)
  let again = @backend_native.DirLock::acquire(dir, true) catch { _ => panic() }
  again.release()
  ignore(@backend_native.remove_file(dir + "/LOCK"))
}

///|
test "cursor position round-trips through the cursor file" {
  let dir = "/tmp/moonlog_cursor_test"
  ignore(@backend_native.ensure_dir(dir))
  ignore(@backend_native.remove_file(@backend_native.cursor_path(dir)))
  assert_eq(@backend_native.load_cursor(dir), (0 : UInt64))
  @backend_native.save_cursor(dir, (42 : UInt64)) catch {
    _ => panic()
  }
  assert_eq(@backend_native.load_cursor(dir), (42 : UInt64))
  @backend_native.save_cursor(dir, (0 : UInt64)) catch {
    _ => panic()
  }
  assert_eq(@backend_native.load_cursor(dir), (0 : UInt64))
  ignore(@backend_native.remove_file(@backend_native.cursor_path(dir)))
}

///|
test "corrupt cursor file falls back to zero" {
  let dir = "/tmp/moonlog_cursor_corrupt"
  ignore(@backend_native.ensure_dir(dir))
  @backend_native.write_file(@backend_native.cursor_path(dir), b"not-a-cursor") catch {
    _ => panic()
  }
  assert_eq(@backend_native.load_cursor(dir), (0 : UInt64))
  ignore(@backend_native.remove_file(@backend_native.cursor_path(dir)))
}

///|
test "named cursor positions round-trip independently" {
  let dir = "/tmp/moonlog_named_cursor"
  ignore(@backend_native.ensure_dir(dir))
  ignore(
    @backend_native.remove_file(@backend_native.named_cursor_path(dir, "alice")),
  )
  ignore(
    @backend_native.remove_file(@backend_native.named_cursor_path(dir, "bob")),
  )
  assert_eq(@backend_native.load_named_cursor(dir, "alice"), (0 : UInt64))
  @backend_native.save_named_cursor(dir, "alice", (7 : UInt64)) catch {
    _ => panic()
  }
  @backend_native.save_named_cursor(dir, "bob", (3 : UInt64)) catch {
    _ => panic()
  }
  assert_eq(@backend_native.load_named_cursor(dir, "alice"), (7 : UInt64))
  assert_eq(@backend_native.load_named_cursor(dir, "bob"), (3 : UInt64))
  ignore(
    @backend_native.remove_file(@backend_native.named_cursor_path(dir, "alice")),
  )
  ignore(
    @backend_native.remove_file(@backend_native.named_cursor_path(dir, "bob")),
  )
}

///|
test "open_log_dir detects a truncated segment and recovers" {
  let dir = "/tmp/moonlog_manifest_size"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 6; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  let size = log.segments[0].byte_size()
  for seg in log.segments {
    seg.writer.close()
  }
  let path = dir + "/" + @segment.segment_file_name((0 : UInt64))
  let f = @backend_native.NativeFileLog::open(path) catch { _ => panic() }
  f.truncate(size / (2 : Int64)) catch {
    _ => panic()
  }
  f.close()
  let reopened = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_true(reopened.count() < 6)
  let recs = reopened.scan() catch { _ => panic() }
  assert_eq(recs.length(), reopened.count())
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "flush_meta replaces metadata atomically without temp leftovers" {
  let dir = "/tmp/moonlog_atomic_meta"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 3; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  let names = @backend_native.list_dir(dir)
  for name in names {
    assert_true(!name.has_suffix(".tmp"))
  }
  assert_true(
    @backend_native.file_exists(dir + "/" + @backend_native.MANIFEST_NAME),
  )
  assert_true(
    @backend_native.file_exists(
      @backend_native.segment_index_path(dir, (0 : UInt64)),
    ),
  )
  for seg in log.segments {
    seg.writer.close()
  }
  let reopened = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(reopened.count(), 3)
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "cursor writes are atomic and leave no temp files" {
  let dir = "/tmp/moonlog_cursor_atomic"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  @backend_native.save_cursor(dir, (9 : UInt64)) catch {
    _ => panic()
  }
  @backend_native.save_named_cursor(dir, "alice", (4 : UInt64)) catch {
    _ => panic()
  }
  let names = @backend_native.list_dir(dir)
  for name in names {
    assert_true(!name.has_suffix(".tmp"))
  }
  assert_eq(@backend_native.load_cursor(dir), (9 : UInt64))
  assert_eq(@backend_native.load_named_cursor(dir, "alice"), (4 : UInt64))
  clean_dir(dir)
}

///|
test "named cursors can be listed and removed" {
  let dir = "/tmp/moonlog_cursor_list"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  @backend_native.save_named_cursor(dir, "alice", (1 : UInt64)) catch {
    _ => panic()
  }
  @backend_native.save_named_cursor(dir, "bob", (2 : UInt64)) catch {
    _ => panic()
  }
  let names = @backend_native.list_named_cursors(dir) catch { _ => panic() }
  assert_eq(names.length(), 2)
  let mut saw_alice = false
  let mut saw_bob = false
  for name in names {
    if name == "alice" {
      saw_alice = true
    }
    if name == "bob" {
      saw_bob = true
    }
  }
  assert_true(saw_alice)
  assert_true(saw_bob)
  @backend_native.remove_named_cursor(dir, "alice")
  assert_eq(@backend_native.load_named_cursor(dir, "alice"), (0 : UInt64))
  let remaining = @backend_native.list_named_cursors(dir) catch { _ => panic() }
  assert_eq(remaining.length(), 1)
  clean_dir(dir)
}

///|
test "open_log_dir picks a roll-size scaled index interval" {
  let dir = "/tmp/moonlog_index_interval"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  ignore(log.append(b"k", b"v", (0 : Int64)) catch { _ => panic() })
  let expected = @backend_native.index_interval_for((1_000_000 : Int64))
  assert_true(expected >= 1)
  assert_eq(log.segments[0].index_interval(), expected)
  for seg in log.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "flush_meta records segment checksums and verify detects tampering" {
  let dir = "/tmp/moonlog_segment_checksum"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((60 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let reopened = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  let ok = reopened.verify()
  match ok.first_bad_checksum {
    Some(_) => panic()
    None => ()
  }
  for seg in reopened.segments {
    seg.writer.close()
  }
  let path = dir + "/" + @segment.segment_file_name((0 : UInt64))
  let data = @backend_native.read_file(path)
  assert_true(data.length() > 0)
  let head : Bytes = if data.at(0).to_int() == 0 { b"\x01" } else { b"\x00" }
  let tampered = head + @core.slice(data, 1, data.length())
  @backend_native.write_file(path, tampered) catch {
    _ => panic()
  }
  let reopened2 = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  let report = reopened2.verify()
  match report.first_bad_checksum {
    Some(base) => assert_eq(base, (0 : UInt64))
    None => panic()
  }
  for seg in reopened2.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "append buffers writes and reads drain them before flushing" {
  let dir = "/tmp/moonlog_write_buffer"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 10; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  // The records are still buffered; reads must still see them.
  let recs = log.scan() catch { _ => panic() }
  assert_eq(recs.length(), 10)
  assert_eq(recs[9].value, b"value")
  for seg in log.segments {
    seg.writer.close()
  }
  let reopened = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(reopened.count(), 10)
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "compress_log_dir compresses rolled segments and they reopen read-only" {
  let dir = "/tmp/moonlog_compress"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((60 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let packed = @backend_native.compress_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  assert_true(packed >= 1)
  let reopened = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  assert_eq(reopened.count(), 8)
  let recs = reopened.scan() catch { _ => panic() }
  assert_eq(recs.length(), 8)
  assert_eq(recs[7].value, b"value")
  let report = reopened.verify()
  match report.first_bad_checksum {
    Some(_) => panic()
    None => ()
  }
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "flush_meta persists the key index and reopen reads it back" {
  let dir = "/tmp/moonlog_keystore"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((60 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  let keys : Array[Bytes] = [
    b"k0", b"k1", b"k2", b"k3", b"k4", b"k5", b"k6", b"k7",
  ]
  let values : Array[Bytes] = [
    b"v0", b"v1", b"v2", b"v3", b"v4", b"v5", b"v6", b"v7",
  ]
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(keys[i], values[i], i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let names = @backend_native.list_dir(dir) catch { _ => panic() }
  let mut saw_keys = false
  for name in names {
    if name.has_suffix(".keys") {
      saw_keys = true
    }
  }
  assert_true(saw_keys)
  let reopened = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  assert_eq(reopened.count(), 8)
  let index = reopened.build_key_index()
  let got = reopened.get_latest(index, b"k3") catch { _ => panic() }
  match got {
    Some(rec) => assert_eq(rec.value, b"v3")
    None => panic()
  }
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "acquire_timeout retries a busy lock and fails on timeout" {
  let dir = "/tmp/moonlog_lock_timeout"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let held = @backend_native.DirLock::acquire(dir, true) catch { _ => panic() }
  let mut raised = false
  try {
    let _ = @backend_native.DirLock::acquire_timeout(dir, true, (30 : Int32))
  } catch {
    _ => raised = true
  }
  assert_true(raised)
  held.release()
  let again = @backend_native.DirLock::acquire_timeout(dir, true, (30 : Int32)) catch {
    _ => panic()
  }
  again.release()
  clean_dir(dir)
}

///|
test "flush_meta skips clean segments and rebuilds on demand" {
  let dir = "/tmp/moonlog_dirty_flush"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  ignore(log.append(b"a", b"1", (0 : Int64)) catch { _ => panic() })
  ignore(log.append(b"b", b"2", (1 : Int64)) catch { _ => panic() })
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let find_keys = fn() -> String {
    let names = @backend_native.list_dir(dir) catch { _ => panic() }
    let mut found = ""
    for name in names {
      if name.has_suffix(".keys") {
        found = dir + "/" + name
      }
    }
    found
  }
  let kp = find_keys()
  assert_true(kp.length() > 0)
  let reopened = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  // External loss of the sidecar: a clean segment is NOT rewritten on flush.
  ignore(@backend_native.remove_file(kp))
  ignore(@backend_native.flush_meta(dir, reopened) catch { _ => panic() })
  for seg in reopened.segments {
    seg.writer.close()
  }
  let kp2 = find_keys()
  assert_true(kp2.length() == 0)
  // A fresh open still recovers from the data file and rebuilds the keys.
  let again = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(again.count(), 2)
  let index = again.build_key_index()
  let got = again.get_latest(index, b"b") catch { _ => panic() }
  match got {
    Some(rec) => assert_eq(rec.value, b"2")
    None => panic()
  }
  for seg in again.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "open_log_dir recovers when the index sidecar is corrupt" {
  let dir = "/tmp/moonlog_corrupt_index"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 6; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let ip = @backend_native.segment_index_path(dir, (0 : UInt64))
  let data = @backend_native.read_file(ip)
  assert_true(data.length() > 0)
  let head : Bytes = if data.at(0).to_int() == 0 { b"\x01" } else { b"\x00" }
  @backend_native.write_file(ip, head + @core.slice(data, 1, data.length())) catch {
    _ => panic()
  }
  let reopened = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(reopened.count(), 6)
  let index = reopened.build_key_index()
  let got = reopened.get_latest(index, b"k") catch { _ => panic() }
  match got {
    Some(rec) => assert_eq(rec.value, b"value")
    None => panic()
  }
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "open_log_dir rebuilds keys when manifest and sidecars are missing" {
  let dir = "/tmp/moonlog_missing_sidecars"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((60 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  let keys : Array[Bytes] = [
    b"k0", b"k1", b"k2", b"k3", b"k4", b"k5", b"k6", b"k7",
  ]
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(keys[i], b"v", i.to_int64()) catch { _ => panic() })
  }
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let names = @backend_native.list_dir(dir) catch { _ => panic() }
  for name in names {
    if name.has_suffix(".index") ||
      name.has_suffix(".keys") ||
      name == @backend_native.MANIFEST_NAME {
      ignore(@backend_native.remove_file(dir + "/" + name))
    }
  }
  let reopened = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  assert_eq(reopened.count(), 8)
  let index = reopened.build_key_index()
  assert_eq(index.size(), 8)
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
/// Deterministic property test on the real file backend: randomized
/// put/delete/check sequences with rolling segments, plus periodic crash
/// injection — the last segment's data file is truncated by a few bytes (a
/// torn tail), so the manifest size check fails and the reopen path runs a
/// full recovery. The in-memory model is rebuilt from the surviving record
/// count.
test "property: native randomized ops with crash injection match the model" {
  let dir = "/tmp/moonlog_prop_native"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let keys : Array[Bytes] = [
    b"k0", b"k1", b"k2", b"k3", b"k4", b"k5", b"k6", b"k7", b"k8", b"k9", b"ka",
    b"kb", b"kc", b"kd", b"ke", b"kf",
  ]
  let values : Array[Bytes] = [
    b"v0", b"v1", b"v2", b"v3", b"v4", b"v5", b"v6", b"v7", b"v8", b"v9", b"va",
    b"vb", b"vc", b"vd", b"ve", b"vf",
  ]
  let model : Array[Bytes?] = Array::make(16, (None : Bytes?))
  let ops : Array[(Int32, Int32, Int32)] = []
  let mut log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @backend_native.open_log_dir(dir, (200 : Int64)) catch { _ => panic() }
  let check_all = fn(
    l : @log.Log[@backend_native.NativeFileLog, @backend_native.NativeFileLog],
  ) -> Unit raise {
    let idx = l.build_key_index()
    for i = 0; i < 16; i = i + 1 {
      let got = l.get_latest(idx, keys[i]) catch { _ => panic() }
      match model[i] {
        Some(expected) =>
          match got {
            Some(rec) =>
              if rec.value != expected {
                println(
                  "MISMATCH ki=" +
                  i.to_string() +
                  " expected=" +
                  (@utf8.decode(expected) catch { _ => "<bin>" }) +
                  " got=" +
                  (@utf8.decode(rec.value) catch { _ => "<bin>" }),
                )
                assert_eq(rec.value, expected)
              }
            None => {
              println("MISSING ki=" + i.to_string())
              panic()
            }
          }
        None =>
          match got {
            Some(_) => {
              println("EXTRA ki=" + i.to_string())
              panic()
            }
            None => ()
          }
      }
    }
    // Cross-check the folded live view on the file backend too.
    let mut expect = 0
    for i = 0; i < 16; i = i + 1 {
      match model[i] {
        Some(_) => expect = expect + 1
        None => ()
      }
    }
    let snaps = l.snapshot() catch { _ => panic() }
    assert_eq(snaps.length(), expect)
  }
  let mut x : UInt64 = 0xDEADBEEFCAFEBABE
  let mut step = 0
  while step < 300 {
    if step % 60 == 59 {
      // Torn-tail injection: fsync everything, then chop a few bytes off the
      // LAST segment's data file so the manifest size check fails and the
      // reopen path runs a full recovery.
      @backend_native.flush_meta(dir, log) catch {
        _ => panic()
      }
      let last = log.segments[log.segments.length() - 1]
      let path = dir + "/" + @segment.segment_file_name(last.base_offset)
      let data = @backend_native.read_file(path)
      if data.length() > 12 {
        @backend_native.write_file(
          path,
          @core.slice(data, 0, data.length() - 3),
        ) catch {
          _ => panic()
        }
      }
      for seg in log.segments {
        seg.writer.close()
      }
      let reopened = @backend_native.open_log_dir(dir, (200 : Int64)) catch {
        _ => panic()
      }
      let survive = reopened.count()
      // The torn tail only ever eats the most recently appended record(s) and
      // leaves no offset holes, so drop the trailing ops and rebuild the model
      // from what actually survived.
      while ops.length() > survive {
        ignore(ops.pop())
      }
      for i = 0; i < 16; i = i + 1 {
        model[i] = (None : Bytes?)
      }
      for op in ops {
        let (kd, ki, vi) = op
        if kd == 0 {
          model[ki] = Some(values[vi])
        } else {
          model[ki] = (None : Bytes?)
        }
      }
      log = reopened
      check_all(log) catch {
        _ => panic()
      }
    }
    x = x ^ (x << 13)
    x = x ^ (x >> 7)
    x = x ^ (x << 17)
    let roll = ((x >> 32) & 0x7FFFFFFF).to_int() % 100
    let ki = ((x >> 40) & 0xF).to_int()
    let k = keys[ki]
    if roll < 60 {
      let vi = step % 16
      let v = values[vi]
      ignore(log.append(k, v, step.to_int64()) catch { _ => panic() })
      ops.push((0, ki, vi))
      model[ki] = Some(v)
    } else if roll < 85 {
      ignore(log.delete(k, step.to_int64()) catch { _ => panic() })
      ops.push((1, ki, 0))
      model[ki] = (None : Bytes?)
    } else {
      let idx = log.build_key_index()
      let got = log.get_latest(idx, k) catch { _ => panic() }
      match model[ki] {
        Some(expected) =>
          match got {
            Some(rec) => assert_eq(rec.value, expected)
            None => panic()
          }
        None =>
          match got {
            Some(_) => panic()
            None => ()
          }
      }
    }
    step = step + 1
  }
  check_all(log) catch {
    _ => panic()
  }
  let report = log.verify()
  match report.first_bad_offset {
    Some(_) => panic()
    None => ()
  }
  match report.first_bad_checksum {
    Some(_) => panic()
    None => ()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "verify_fast detects data corruption via segment checksums" {
  let dir = "/tmp/moonlog_verify_fast"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((60 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let reopened = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  let ok = reopened.verify_fast()
  match ok.first_bad_checksum {
    Some(_) => panic()
    None => ()
  }
  for seg in reopened.segments {
    seg.writer.close()
  }
  // Flip a byte in the first segment's data file (manifest size unchanged).
  let path = dir + "/" + @segment.segment_file_name((0 : UInt64))
  let data = @backend_native.read_file(path)
  let head : Bytes = if data.at(0).to_int() == 0 { b"\x01" } else { b"\x00" }
  @backend_native.write_file(path, head + @core.slice(data, 1, data.length())) catch {
    _ => panic()
  }
  let reopened2 = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  let bad = reopened2.verify_fast()
  match bad.first_bad_checksum {
    Some(base) => assert_eq(base, (0 : UInt64))
    None => panic()
  }
  for seg in reopened2.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|

///|
test "ts samples are persisted in segment metadata (v8)" {
  let dir = "/tmp/moonlog_ts_persist"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 100; i = i + 1 {
    ignore(log.append(b"k", b"v", (i * 10).to_int64()) catch { _ => panic() })
  }
  assert_eq(log.segment_count(), 1)
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  // Reopen: the loaded segment must restore its in-memory ts samples from the
  // v8 metadata, so scan_time_range uses the sample binary search.
  let reopened = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_true(reopened.segments[0].ts_samples.length() >= 3)
  let mid = reopened.scan_time_range((150 : Int64), (350 : Int64)) catch {
    _ => panic()
  }
  assert_eq(mid.length(), 20)
  assert_eq(mid[0].timestamp, (150 : Int64))
  assert_eq(mid[19].timestamp, (340 : Int64))
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "a freshly loaded segment does not need fsync" {
  let dir = "/tmp/moonlog_fsync_clean"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((60 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let reopened = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  // Data already on disk is durable: loading must not mark segments dirty, or
  // every CLI write command would re-fsync every segment.
  for seg in reopened.segments {
    assert_true(!seg.fsync_dirty)
  }
  for seg in reopened.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "backup and restore roundtrip preserves records and offsets" {
  let src = "/tmp/moonlog_backup_src"
  let dst = "/tmp/moonlog_backup_dst"
  let rst = "/tmp/moonlog_backup_restored"
  ignore(@backend_native.ensure_dir(src))
  ignore(@backend_native.ensure_dir(dst))
  ignore(@backend_native.ensure_dir(rst))
  clean_dir(src)
  clean_dir(dst)
  clean_dir(rst)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((60 : Int64), base => {
    @backend_native.open_segment_in_dir(src, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  @backend_native.flush_meta(src, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let n = @backend_native.backup_log_dir(src, dst) catch { _ => panic() }
  assert_true(n >= 2)
  // An incremental pass with nothing changed copies no segments.
  let none = @backend_native.backup_log_dir(src, dst) catch { _ => panic() }
  assert_eq(none, 0)
  // New appends change only the active segment (and may roll one), so the
  // next incremental pass copies just what changed.
  let log2 = @backend_native.open_log_dir(src, (60 : Int64)) catch {
    _ => panic()
  }
  ignore(log2.append(b"k", b"more", (100 : Int64)) catch { _ => panic() })
  ignore(log2.append(b"k", b"more2", (101 : Int64)) catch { _ => panic() })
  @backend_native.flush_meta(src, log2) catch {
    _ => panic()
  }
  for seg in log2.segments {
    seg.writer.close()
  }
  let inc = @backend_native.backup_log_dir(src, dst) catch { _ => panic() }
  assert_true(inc >= 1)
  let m = @backend_native.restore_log_dir(dst, rst) catch { _ => panic() }
  assert_true(m >= n)
  // The restored copy matches the source, offsets included.
  let rlog = @backend_native.open_log_dir(rst, (60 : Int64)) catch {
    _ => panic()
  }
  assert_eq(rlog.count(), 10)
  assert_eq(rlog.next_offset(), (10 : UInt64))
  let recs = rlog.scan() catch { _ => panic() }
  assert_eq(recs.length(), 10)
  assert_eq(recs[0].offset, (0 : UInt64))
  assert_eq(recs[0].timestamp, (0 : Int64))
  assert_eq(recs[7].offset, (7 : UInt64))
  assert_eq(recs[9].value, b"more2")
  // The restored copy is immediately appendable.
  let off = rlog.append(b"k", b"more", (100 : Int64)) catch { _ => panic() }
  assert_eq(off, (10 : UInt64))
  @backend_native.flush_meta(rst, rlog) catch {
    _ => panic()
  }
  for seg in rlog.segments {
    seg.writer.close()
  }
  clean_dir(src)
  clean_dir(dst)
  clean_dir(rst)
}

///|
test "restore rejects a directory without a decodable MANIFEST" {
  let src = "/tmp/moonlog_restore_badsrc"
  let dst = "/tmp/moonlog_restore_baddst"
  ignore(@backend_native.ensure_dir(src))
  ignore(@backend_native.ensure_dir(dst))
  clean_dir(src)
  clean_dir(dst)
  @backend_native.write_file(src + "/MANIFEST", b"garbage") catch {
    _ => panic()
  }
  let rejected = try {
    ignore(@backend_native.restore_log_dir(src, dst))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  clean_dir(src)
  clean_dir(dst)
}

///|
test "repair truncates a torn tail and rebuilds the manifest" {
  let dir = "/tmp/moonlog_repair_tail"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  ignore(log.append(b"k", b"a", (0 : Int64)) catch { _ => panic() })
  ignore(log.append(b"k", b"b", (1 : Int64)) catch { _ => panic() })
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  // Inject a torn tail and drop the manifest.
  let path = dir + "/" + @segment.segment_file_name((0 : UInt64))
  let f = @backend_native.NativeFileLog::open(path) catch { _ => panic() }
  ignore(f.append(b"junk") catch { _ => panic() })
  f.close()
  ignore(@backend_native.remove_file(dir + "/MANIFEST"))
  let rep = @backend_native.repair_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(rep.truncated, 1)
  assert_eq(rep.isolated, 0)
  assert_eq(rep.removed_empty, 0)
  assert_eq(rep.records, 2)
  match rep.still_bad {
    Some(_) => panic()
    None => ()
  }
  // The rebuilt manifest is used by the next open, and appends continue.
  let rlog = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(rlog.count(), 2)
  let off = rlog.append(b"k", b"c", (2 : Int64)) catch { _ => panic() }
  assert_eq(off, (2 : UInt64))
  @backend_native.flush_meta(dir, rlog) catch {
    _ => panic()
  }
  for seg in rlog.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "repair quarantines a segment failing its stored checksum" {
  let dir = "/tmp/moonlog_repair_isolate"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((60 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  let total_segments = log.segment_count()
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  // Flip a byte in the first (rolled) segment's data file; the size is
  // unchanged, so only the whole-segment checksum catches this.
  let path = dir + "/" + @segment.segment_file_name((0 : UInt64))
  let data = @backend_native.read_file(path)
  let head : Bytes = if data.at(0).to_int() == 0 { b"\x01" } else { b"\x00" }
  @backend_native.write_file(path, head + @core.slice(data, 1, data.length())) catch {
    _ => panic()
  }
  let rep = @backend_native.repair_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  assert_eq(rep.isolated, 1)
  assert_eq(rep.segments, total_segments - 1)
  assert_true(rep.records > 0)
  match rep.still_bad {
    Some(_) => panic()
    None => ()
  }
  // The evidence is kept next to the data as <name>.corrupt.
  assert_true(
    @backend_native.file_exists(
      dir + "/" + @segment.segment_file_name((0 : UInt64)) + ".corrupt",
    ),
  )
  // The surviving log reopens with holes tolerated and stays appendable.
  let rlog = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
    _ => panic()
  }
  assert_eq(rlog.count(), rep.records)
  let before = rlog.next_offset()
  let tail = rlog.append(b"k", b"after", (200 : Int64)) catch { _ => panic() }
  assert_eq(tail, before)
  @backend_native.flush_meta(dir, rlog) catch {
    _ => panic()
  }
  for seg in rlog.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
fn repair_lcg(s : UInt64) -> UInt64 {
  s * 6364136223846793005 + 1442695040888963407
}

///|
/// Randomized damage must never lose a surviving record's content: after a
/// repair pass the log decodes cleanly, every remaining record matches the
/// original at its offset, and appending continues from the recovered end.
/// Segments (or tails) destroyed by the injected damage may be dropped —
/// that is recovery, not corruption.
test "repair property: random damage preserves surviving records" {
  let dir = "/tmp/moonlog_repair_prop"
  ignore(@backend_native.ensure_dir(dir))
  let mut s : UInt64 = 0x9E3779B97F4A7C15
  let mut round = 0
  while round < 40 {
    clean_dir(dir)
    s = repair_lcg(s)
    let n_rec = ((s >> 3) % (5 : UInt64)).to_int() + 4
    let log : @log.Log[
      @backend_native.NativeFileLog,
      @backend_native.NativeFileLog,
    ] = @log.Log::new((60 : Int64), base => {
      @backend_native.open_segment_in_dir(dir, base) catch {
        _ => panic()
      }
    })
    let before : Array[Bytes] = []
    for i = 0; i < n_rec; i = i + 1 {
      let v : Bytes = if i % 3 == 0 {
        b"a"
      } else if i % 3 == 1 {
        b"bb"
      } else {
        b"ccc"
      }
      ignore(log.append(b"k", v, i.to_int64()) catch { _ => panic() })
      before.push(v)
    }
    assert_true(log.segment_count() >= 1)
    @backend_native.flush_meta(dir, log) catch {
      _ => panic()
    }
    for seg in log.segments {
      seg.writer.close()
    }
    // Inject 1-3 random kinds of damage per round.
    s = repair_lcg(s)
    let kinds = ((s >> 5) % (3 : UInt64)).to_int() + 1
    let mut k = 0
    while k < kinds {
      s = repair_lcg(s)
      let kind = ((s >> 7) % (6 : UInt64)).to_int()
      let bases : Array[UInt64] = []
      let names = @backend_native.list_dir(dir) catch { _ => [] }
      for name in names {
        if name.has_suffix(".log") {
          let digits = name[0:name.length() - 4].to_owned()
          let v = @string.parse_uint64(digits) catch { _ => (0 : UInt64) }
          bases.push(v)
        }
      }
      bases.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
      if bases.length() == 0 {
        panic()
      }
      let seg_idx = ((s >> 11) % bases.length().to_uint64()).to_int()
      let seg_path = dir + "/" + @segment.segment_file_name(bases[seg_idx])
      if kind == 0 {
        let data = @backend_native.read_file(seg_path)
        if data.length() > 1 {
          @backend_native.write_file(
            seg_path,
            @core.slice(data, 0, data.length() / 2),
          ) catch {
            _ => panic()
          }
        }
      } else if kind == 1 {
        let data = @backend_native.read_file(seg_path)
        if data.length() > 0 {
          let head : Bytes = if data.at(0).to_int() == 0 {
            b"\x01"
          } else {
            b"\x00"
          }
          @backend_native.write_file(
            seg_path,
            head + @core.slice(data, 1, data.length()),
          ) catch {
            _ => panic()
          }
        }
      } else if kind == 2 {
        ignore(@backend_native.remove_file(dir + "/MANIFEST"))
      } else if kind == 3 {
        ignore(@backend_native.remove_file(seg_path + ".index"))
      } else if kind == 4 {
        let data = @backend_native.read_file(seg_path)
        @backend_native.write_file(seg_path, data + b"torn-junk") catch {
          _ => panic()
        }
      } else {
        ignore(@backend_native.remove_file(seg_path + ".keys"))
      }
      k = k + 1
    }
    let rep = @backend_native.repair_log_dir(dir, (60 : Int64)) catch {
      _ => panic()
    }
    match rep.still_bad {
      Some(_) => panic()
      None => ()
    }
    // Surviving records must be byte-identical to the originals.
    let rlog = @backend_native.open_log_dir(dir, (60 : Int64)) catch {
      _ => panic()
    }
    let recs = rlog.scan() catch { _ => panic() }
    for rec in recs {
      let idx = rec.offset.to_int()
      assert_true(idx < before.length())
      assert_eq(rec.value, before[idx])
    }
    // The log stays appendable at the recovered end.
    let next = rlog.next_offset()
    let tail = rlog.append(b"k", b"tail", (999 : Int64)) catch { _ => panic() }
    assert_eq(tail, next)
    @backend_native.flush_meta(dir, rlog) catch {
      _ => panic()
    }
    for seg in rlog.segments {
      seg.writer.close()
    }
    round = round + 1
  }
  clean_dir(dir)
}

///|
test "repair dry-run reports the torn-tail plan without touching anything" {
  let dir = "/tmp/moonlog_repair_dryrun"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((1_000_000 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  ignore(log.append(b"k", b"a", (0 : Int64)) catch { _ => panic() })
  ignore(log.append(b"k", b"b", (1 : Int64)) catch { _ => panic() })
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  // Inject a torn tail.
  let path = dir + "/" + @segment.segment_file_name((0 : UInt64))
  let f = @backend_native.NativeFileLog::open(path) catch { _ => panic() }
  ignore(f.append(b"junk") catch { _ => panic() })
  f.close()
  let size_before = @backend_native.file_size(path)
  let rep = @backend_native.repair_log_dir(
    dir,
    (1_000_000 : Int64),
    dry_run=true,
  ) catch {
    _ => panic()
  }
  assert_eq(rep.truncated, 1)
  assert_eq(rep.isolated, 0)
  assert_eq(rep.removed_empty, 0)
  assert_eq(rep.records, 2)
  assert_true(!rep.rebuilt_meta)
  // Nothing changed on disk: same file size, manifest still present.
  assert_eq(@backend_native.file_size(path), size_before)
  assert_true(@backend_native.file_exists(dir + "/MANIFEST"))
  // The dry-run plan matches what a real repair then does.
  let real = @backend_native.repair_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(real.truncated, 1)
  assert_eq(real.records, 2)
  // Appends continue from the repaired end.
  let rlog = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  let off = rlog.append(b"k", b"c", (2 : Int64)) catch { _ => panic() }
  assert_eq(off, (2 : UInt64))
  @backend_native.flush_meta(dir, rlog) catch {
    _ => panic()
  }
  for seg in rlog.segments {
    seg.writer.close()
  }
  clean_dir(dir)
}

///|
test "repair dry-run does not quarantine checksum-bad segments" {
  let dir = "/tmp/moonlog_repair_dryrun_iso"
  ignore(@backend_native.ensure_dir(dir))
  clean_dir(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @log.Log::new((60 : Int64), base => {
    @backend_native.open_segment_in_dir(dir, base) catch {
      _ => panic()
    }
  })
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"value", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  // Flip a byte in the first (rolled) segment so its stored checksum fails.
  let path = dir + "/" + @segment.segment_file_name((0 : UInt64))
  let data = @backend_native.read_file(path)
  let head : Bytes = if data.at(0).to_int() == 0 { b"\x01" } else { b"\x00" }
  @backend_native.write_file(path, head + @core.slice(data, 1, data.length())) catch {
    _ => panic()
  }
  let rep = @backend_native.repair_log_dir(dir, (60 : Int64), dry_run=true) catch {
    _ => panic()
  }
  assert_eq(rep.isolated, 1)
  // Nothing was quarantined: no .corrupt file, the original is still in place.
  assert_true(
    !@backend_native.file_exists(
      dir + "/" + @segment.segment_file_name((0 : UInt64)) + ".corrupt",
    ),
  )
  assert_true(@backend_native.file_exists(path))
  clean_dir(dir)
}

///|
/// Incremental backup invariant: any number of append/delete rounds followed
/// by an incremental `backup_log_dir` pass leaves a backup that restores into
/// an equivalent log — offsets, timestamps, kinds and payloads included —
/// even when the source compacts and its old segment files vanish (the
/// backup must prune its stale copies).
test "incremental backup property: repeated passes track the source" {
  let src = "/tmp/moonlog_incbk_src"
  let dst = "/tmp/moonlog_incbk_dst"
  let rst = "/tmp/moonlog_incbk_rst"
  ignore(@backend_native.ensure_dir(src))
  ignore(@backend_native.ensure_dir(dst))
  ignore(@backend_native.ensure_dir(rst))
  clean_dir(src)
  clean_dir(dst)
  clean_dir(rst)
  let mut s : UInt64 = 0xC0FFEEF00D
  let mut ts : Int64 = 0
  let mut round = 0
  while round < 8 {
    // Random writes accumulate on the source (the backup keeps growing).
    let log = @backend_native.open_log_dir(src, (60 : Int64)) catch {
      _ => panic()
    }
    s = repair_lcg(s)
    let n_writes = ((s >> 3) % (6 : UInt64)).to_int() + 1
    let mut w = 0
    while w < n_writes {
      s = repair_lcg(s)
      let slot = ((s >> 5) % (4 : UInt64)).to_int() * 4
      let key = @core.slice(b"key0key1key2key3", slot, slot + 4)
      ts = ts + 1
      if (s >> 9) % (4 : UInt64) == (0 : UInt64) {
        ignore(log.delete(key, ts) catch { _ => panic() })
      } else {
        let v = if (s >> 7) % (2 : UInt64) == (0 : UInt64) {
          b"even-payload"
        } else {
          b"odd"
        }
        ignore(log.append(key, v, ts) catch { _ => panic() })
      }
      w = w + 1
    }
    @backend_native.flush_meta(src, log) catch {
      _ => panic()
    }
    // Every third round folds the source: old segment files vanish and
    // offsets renumber, so the backup must prune its stale copies.
    if round % 3 == 2 {
      ignore(
        log.compact(on_drop=seg => {
          @backend_native.remove_segment_files(src, seg.base_offset)
          seg.writer.close()
        }) catch {
          _ => panic()
        },
      )
      @backend_native.flush_meta(src, log) catch {
        _ => panic()
      }
    }
    for seg in log.segments {
      seg.writer.close()
    }
    // Incremental pass over the accumulating backup, then the restore must
    // match the source record for record.
    ignore(@backend_native.backup_log_dir(src, dst) catch { _ => panic() })
    clean_dir(rst)
    ignore(@backend_native.restore_log_dir(dst, rst) catch { _ => panic() })
    let s_log = @backend_native.open_log_dir(src, (60 : Int64)) catch {
      _ => panic()
    }
    let r_log = @backend_native.open_log_dir(rst, (60 : Int64)) catch {
      _ => panic()
    }
    let s_recs = s_log.scan() catch { _ => panic() }
    let r_recs = r_log.scan() catch { _ => panic() }
    assert_eq(r_recs.length(), s_recs.length())
    let mut i = 0
    while i < s_recs.length() {
      assert_eq(r_recs[i], s_recs[i])
      i = i + 1
    }
    for seg in s_log.segments {
      seg.writer.close()
    }
    for seg in r_log.segments {
      seg.writer.close()
    }
    round = round + 1
  }
  clean_dir(src)
  clean_dir(dst)
  clean_dir(rst)
}

///|
/// Export/import roundtrip invariant: a random log (puts and tombstones over
/// a small key space) exported to a record stream and replayed into a fresh
/// directory yields the same records in the same order — offsets (the source
/// is contiguous), timestamps, kinds and payloads included.
test "export/import roundtrip property" {
  let src = "/tmp/moonlog_rt_src"
  let dst = "/tmp/moonlog_rt_dst"
  ignore(@backend_native.ensure_dir(src))
  ignore(@backend_native.ensure_dir(dst))
  clean_dir(src)
  clean_dir(dst)
  let mut s : UInt64 = 0x1234ABCD5E
  let mut ts : Int64 = 0
  let mut round = 0
  while round < 6 {
    let log = @backend_native.open_log_dir(src, (60 : Int64)) catch {
      _ => panic()
    }
    s = repair_lcg(s)
    let n_writes = ((s >> 3) % (10 : UInt64)).to_int() + 3
    let mut w = 0
    while w < n_writes {
      s = repair_lcg(s)
      let slot = ((s >> 5) % (4 : UInt64)).to_int() * 4
      let key = @core.slice(b"key0key1key2key3", slot, slot + 4)
      ts = ts + 1
      if (s >> 9) % (4 : UInt64) == (0 : UInt64) {
        ignore(log.delete(key, ts) catch { _ => panic() })
      } else {
        let v = if (s >> 7) % (2 : UInt64) == (0 : UInt64) {
          b"even-payload"
        } else {
          b"odd"
        }
        ignore(log.append(key, v, ts) catch { _ => panic() })
      }
      w = w + 1
    }
    @backend_native.flush_meta(src, log) catch {
      _ => panic()
    }
    // Roundtrip: export the whole stream, replay it into a fresh directory.
    let data = log.export_bytes() catch { _ => panic() }
    clean_dir(dst)
    let fresh = @backend_native.open_log_dir(dst, (60 : Int64)) catch {
      _ => panic()
    }
    let imported = fresh.import_bytes(data) catch { _ => panic() }
    let src_recs = log.scan() catch { _ => panic() }
    let dst_recs = fresh.scan() catch { _ => panic() }
    assert_eq(imported, src_recs.length())
    assert_eq(dst_recs.length(), src_recs.length())
    let mut i = 0
    while i < src_recs.length() {
      assert_eq(dst_recs[i], src_recs[i])
      i = i + 1
    }
    @backend_native.flush_meta(dst, fresh) catch {
      _ => panic()
    }
    for seg in log.segments {
      seg.writer.close()
    }
    for seg in fresh.segments {
      fresh.flush()
      seg.writer.close()
    }
    round = round + 1
  }
  clean_dir(src)
  clean_dir(dst)
}
