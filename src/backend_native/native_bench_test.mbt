///|
/// Best-effort empty a bench directory so repeated runs start clean.
fn bench_clean(dir : String) -> Unit {
  let names = @backend_native.list_dir(dir) catch { _ => [] }
  for name in names {
    ignore(@backend_native.remove_file(dir + "/" + name))
  }
}

///|
test "bench native sequential scan" (it : @bench.T) {
  let dir = "/tmp/moonlog_native_bench"
  ignore(@backend_native.ensure_dir(dir))
  bench_clean(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  for i = 0; i < 2000; i = i + 1 {
    ignore(
      log.append(b"key", b"value-bytes", i.to_int64()) catch {
        _ => panic()
      },
    )
  }
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  let reopened : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  it.bench(fn() {
    let recs = reopened.scan() catch { _ => panic() }
    it.keep(recs.length())
  })
  for seg in reopened.segments {
    seg.writer.close()
  }
  bench_clean(dir)
}

///|
test "bench append batch bulk write" (it : @bench.T) {
  let dir = "/tmp/moonlog_native_bench_batch"
  ignore(@backend_native.ensure_dir(dir))
  bench_clean(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @backend_native.open_log_dir(
    dir,
    (1_000_000 : Int64),
    sync=@log.SyncPolicy::Batch,
  ) catch {
    _ => panic()
  }
  let value = b"bench-batch-value-0123456789abcdef0123456789abcdef"
  let records : Array[(Bytes, Bytes, Int64)] = []
  for i = 0; i < 1000; i = i + 1 {
    records.push((b"key", value, i.to_int64()))
  }
  it.bench(fn() {
    ignore(log.append_batch(records) catch { _ => panic() })
    it.keep(records.length())
  })
  @backend_native.flush_meta(dir, log) catch {
    _ => panic()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  bench_clean(dir)
}
