///|
/// Helper: a segment whose writer and reader share one in-memory store.
fn mem_segment(
  base : UInt64,
) -> @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] {
  let store = @backend_mem.MemLog::new()
  @segment.Segment::new(store, store, base)
}

///|
test "log rolls segments and preserves global offsets" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (100 : Int64),
    base => mem_segment(base),
  )
  let o0 = log.append(b"k0", b"v0", (0 : Int64)) catch { _ => panic() }
  let o1 = log.append(b"k1", b"v1", (1 : Int64)) catch { _ => panic() }
  let o2 = log.append(b"k2", b"v2", (2 : Int64)) catch { _ => panic() }
  let o3 = log.append(b"k3", b"v3", (3 : Int64)) catch { _ => panic() }
  let o4 = log.append(b"k4", b"v4", (4 : Int64)) catch { _ => panic() }
  assert_eq(o0, (0 : UInt64))
  assert_eq(o1, (1 : UInt64))
  assert_eq(o2, (2 : UInt64))
  assert_eq(o3, (3 : UInt64))
  assert_eq(o4, (4 : UInt64))
  assert_eq(log.count(), 5)
  assert_true(log.segment_count() >= 2)
  assert_eq(log.next_offset(), (5 : UInt64))
  let recs = log.scan() catch { _ => panic() }
  assert_eq(recs.length(), 5)
  assert_eq(recs[0].offset, (0 : UInt64))
  assert_eq(recs[4].offset, (4 : UInt64))
  assert_eq(recs[4].value, b"v4")
  let hit = log.get((3 : UInt64)) catch { _ => panic() }
  match hit {
    Some(rec) => assert_eq(rec.value, b"v3")
    None => panic()
  }
  let miss = log.get((99 : UInt64)) catch { _ => panic() }
  match miss {
    Some(_) => panic()
    None => ()
  }
}

///|
test "empty log has no segments and empty scan" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1024 : Int64),
    base => mem_segment(base),
  )
  assert_eq(log.count(), 0)
  assert_eq(log.segment_count(), 0)
  let recs = log.scan() catch { _ => panic() }
  assert_eq(recs.length(), 0)
}

///|
test "single large segment holds all records when under roll size" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 20; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  assert_eq(log.count(), 20)
  assert_eq(log.segment_count(), 1)
  assert_eq(log.next_offset(), (20 : UInt64))
}

///|
test "scan_range spans segments and returns records in order" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (100 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  let recs = log.scan_range((3 : UInt64), (6 : UInt64)) catch { _ => panic() }
  assert_eq(recs.length(), 3)
  assert_eq(recs[0].offset.to_int(), 3)
  assert_eq(recs[1].offset.to_int(), 4)
  assert_eq(recs[2].offset.to_int(), 5)
  let empty = log.scan_range((6 : UInt64), (6 : UInt64)) catch { _ => panic() }
  assert_eq(empty.length(), 0)
}

///|
test "log get binary-searches the owning segment" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (100 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  let first = log.get((0 : UInt64)) catch { _ => panic() }
  match first {
    Some(rec) => assert_eq(rec.offset.to_int(), 0)
    None => panic()
  }
  let last = log.get((7 : UInt64)) catch { _ => panic() }
  match last {
    Some(rec) => assert_eq(rec.offset.to_int(), 7)
    None => panic()
  }
  let miss = log.get((99 : UInt64)) catch { _ => panic() }
  match miss {
    Some(_) => panic()
    None => ()
  }
}

///|
test "delete appends tombstones without rewriting history" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  ignore(log.append(b"k", b"v", (0 : Int64)) catch { _ => panic() })
  ignore(log.delete(b"k", (1 : Int64)) catch { _ => panic() })
  ignore(log.append(b"k", b"v2", (2 : Int64)) catch { _ => panic() })
  let recs = log.scan() catch { _ => panic() }
  assert_eq(recs.length(), 3)
  assert_true(!recs[0].is_delete())
  assert_true(recs[1].is_delete())
  assert_eq(recs[1].value.length(), 0)
  assert_true(!recs[2].is_delete())
}

///|
test "drop_before removes fully old segments and reports them" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (100 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 10; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  let before = log.segment_count()
  let last_base = log.segments[log.segments.length() - 1].base_offset
  let dropped_bases : Array[UInt64] = []
  let dropped = log.drop_before(last_base, seg => {
    dropped_bases.push(seg.base_offset)
  })
  assert_eq(dropped, dropped_bases.length())
  assert_true(dropped >= 1)
  assert_eq(log.segment_count(), before - dropped)
  let remaining = log.scan() catch { _ => panic() }
  assert_eq(remaining.length(), 10 - last_base.to_int())
}

///|
test "retain_last keeps only the newest segments" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (100 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 10; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  let before = log.segment_count()
  assert_true(before >= 2)
  let dropped = log.retain_last(1, _seg => ())
  assert_eq(dropped, before - 1)
  assert_eq(log.segment_count(), 1)
}

///|
test "consumer cursor polls in batches and advances" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 7; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  let cur = @log.ConsumerCursor::new((0 : UInt64))
  let b1 = cur.poll(log, 3) catch { _ => panic() }
  assert_eq(b1.length(), 3)
  assert_eq(cur.position(), (3 : UInt64))
  let b2 = cur.poll(log, 3) catch { _ => panic() }
  assert_eq(b2.length(), 3)
  assert_eq(b2[0].offset.to_int(), 3)
  assert_eq(cur.position(), (6 : UInt64))
  let b3 = cur.poll(log, 3) catch { _ => panic() }
  assert_eq(b3.length(), 1)
  assert_eq(cur.position(), (7 : UInt64))
  let b4 = cur.poll(log, 3) catch { _ => panic() }
  assert_eq(b4.length(), 0)
  assert_eq(cur.position(), (7 : UInt64))
}

///|
test "retain_last with zero keeps the active segment" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (100 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 10; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  let before = log.segment_count()
  assert_true(before >= 2)
  let dropped = log.retain_last(0, _seg => ())
  assert_eq(dropped, before - 1)
  assert_eq(log.segment_count(), 1)
}

///|
test "cursor poll with non-positive limit returns nothing" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 5; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  let cur = @log.ConsumerCursor::new((0 : UInt64))
  let z = cur.poll(log, 0) catch { _ => panic() }
  assert_eq(z.length(), 0)
  let n = cur.poll(log, -2) catch { _ => panic() }
  assert_eq(n.length(), 0)
  assert_eq(cur.position(), (0 : UInt64))
}

///|
test "empty log get and scan_range return nothing" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1024 : Int64),
    base => mem_segment(base),
  )
  let g = log.get((0 : UInt64)) catch { _ => panic() }
  match g {
    Some(_) => panic()
    None => ()
  }
  let recs = log.scan_range((0 : UInt64), (10 : UInt64)) catch { _ => panic() }
  assert_eq(recs.length(), 0)
}
