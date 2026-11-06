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
/// Compare the two filter paths of 3.2 on the same 2000-record log (10%
/// `level=error`): the linear path parses every record, the indexed path
/// reads the field-column postings only.
test "bench linear field filter" (it : @bench.T) {
  let dir = "/tmp/moonlog_native_bench_inv_lin"
  ignore(@backend_native.ensure_dir(dir))
  bench_clean(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  for i = 0; i < 2000; i = i + 1 {
    let v = if i % 10 == 0 {
      b"level=error msg=boom"
    } else {
      b"level=info msg=ok"
    }
    ignore(log.append(b"svc", v, i.to_int64()) catch { _ => panic() })
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
    let mut n : Int32 = 0
    for r in recs {
      for pair in @core.parse_kv_pairs(r.value) {
        if pair.0 == b"level" && pair.1 == b"error" {
          n = n + 1
        }
      }
    }
    it.keep(n)
  })
  for seg in reopened.segments {
    seg.writer.close()
  }
  bench_clean(dir)
}

///|
test "bench inverted field lookup" (it : @bench.T) {
  let dir = "/tmp/moonlog_native_bench_inv_idx"
  ignore(@backend_native.ensure_dir(dir))
  bench_clean(dir)
  let log : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ] = @backend_native.open_log_dir(dir, (1_000_000 : Int64)) catch {
    _ => panic()
  }
  for i = 0; i < 2000; i = i + 1 {
    let v = if i % 10 == 0 {
      b"level=error msg=boom"
    } else {
      b"level=info msg=ok"
    }
    ignore(log.append(b"svc", v, i.to_int64()) catch { _ => panic() })
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
  // Lazy build (as the first indexed query would trigger), then warm reads.
  for seg in reopened.segments {
    seg.ensure_inv_index() catch {
      _ => panic()
    }
  }
  it.bench(fn() {
    let mut n : Int32 = 0
    for seg in reopened.segments {
      for _idx in seg.inv_field_postings(b"level", b"error") {
        n = n + 1
      }
    }
    it.keep(n)
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
