///|
/// A native end-to-end demo: open a directory-backed log, append records, query
/// the live KV view, print per-segment stats and snapshot the directory. Unlike
/// the in-memory demo this exercises the real file backend.
///
///   moon run examples/native_demo --target native
fn show(b : Bytes) -> String {
  @utf8.decode(b) catch {
    _ => "<binary>"
  }
}

///|
fn main {
  let dir = "/tmp/moonlog_native_demo"
  ignore(@backend_native.ensure_dir(dir))
  let opened : @log.Log[
    @backend_native.NativeFileLog,
    @backend_native.NativeFileLog,
  ]? = Some(@backend_native.open_log_dir(dir, (1_048_576 : Int64))) catch {
    _ => None
  }
  let log = match opened {
    Some(l) => l
    None => {
      println("could not open " + dir)
      return
    }
  }

  ignore(
    log.append(b"user:1", b"alice", (1 : Int64)) catch {
      _ => (0 : UInt64)
    },
  )
  ignore(log.append(b"user:2", b"bob", (2 : Int64)) catch { _ => (0 : UInt64) })
  ignore(
    log.append(b"user:1", b"alice-v2", (3 : Int64)) catch {
      _ => (0 : UInt64)
    },
  )
  ignore(log.delete(b"user:2", (4 : Int64)) catch { _ => (0 : UInt64) })

  println("== live keys ==")
  let index = log.build_key_index()
  let u1 = log.get_latest(index, b"user:1") catch { _ => None }
  match u1 {
    Some(rec) => println("user:1 -> " + show(rec.value))
    None => println("user:1 -> (none)")
  }
  let u2 = log.get_latest(index, b"user:2") catch { _ => None }
  match u2 {
    Some(rec) => println("user:2 -> " + show(rec.value))
    None => println("user:2 -> (none)")
  }

  println("== key range scan ==")
  let recs = log.scan_key_range(b"user:1", b"user:9") catch {
    _ => ([] : Array[@core.Record])
  }
  for rec in recs {
    println("  " + show(rec.key) + "=" + show(rec.value))
  }

  println("== per-segment stats ==")
  for row in log.segment_summaries() {
    println(
      "seg " +
      row.base_offset.to_string() +
      " records=" +
      row.records.to_string() +
      " bytes=" +
      row.bytes.to_string(),
    )
  }

  @backend_native.flush_meta(dir, log) catch {
    _ => ()
  }
  for seg in log.segments {
    seg.writer.close()
  }
  println("done")
}
