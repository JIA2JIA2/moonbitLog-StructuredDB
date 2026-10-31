///|
test "segment append assigns monotonic offsets and scans back" {
  let log = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    log,
    log,
    (100 : UInt64),
  )
  let o1 = seg.append(b"k1", b"v1", (1 : Int64)) catch { _ => panic() }
  let o2 = seg.append(b"k2", b"v2", (2 : Int64)) catch { _ => panic() }
  let o3 = seg.append(b"k3", b"v3", (3 : Int64)) catch { _ => panic() }
  assert_eq(o1, (100 : UInt64))
  assert_eq(o2, (101 : UInt64))
  assert_eq(o3, (102 : UInt64))
  assert_eq(seg.count(), 3)
  let raw = seg.read_raw((0 : Int64), seg.byte_size().to_int()) catch {
    _ => panic()
  }
  assert_eq(raw.length().to_int64(), seg.byte_size())
  let recs = seg.scan() catch { _ => panic() }
  assert_eq(recs.length(), 3)
  assert_eq(recs[0].offset, (100 : UInt64))
  assert_eq(recs[0].value, b"v1")
  assert_eq(recs[2].offset, (102 : UInt64))
  assert_eq(recs[2].value, b"v3")
}

///|
test "segment get by logical offset" {
  let log = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    log,
    log,
    (0 : UInt64),
  )
  let _ = seg.append(b"a", b"one", (10 : Int64)) catch { _ => panic() }
  let _ = seg.append(b"b", b"two", (20 : Int64)) catch { _ => panic() }
  let hit = seg.get((1 : UInt64)) catch { _ => panic() }
  match hit {
    Some(rec) => assert_eq(rec.value, b"two")
    None => panic()
  }
  let miss = seg.get((99 : UInt64)) catch { _ => panic() }
  match miss {
    Some(_) => panic()
    None => ()
  }
}

///|
test "empty segment scans to empty array" {
  let log = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    log,
    log,
    (0 : UInt64),
  )
  let recs = seg.scan() catch { _ => panic() }
  assert_eq(recs.length(), 0)
  assert_eq(seg.count(), 0)
  assert_eq(seg.byte_size(), (0 : Int64))
}

///|
test "segment file name is zero padded for lexical ordering" {
  assert_eq(@segment.segment_file_name((7 : UInt64)), "0000000000000007.log")
  assert_eq(@segment.segment_file_name((0 : UInt64)), "0000000000000000.log")
}

///|
fn indexed_mem_segment(
  base : UInt64,
  interval : Int32,
) -> @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] {
  let store = @backend_mem.MemLog::new()
  @segment.Segment::new_with_index_interval(store, store, base, interval)
}

///|
test "sparse index samples one entry per interval and still finds any offset" {
  let seg = indexed_mem_segment((10 : UInt64), 2)
  for i = 0; i < 10; i = i + 1 {
    ignore(seg.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  assert_eq(seg.count(), 10)
  assert_eq(seg.index_interval(), 2)
  assert_eq(seg.index.length(), 5)
  assert_eq(seg.index.entry(0).record_index, (0 : UInt64))
  assert_eq(seg.index.entry(1).record_index, (2 : UInt64))
  assert_eq(seg.index.entry(4).record_index, (8 : UInt64))
  for i = 0; i < 10; i = i + 1 {
    let hit = seg.get((10 + i).to_uint64()) catch { _ => panic() }
    match hit {
      Some(rec) => assert_eq(rec.offset.to_int(), 10 + i)
      None => panic()
    }
  }
  let below = seg.get((9 : UInt64)) catch { _ => panic() }
  match below {
    Some(_) => panic()
    None => ()
  }
  let beyond = seg.get((20 : UInt64)) catch { _ => panic() }
  match beyond {
    Some(_) => panic()
    None => ()
  }
}

///|
test "sparse index floor returns the greatest lower bound" {
  let idx = @segment.SparseIndex::new(4)
  idx.push((0 : UInt64), (0 : Int64))
  idx.push((4 : UInt64), (40 : Int64))
  idx.push((8 : UInt64), (80 : Int64))
  let f0 = idx.floor((0 : UInt64))
  match f0 {
    Some(e) => assert_eq(e.position, (0 : Int64))
    None => panic()
  }
  let f5 = idx.floor((5 : UInt64))
  match f5 {
    Some(e) => {
      assert_eq(e.record_index, (4 : UInt64))
      assert_eq(e.position, (40 : Int64))
    }
    None => panic()
  }
  let f99 = idx.floor((99 : UInt64))
  match f99 {
    Some(e) => assert_eq(e.record_index, (8 : UInt64))
    None => panic()
  }
}

///|
test "scan_range honours half-open bounds and clamps to segment" {
  let seg = indexed_mem_segment((0 : UInt64), 2)
  for i = 0; i < 8; i = i + 1 {
    ignore(seg.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  let recs = seg.scan_range((2 : UInt64), (5 : UInt64)) catch { _ => panic() }
  assert_eq(recs.length(), 3)
  assert_eq(recs[0].offset.to_int(), 2)
  assert_eq(recs[2].offset.to_int(), 4)
  let whole = seg.scan_range((0 : UInt64), (100 : UInt64)) catch {
    _ => panic()
  }
  assert_eq(whole.length(), 8)
  let empty = seg.scan_range((5 : UInt64), (5 : UInt64)) catch { _ => panic() }
  assert_eq(empty.length(), 0)
  let past = seg.scan_range((100 : UInt64), (200 : UInt64)) catch {
    _ => panic()
  }
  assert_eq(past.length(), 0)
}

///|
test "rebuild_index restores an index from persisted bytes" {
  let store = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (0 : UInt64),
  )
  for i = 0; i < 6; i = i + 1 {
    ignore(seg.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  let seg2 : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (0 : UInt64),
  )
  assert_eq(seg2.count(), 0)
  let n = seg2.rebuild_index() catch { _ => panic() }
  assert_eq(n, 6)
  assert_eq(seg2.count(), 6)
  assert_eq(seg2.next_offset, (6 : UInt64))
  let hit = seg2.get((4 : UInt64)) catch { _ => panic() }
  match hit {
    Some(rec) => assert_eq(rec.value, b"v")
    None => panic()
  }
}

///|
test "recover truncates a short torn tail" {
  let store = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (0 : UInt64),
  )
  ignore(seg.append(b"k", b"v0", (0 : Int64)) catch { _ => panic() })
  ignore(seg.append(b"k", b"v1", (1 : Int64)) catch { _ => panic() })
  let good = seg.byte_size()
  ignore(store.append(b"ab") catch { _ => panic() })
  assert_true(store.length() > good)
  let n = seg.recover() catch { _ => panic() }
  assert_eq(n, 2)
  assert_eq(seg.count(), 2)
  assert_eq(seg.byte_size(), good)
  assert_eq(store.length(), good)
  let recs = seg.scan() catch { _ => panic() }
  assert_eq(recs.length(), 2)
}

///|
test "recover truncates a tail whose declared length overruns the file" {
  let store = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (0 : UInt64),
  )
  ignore(seg.append(b"k", b"v0", (0 : Int64)) catch { _ => panic() })
  let good = seg.byte_size()
  ignore(store.append(b"junk") catch { _ => panic() })
  let n = seg.recover() catch { _ => panic() }
  assert_eq(n, 1)
  assert_eq(seg.byte_size(), good)
  assert_eq(store.length(), good)
  let hit = seg.get((0 : UInt64)) catch { _ => panic() }
  match hit {
    Some(rec) => assert_eq(rec.value, b"v0")
    None => panic()
  }
}

///|
test "sparse index interval normalises to at least one" {
  assert_eq(@segment.SparseIndex::new((0 : Int32)).interval, 1)
  assert_eq(@segment.SparseIndex::new((-4 : Int32)).interval, 1)
  assert_eq(@segment.SparseIndex::new((8 : Int32)).interval, 8)
}

///|
test "get honours segment offset boundaries" {
  let seg = indexed_mem_segment((10 : UInt64), (4 : Int32))
  for i = 0; i < 3; i = i + 1 {
    ignore(seg.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  let lo = seg.get((10 : UInt64)) catch { _ => panic() }
  match lo {
    Some(rec) => assert_eq(rec.offset.to_int(), 10)
    None => panic()
  }
  let hi = seg.get((12 : UInt64)) catch { _ => panic() }
  match hi {
    Some(rec) => assert_eq(rec.offset.to_int(), 12)
    None => panic()
  }
  let below = seg.get((9 : UInt64)) catch { _ => panic() }
  match below {
    Some(_) => panic()
    None => ()
  }
  let above = seg.get((13 : UInt64)) catch { _ => panic() }
  match above {
    Some(_) => panic()
    None => ()
  }
}
