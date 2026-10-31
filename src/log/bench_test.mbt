///|
fn bench_new_log(
  roll : Int64,
) -> @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] {
  @log.Log::new(roll, base => {
    let store = @backend_mem.MemLog::new()
    @segment.Segment::new(store, store, base)
  })
}

///|
fn bench_fill_append(
  log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog],
  n : Int32,
) -> Unit {
  for i = 0; i < n; i = i + 1 {
    ignore(log.append(b"key", b"value", i.to_int64()) catch { _ => panic() })
  }
}

///|
test "bench append put" (it : @bench.T) {
  let log = bench_new_log((1_000_000_000 : Int64))
  it.bench(fn() {
    ignore(log.append(b"key", b"value", (0 : Int64)) catch { _ => panic() })
  })
}

///|
test "bench get by offset" (it : @bench.T) {
  let log = bench_new_log((1_000_000_000 : Int64))
  bench_fill_append(log, 10000)
  let mut o : UInt64 = 0
  it.bench(fn() {
    let rec = log.get(o) catch { _ => panic() }
    it.keep(rec)
    o = (o + 7) % (10000 : UInt64)
  })
}

///|
test "bench range scan" (it : @bench.T) {
  let log = bench_new_log((1_000_000_000 : Int64))
  bench_fill_append(log, 10000)
  it.bench(fn() {
    let recs = log.scan_range((0 : UInt64), (1000 : UInt64)) catch {
      _ => panic()
    }
    it.keep(recs.length())
  })
}

///|
test "bench segment recover" (it : @bench.T) {
  let store = @backend_mem.MemLog::new()
  let src : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (0 : UInt64),
  )
  for i = 0; i < 10000; i = i + 1 {
    ignore(src.append(b"key", b"value", i.to_int64()) catch { _ => panic() })
  }
  it.bench(fn() {
    let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
      store,
      store,
      (0 : UInt64),
    )
    ignore(seg.recover() catch { _ => panic() })
    it.keep(seg.count())
  })
}
