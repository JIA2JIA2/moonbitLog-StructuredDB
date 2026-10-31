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
