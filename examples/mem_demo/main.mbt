///|
/// A tiny, dependency-free demo of the append-only event log on the in-memory
/// backend. It builds cleanly and runs on wasm, js and native alike, so it
/// doubles as the "open me in the browser" entry point.
///
///   moon run examples/mem_demo --target native
///   moon run examples/mem_demo --target wasm
fn show(b : Bytes) -> String {
  @utf8.decode(b) catch {
    _ => "<binary>"
  }
}

///|
fn main {
  let store = @backend_mem.MemLog::new()
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (1_048_576 : Int64),
    base => @segment.Segment::new(store, store, base),
  )
  ignore(log.append(b"user:1", b"alice", (1 : Int64)) catch { _ => panic() })
  ignore(log.append(b"user:2", b"bob", (2 : Int64)) catch { _ => panic() })
  ignore(log.append(b"user:1", b"alice-v2", (3 : Int64)) catch { _ => panic() })
  ignore(log.delete(b"user:2", (4 : Int64)) catch { _ => panic() })

  println("== raw log ==")
  let recs = log.scan() catch { _ => panic() }
  for rec in recs {
    let kind = if rec.is_delete() { "DEL" } else { "PUT" }
    println(
      rec.offset.to_string() +
      " " +
      kind +
      " " +
      show(rec.key) +
      "=" +
      show(rec.value),
    )
  }

  println("== live keys ==")
  let index = log.build_key_index()
  for key in [b"user:1", b"user:2"] {
    let latest = log.get_latest(index, key) catch { _ => panic() }
    match latest {
      Some(rec) => println(show(key) + " -> " + show(rec.value))
      None => println(show(key) + " -> (none)")
    }
  }

  println("== cursor poll ==")
  let cur = @log.ConsumerCursor::new((0 : UInt64))
  let batch = cur.poll(log, (2 : Int32)) catch { _ => panic() }
  println(
    "got " +
    batch.length().to_string() +
    " records, cursor now at " +
    cur.position().to_string(),
  )
}
