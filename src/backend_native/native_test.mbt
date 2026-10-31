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
