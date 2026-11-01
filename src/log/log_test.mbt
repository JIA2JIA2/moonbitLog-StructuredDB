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

///|
test "manifest roundtrips through encode/decode" {
  let m : @log.Manifest = {
    roll_size: (1024 : Int64),
    next_offset: (42 : UInt64),
    segment_bases: [(0 : UInt64), (10 : UInt64), (20 : UInt64)],
    segment_sizes: [(100 : Int64), (200 : Int64), (300 : Int64)],
  }
  let bytes = m.encode()
  let d = @log.decode_manifest(bytes) catch { _ => panic() }
  assert_eq(d.roll_size, (1024 : Int64))
  assert_eq(d.next_offset, (42 : UInt64))
  assert_eq(d.segment_bases.length(), 3)
  assert_eq(d.segment_bases[0], (0 : UInt64))
  assert_eq(d.segment_bases[2], (20 : UInt64))
  assert_eq(d.segment_sizes.length(), 3)
  assert_eq(d.segment_sizes[0], (100 : Int64))
  assert_eq(d.segment_sizes[2], (300 : Int64))
}

///|
test "manifest decode rejects corrupt bytes" {
  let m : @log.Manifest = {
    roll_size: (8 : Int64),
    next_offset: (1 : UInt64),
    segment_bases: [(0 : UInt64)],
    segment_sizes: [(16 : Int64)],
  }
  let bytes = m.encode()
  let broken = @core.slice(bytes, 0, bytes.length() - 1) + b"\x00"
  let mut raised = false
  try {
    let _ = @log.decode_manifest(broken)
  } catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "log for_each aggregates across segments" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (100 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 8; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  let collected : Array[@core.Record] = []
  log.for_each((0 : UInt64), log.next_offset(), rec => collected.push(rec))
  assert_eq(collected.length(), 8)
  let mut i = 0
  while i < 8 {
    assert_eq(collected[i].offset.to_int(), i)
    i = i + 1
  }
}

///|
test "key index tracks latest puts and honours tombstones" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  ignore(log.append(b"a", b"1", (0 : Int64)) catch { _ => panic() })
  ignore(log.append(b"a", b"2", (1 : Int64)) catch { _ => panic() })
  ignore(log.append(b"b", b"3", (2 : Int64)) catch { _ => panic() })
  ignore(log.delete(b"b", (3 : Int64)) catch { _ => panic() })
  ignore(log.append(b"c", b"4", (4 : Int64)) catch { _ => panic() })
  let idx = log.build_key_index() catch { _ => panic() }
  assert_eq(idx.size(), 2)
  let a = log.get_latest(idx, b"a") catch { _ => panic() }
  match a {
    Some(rec) => assert_eq(rec.value, b"2")
    None => panic()
  }
  let b = log.get_latest(idx, b"b") catch { _ => panic() }
  match b {
    Some(_) => panic()
    None => ()
  }
  let c = log.get_latest(idx, b"c") catch { _ => panic() }
  match c {
    Some(rec) => assert_eq(rec.value, b"4")
    None => panic()
  }
}

///|
test "snapshot folds to latest puts with renumbered offsets" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  ignore(log.append(b"a", b"1", (0 : Int64)) catch { _ => panic() })
  ignore(log.append(b"a", b"2", (1 : Int64)) catch { _ => panic() })
  ignore(log.append(b"b", b"3", (2 : Int64)) catch { _ => panic() })
  ignore(log.delete(b"b", (3 : Int64)) catch { _ => panic() })
  ignore(log.append(b"c", b"4", (4 : Int64)) catch { _ => panic() })
  let snap = log.snapshot() catch { _ => panic() }
  assert_eq(snap.length(), 2)
  assert_eq(snap[0].offset, (0 : UInt64))
  assert_eq(snap[0].key, b"a")
  assert_eq(snap[0].value, b"2")
  assert_true(!snap[0].is_delete())
  assert_eq(snap[1].offset, (1 : UInt64))
  assert_eq(snap[1].key, b"c")
  assert_eq(snap[1].value, b"4")
}

///|
test "retain_max_bytes drops oldest segments until under the limit" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (100 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 20; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 3)
  let mut total : Int64 = 0
  for seg in log.segments {
    total = total + seg.size
  }
  let limit = total / 2
  let dropped_bases : Array[UInt64] = []
  let dropped = log.retain_max_bytes(limit, seg => {
    dropped_bases.push(seg.base_offset)
  })
  assert_true(dropped >= 1)
  assert_eq(dropped, dropped_bases.length())
  let mut remaining : Int64 = 0
  for seg in log.segments {
    remaining = remaining + seg.size
  }
  assert_true(remaining <= limit || log.segment_count() == 1)
}

///|
test "sync policy Always flushes on append" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
    sync=@log.SyncPolicy::Always,
  )
  ignore(log.append(b"k", b"v", (0 : Int64)) catch { _ => panic() })
  assert_eq(log.count(), 1)
  let recs = log.scan() catch { _ => panic() }
  assert_eq(recs.length(), 1)
}

///|
test "log compact folds to the live view and drops old segments" {
  let dropped : Array[UInt64] = []
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (60 : Int64),
    base => mem_segment(base),
  )
  ignore(log.append(b"a", b"1", (1 : Int64)) catch { _ => panic() })
  ignore(log.append(b"a", b"2", (2 : Int64)) catch { _ => panic() })
  ignore(log.append(b"b", b"3", (3 : Int64)) catch { _ => panic() })
  ignore(log.append(b"c", b"4", (4 : Int64)) catch { _ => panic() })
  ignore(log.delete(b"c", (5 : Int64)) catch { _ => panic() })
  let before = log.segment_count()
  assert_true(before >= 2)
  let n = log.compact(on_drop=seg => dropped.push(seg.base_offset)) catch {
    _ => panic()
  }
  assert_eq(n, 2)
  assert_eq(dropped.length(), before)
  assert_eq(log.segment_count(), 1)
  assert_eq(log.count(), 2)
  assert_eq(log.next_offset(), (2 : UInt64))
  let recs = log.scan() catch { _ => panic() }
  assert_eq(recs.length(), 2)
  assert_eq(recs[0].key, b"a")
  assert_eq(recs[0].value, b"2")
  assert_eq(recs[1].key, b"b")
  let idx = log.build_key_index() catch { _ => panic() }
  assert_eq(idx.size(), 2)
  let gone = log.get_latest(idx, b"c") catch { _ => panic() }
  match gone {
    Some(_) => panic()
    None => ()
  }
}

///|
test "retain_before drops segments whose last record predates the cutoff" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (60 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 6; i = i + 1 {
    ignore(log.append(b"k", b"v", (i * 10).to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  let before = log.segment_count()
  let dropped_bases : Array[UInt64] = []
  let dropped = log.retain_before((25 : Int64), seg => {
    dropped_bases.push(seg.base_offset)
  }) catch {
    _ => panic()
  }
  assert_eq(dropped, dropped_bases.length())
  assert_true(dropped >= 1)
  assert_true(log.segment_count() < before)
  let recs = log.scan() catch { _ => panic() }
  assert_true(recs.length() >= 1)
  assert_eq(recs[recs.length() - 1].timestamp, (50 : Int64))
}

///|
test "append_batch assigns contiguous offsets across rolls" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (60 : Int64),
    base => mem_segment(base),
  )
  let batch : Array[(Bytes, Bytes, Int64)] = [
    (b"a", b"1", (0 : Int64)),
    (b"b", b"2", (1 : Int64)),
    (b"c", b"3", (2 : Int64)),
    (b"d", b"4", (3 : Int64)),
  ]
  let offsets = log.append_batch(batch) catch { _ => panic() }
  assert_eq(offsets.length(), 4)
  assert_eq(offsets[0], (0 : UInt64))
  assert_eq(offsets[3], (3 : UInt64))
  assert_eq(log.count(), 4)
  assert_true(log.segment_count() >= 2)
  let recs = log.scan() catch { _ => panic() }
  assert_eq(recs[3].value, b"4")
}

///|
test "verify reports a healthy multi-segment log" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (60 : Int64),
    base => mem_segment(base),
  )
  for i = 0; i < 6; i = i + 1 {
    ignore(log.append(b"k", b"v", i.to_int64()) catch { _ => panic() })
  }
  assert_true(log.segment_count() >= 2)
  let report = log.verify()
  assert_eq(report.segments, log.segment_count())
  assert_eq(report.records, 6)
  match report.first_bad_offset {
    Some(_) => panic()
    None => ()
  }
}

///|
test "verify on an empty log is healthy" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (60 : Int64),
    base => mem_segment(base),
  )
  let report = log.verify()
  assert_eq(report.segments, 0)
  assert_eq(report.records, 0)
  match report.first_bad_offset {
    Some(_) => panic()
    None => ()
  }
}

///|
/// A writer that forwards bytes to an in-memory log but counts flush (fsync)
/// calls, letting tests observe the SyncPolicy behaviour.
struct FlushSpy {
  mem : @backend_mem.MemLog
  counter : FlushCounter
}

///|
struct FlushCounter {
  mut n : Int32
}

///|
impl @io.LogWriter for FlushSpy with fn append(self, chunk) {
  self.mem.append(chunk)
}

///|
impl @io.LogWriter for FlushSpy with fn flush(self) {
  self.counter.n = self.counter.n + 1
}

///|
impl @io.LogReader for FlushSpy with fn read_at(self, offset, len) {
  self.mem.read_at(offset, len)
}

///|
impl @io.LogReader for FlushSpy with fn length(self) {
  self.mem.length()
}

///|
fn spy_segment(
  counter : FlushCounter,
  base : UInt64,
) -> @segment.Segment[FlushSpy, FlushSpy] {
  let spy = { mem: @backend_mem.MemLog::new(), counter, }
  @segment.Segment::new(spy, spy, base)
}

///|
test "sync policy Batch defers fsync to batch end or explicit flush" {
  // Always: one fsync per appended record.
  let always_counter : FlushCounter = { n: 0, }
  let always_log : @log.Log[FlushSpy, FlushSpy] = @log.Log::new(
    (1_000_000 : Int64),
    base => spy_segment(always_counter, base),
    sync=@log.SyncPolicy::Always,
  )
  ignore(always_log.append(b"a", b"1", (0 : Int64)) catch { _ => panic() })
  ignore(always_log.append(b"b", b"2", (1 : Int64)) catch { _ => panic() })
  assert_eq(always_counter.n, 2)

  // Batch: individual appends do not flush; the batch tail flushes once.
  let batch_counter : FlushCounter = { n: 0, }
  let batch_log : @log.Log[FlushSpy, FlushSpy] = @log.Log::new(
    (1_000_000 : Int64),
    base => spy_segment(batch_counter, base),
    sync=@log.SyncPolicy::Batch,
  )
  ignore(batch_log.append(b"a", b"1", (0 : Int64)) catch { _ => panic() })
  assert_eq(batch_counter.n, 0)
  let batch : Array[(Bytes, Bytes, Int64)] = [
    (b"b", b"2", (1 : Int64)),
    (b"c", b"3", (2 : Int64)),
  ]
  ignore(batch_log.append_batch(batch) catch { _ => panic() })
  assert_eq(batch_counter.n, 1)
  batch_log.flush() catch {
    _ => panic()
  }
  assert_eq(batch_counter.n, 2)

  // Never: nothing flushes unless the caller asks.
  let never_counter : FlushCounter = { n: 0, }
  let never_log : @log.Log[FlushSpy, FlushSpy] = @log.Log::new(
    (1_000_000 : Int64),
    base => spy_segment(never_counter, base),
    sync=@log.SyncPolicy::Never,
  )
  ignore(never_log.append(b"a", b"1", (0 : Int64)) catch { _ => panic() })
  ignore(never_log.append_batch(batch) catch { _ => panic() })
  assert_eq(never_counter.n, 0)
  never_log.flush() catch {
    _ => panic()
  }
  assert_eq(never_counter.n, 1)

  // Reading the batch log exercises the LogReader side of FlushSpy.
  let recs = batch_log.scan() catch { _ => panic() }
  assert_eq(recs.length(), 3)
}

///|
test "get_latest_at honours ttl while scan_live filters expired keys" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  ignore(log.append(b"a", b"1", (1_000 : Int64)) catch { _ => panic() })
  ignore(log.append(b"b", b"2", (5_000 : Int64)) catch { _ => panic() })
  let index = log.build_key_index() catch { _ => panic() }

  // now = 6000, ttl = 2000: `a` (age 5000) expired, `b` (age 1000) still live.
  let a = log.get_latest_at(index, b"a", (6_000 : Int64), (2_000 : Int64)) catch {
    _ => panic()
  }
  match a {
    Some(_) => panic()
    None => ()
  }
  let b = log.get_latest_at(index, b"b", (6_000 : Int64), (2_000 : Int64)) catch {
    _ => panic()
  }
  match b {
    Some(rec) => assert_eq(rec.value, b"2")
    None => panic()
  }
  let live = log.scan_live((6_000 : Int64), (2_000 : Int64)) catch {
    _ => panic()
  }
  assert_eq(live.length(), 1)
  assert_eq(live[0].key, b"b")
}

///|
test "export/import round-trips the record stream" {
  let src : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  ignore(src.append(b"a", b"1", (1_000 : Int64)) catch { _ => panic() })
  ignore(src.append(b"b", b"2", (2_000 : Int64)) catch { _ => panic() })
  ignore(src.delete(b"a", (3_000 : Int64)) catch { _ => panic() })
  let blob = src.export_bytes() catch { _ => panic() }

  let dst : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  let n = dst.import_bytes(blob) catch { _ => panic() }
  assert_eq(n, 3)
  assert_eq(dst.count(), 3)
  let src_recs = src.scan() catch { _ => panic() }
  let dst_recs = dst.scan() catch { _ => panic() }
  assert_eq(src_recs.length(), dst_recs.length())
  for i = 0; i < src_recs.length(); i = i + 1 {
    assert_eq(src_recs[i].offset, dst_recs[i].offset)
    assert_eq(src_recs[i].timestamp, dst_recs[i].timestamp)
    assert_eq(src_recs[i].key, dst_recs[i].key)
    assert_eq(src_recs[i].value, dst_recs[i].value)
    assert_eq(src_recs[i].kind, dst_recs[i].kind)
  }
  // The imported tombstone still hides the key.
  let idx = dst.build_key_index() catch { _ => panic() }
  let gone = dst.get_latest(idx, b"a") catch { _ => panic() }
  match gone {
    Some(_) => panic()
    None => ()
  }
}

///|
test "sync policy Batch fsyncs every segment at the batch tail" {
  let counter : FlushCounter = { n: 0, }
  let log : @log.Log[FlushSpy, FlushSpy] = @log.Log::new(
    (60 : Int64),
    base => spy_segment(counter, base),
    sync=@log.SyncPolicy::Batch,
  )
  let batch : Array[(Bytes, Bytes, Int64)] = [
    (b"a", b"1", (0 : Int64)),
    (b"b", b"2", (1 : Int64)),
    (b"c", b"3", (2 : Int64)),
    (b"d", b"4", (3 : Int64)),
  ]
  ignore(log.append_batch(batch) catch { _ => panic() })
  let segs = log.segment_count()
  assert_true(segs >= 2)
  assert_eq(counter.n, segs)
}

///|
test "scan_prefix returns sorted live keys under a prefix" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  ignore(log.append(b"user:2", b"b", (0 : Int64)) catch { _ => panic() })
  ignore(log.append(b"user:1", b"a", (1 : Int64)) catch { _ => panic() })
  ignore(log.append(b"order:1", b"d", (2 : Int64)) catch { _ => panic() })
  ignore(log.append(b"user:2", b"b2", (3 : Int64)) catch { _ => panic() })
  ignore(log.delete(b"user:1", (4 : Int64)) catch { _ => panic() })
  let recs = log.scan_prefix(b"user") catch { _ => panic() }
  assert_eq(recs.length(), 1)
  assert_eq(recs[0].key, b"user:2")
  assert_eq(recs[0].value, b"b2")
  let all = log.scan_prefix(b"") catch { _ => panic() }
  assert_eq(all.length(), 2)
  assert_eq(all[0].key, b"order:1")
  assert_eq(all[1].key, b"user:2")
}

///|
test "get_latest_bloom matches the key index view" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_000_000 : Int64),
    base => mem_segment(base),
  )
  ignore(log.append(b"a", b"1", (0 : Int64)) catch { _ => panic() })
  ignore(log.append(b"b", b"2", (1 : Int64)) catch { _ => panic() })
  ignore(log.append(b"a", b"3", (2 : Int64)) catch { _ => panic() })
  ignore(log.delete(b"b", (3 : Int64)) catch { _ => panic() })
  let a = log.get_latest_bloom(b"a") catch { _ => panic() }
  match a {
    Some(rec) => assert_eq(rec.value, b"3")
    None => panic()
  }
  let b = log.get_latest_bloom(b"b") catch { _ => panic() }
  match b {
    Some(_) => panic()
    None => ()
  }
  let missing = log.get_latest_bloom(b"never-inserted") catch { _ => panic() }
  match missing {
    Some(_) => panic()
    None => ()
  }
}
