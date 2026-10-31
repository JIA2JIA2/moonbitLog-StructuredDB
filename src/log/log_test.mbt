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
