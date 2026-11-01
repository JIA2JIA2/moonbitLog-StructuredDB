///|
/// Command-line front end for the append-only event log. Runs on the native
/// target with a directory of `*.log` segment files as its store.
///
/// Usage:
///   moonlog <command> <dir> [args...]
///
/// Commands:
///   put <dir> <key> <value>          append a key/value record
///   put-batch <dir> <k> <v> ...      append several key/value records at once
///   delete <dir> <key>               append a tombstone for a key
///   get <dir> <offset>               fetch one record by offset
///   scan <dir> [from] [to]           list records in [from, to)
///   scan-prefix <dir> <prefix>       list live keys beginning with a prefix
///   scan-range <dir> <lo> [hi]       list live keys in [lo, hi), hi optional
///   scan-time <dir> <lo> <hi>        list records with timestamp in [lo, hi)
///   recover <dir>                    open + recover, then report counts
///   prune <dir> <keep-segments>      keep only the newest segments
///   prune-bytes <dir> <bytes>        drop oldest segments over a byte budget
///   prune-before <dir> <timestamp>   drop segments last updated before a time
///   prune-expired <dir> <ttl>        drop segments last updated before now-ttl
///   cursor <dir> <start|-> <limit>   poll a consumer cursor batch
///   cursor-commit <dir> <position>   persist the consumer position
///   cursor-save <dir> <name> <pos>   persist a named consumer position
///   cursor-load <dir> <name>         read a named consumer position
///   cursor-list <dir>                list named consumer positions
///   cursor-drop <dir> <name>         delete a named consumer position
///   getkey <dir> <key>               fetch the latest value for a key
///   getkey-live <dir> <key> <ttl>    fetch a value unless it has expired
///   has-key <dir> <key>              report presence via the segment Bloom filters
///   export <dir> <file>              write all records to a portable file
///   import <dir> <file>              replay records from a portable file
///   compact <dir>                    rewrite the directory with live keys
///   fsck <dir>                       verify record/offset integrity
///   stats <dir>                      print record/segment counts
///
/// Writers take an exclusive directory lock; readers take a shared one, so a
/// CLI invocation never observes a half-written directory.
type CliLog = @log.Log[
  @backend_native.NativeFileLog,
  @backend_native.NativeFileLog,
]

///|
const ROLL_SIZE : Int64 = 1_048_576

///|
const USAGE : String = "usage: moonlog <put|put-batch|delete|get|getkey|getkey-live|has-key|scan|scan-prefix|scan-range|scan-time|recover|prune|prune-bytes|prune-before|prune-expired|cursor|cursor-commit|cursor-save|cursor-load|cursor-list|cursor-drop|export|import|compact|fsck|stats> <dir> [args]"

///|
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn bytes_to_string(b : Bytes) -> String {
  @utf8.decode(b) catch {
    _ => "<binary:" + b.length().to_string() + ">"
  }
}

///|
fn parse_offset(s : String) -> UInt64 raise @io.IoError {
  @string.parse_uint64(s) catch {
    _ => raise @io.IoError::Invalid("invalid offset: " + s)
  }
}

///|
fn parse_count(s : String) -> Int32 raise @io.IoError {
  @string.parse_int(s) catch {
    _ => raise @io.IoError::Invalid("invalid number: " + s)
  }
}

///|
/// Durability policy for the CLI, selected by `MOONLOG_SYNC`. It defaults to
/// `Always`, so a write command that returns has fsynced its data; set it to
/// `batch` to fsync once per batch / import, or `never` / `0` to rely on OS
/// writeback only.
fn desired_sync() -> @log.SyncPolicy {
  match @env.get_env_var("MOONLOG_SYNC") {
    Some(v) =>
      if v == "never" || v == "0" {
        @log.SyncPolicy::Never
      } else if v == "batch" {
        @log.SyncPolicy::Batch
      } else {
        @log.SyncPolicy::Always
      }
    None => @log.SyncPolicy::Always
  }
}

///|
fn open_log(dir : String) -> CliLog raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  @backend_native.open_log_dir(dir, ROLL_SIZE, sync=desired_sync())
}

///|
fn close_log(log : CliLog) -> Unit {
  for seg in log.segments {
    seg.writer.close()
  }
}

///|
/// Run `action` while holding the directory lock (exclusive for writers).
fn run_locked(
  dir : String,
  exclusive : Bool,
  action : () -> Unit raise @io.IoError,
) -> Unit raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  let lock = @backend_native.DirLock::acquire(dir, exclusive)
  action()
  lock.release()
}

///|
fn print_record(rec : @core.Record) -> Unit {
  let kind = if rec.is_delete() { "DEL" } else { "PUT" }
  println(
    rec.offset.to_string() +
    " " +
    kind +
    " " +
    bytes_to_string(rec.key) +
    "=" +
    bytes_to_string(rec.value),
  )
}

///|
fn cmd_put(
  dir : String,
  key : String,
  value : String,
) -> Unit raise @io.IoError {
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let off = log.append(@utf8.encode(key), @utf8.encode(value), now_ms())
    println("offset " + off.to_string())
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
}

///|
/// Append several key/value pairs passed as `<k1> <v1> <k2> <v2> ...`.
fn cmd_put_batch(dir : String, args : Array[String]) -> Unit raise @io.IoError {
  let n = args.length()
  if (n - 3) % 2 != 0 {
    raise @io.IoError::Invalid("put-batch needs key/value pairs")
  }
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let recs : Array[(Bytes, Bytes, Int64)] = []
    let mut i = 3
    while i < n {
      recs.push((@utf8.encode(args[i]), @utf8.encode(args[i + 1]), now_ms()))
      i = i + 2
    }
    let offsets = log.append_batch(recs)
    for off in offsets {
      println("offset " + off.to_string())
    }
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
}

///|
fn cmd_delete(dir : String, key : String) -> Unit raise @io.IoError {
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let off = log.delete(@utf8.encode(key), now_ms())
    println("offset " + off.to_string())
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
}

///|
fn cmd_get(dir : String, offset : String) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let off = parse_offset(offset)
    match log.get(off) {
      Some(rec) => print_record(rec)
      None => println("not found")
    }
    close_log(log)
  })
}

///|
fn cmd_scan(
  dir : String,
  from : String?,
  to : String?,
) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let lo = match from {
      Some(s) => parse_offset(s)
      None => (0 : UInt64)
    }
    let hi = match to {
      Some(s) => parse_offset(s)
      None => log.next_offset()
    }
    let recs = log.scan_range(lo, hi)
    for rec in recs {
      print_record(rec)
    }
    println("(" + recs.length().to_string() + " records)")
    close_log(log)
  })
}

///|
/// List the latest live record for every key starting with `prefix`, sorted
/// by key.
fn cmd_scan_prefix(dir : String, prefix : String) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let recs = log.scan_prefix(@utf8.encode(prefix))
    for rec in recs {
      print_record(rec)
    }
    println("(" + recs.length().to_string() + " records)")
    close_log(log)
  })
}

///|
/// List the latest live record for every key in the half-open range `[lo, hi)`,
/// sorted by key. When `hi` is omitted the range is unbounded above.
fn cmd_scan_range(
  dir : String,
  lo : String,
  hi : String?,
) -> Unit raise @io.IoError {
  let hi_bytes = match hi {
    Some(s) => @utf8.encode(s)
    None => (b"" : Bytes)
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let recs = log.scan_key_range(@utf8.encode(lo), hi_bytes)
    for rec in recs {
      print_record(rec)
    }
    println("(" + recs.length().to_string() + " records)")
    close_log(log)
  })
}

///|
/// List records whose timestamp lies in `[lo, hi)`.
fn cmd_scan_time(
  dir : String,
  lo : String,
  hi : String,
) -> Unit raise @io.IoError {
  let lo_ts = @string.parse_int64(lo) catch {
    _ => raise @io.IoError::Invalid("invalid timestamp: " + lo)
  }
  let hi_ts = @string.parse_int64(hi) catch {
    _ => raise @io.IoError::Invalid("invalid timestamp: " + hi)
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let recs = log.scan_time_range(lo_ts, hi_ts)
    for rec in recs {
      print_record(rec)
    }
    println("(" + recs.length().to_string() + " records)")
    close_log(log)
  })
}

///|
fn cmd_recover(dir : String) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    println(
      "records " +
      log.count().to_string() +
      " segments " +
      log.segment_count().to_string() +
      " next_offset " +
      log.next_offset().to_string(),
    )
    close_log(log)
  })
}

///|
/// Sweep the log and report whether offsets are contiguous throughout.
fn cmd_fsck(dir : String) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let report = log.verify()
    println("segments " + report.segments.to_string())
    println("records " + report.records.to_string())
    match report.first_bad_offset {
      Some(off) => println("corrupt: offset mismatch at " + off.to_string())
      None => println("ok")
    }
    close_log(log)
  })
}

///|
fn cmd_prune(dir : String, keep : String) -> Unit raise @io.IoError {
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let n = parse_count(keep)
    let dropped = log.retain_last(n, seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    println("dropped " + dropped.to_string())
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
}

///|
fn cmd_prune_bytes(dir : String, max : String) -> Unit raise @io.IoError {
  let limit = @string.parse_int64(max) catch {
    _ => raise @io.IoError::Invalid("invalid bytes: " + max)
  }
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let dropped = log.retain_max_bytes(limit, seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    println("dropped " + dropped.to_string())
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
}

///|
/// Drop segments whose last record predates `cutoff` (timestamp-based retention).
fn cmd_prune_before(dir : String, ts : String) -> Unit raise @io.IoError {
  let cutoff = @string.parse_int64(ts) catch {
    _ => raise @io.IoError::Invalid("invalid timestamp: " + ts)
  }
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let dropped = log.retain_before(cutoff, seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    println("dropped " + dropped.to_string())
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
}

///|
/// Drop segments whose last record is older than `ttl` ms relative to now.
fn cmd_prune_expired(dir : String, ttl : String) -> Unit raise @io.IoError {
  let ttl_ms = @string.parse_int64(ttl) catch {
    _ => raise @io.IoError::Invalid("invalid ttl: " + ttl)
  }
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let dropped = log.retain_before(now_ms() - ttl_ms, seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    println("dropped " + dropped.to_string())
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
}

///|
/// Poll a consumer cursor batch. `start` may be `-` to resume from the
/// persisted position written by `cursor-commit`.
fn cmd_cursor(
  dir : String,
  start : String,
  limit : String,
) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let from = if start == "-" || start == "auto" {
      @backend_native.load_cursor(dir)
    } else {
      parse_offset(start)
    }
    let log = open_log(dir)
    let cur = @log.ConsumerCursor::new(from)
    let recs = cur.poll(log, parse_count(limit))
    for rec in recs {
      print_record(rec)
    }
    println("cursor " + cur.position().to_string())
    close_log(log)
  })
}

///|
/// Persist a consumer cursor position so a later `cursor -` resumes there.
fn cmd_cursor_commit(dir : String, position : String) -> Unit raise @io.IoError {
  let pos = parse_offset(position)
  run_locked(dir, true, () => @backend_native.save_cursor(dir, pos))
  println("cursor " + pos.to_string())
}

///|
/// Persist a named consumer cursor position (`CURSOR.<name>`).
fn cmd_cursor_save(
  dir : String,
  name : String,
  position : String,
) -> Unit raise @io.IoError {
  if name.length() == 0 {
    raise @io.IoError::Invalid("cursor name must not be empty")
  }
  let pos = parse_offset(position)
  run_locked(dir, true, () => @backend_native.save_named_cursor(dir, name, pos))
  println("cursor " + name + " " + pos.to_string())
}

///|
/// Read a named consumer cursor position (`CURSOR.<name>`).
fn cmd_cursor_load(dir : String, name : String) -> Unit raise @io.IoError {
  if name.length() == 0 {
    raise @io.IoError::Invalid("cursor name must not be empty")
  }
  let pos = @backend_native.load_named_cursor(dir, name)
  println("cursor " + name + " " + pos.to_string())
}

///|
/// List every persisted named consumer cursor and its position.
fn cmd_cursor_list(dir : String) -> Unit raise @io.IoError {
  let names = @backend_native.list_named_cursors(dir)
  if names.length() == 0 {
    println("(no named cursors)")
  } else {
    for name in names {
      let pos = @backend_native.load_named_cursor(dir, name)
      println(name + " " + pos.to_string())
    }
  }
}

///|
/// Delete a named consumer cursor position file.
fn cmd_cursor_drop(dir : String, name : String) -> Unit raise @io.IoError {
  if name.length() == 0 {
    raise @io.IoError::Invalid("cursor name must not be empty")
  }
  @backend_native.remove_named_cursor(dir, name)
  println("dropped cursor " + name)
}

///|
/// Report whether a key is currently live, using segment Bloom filters to skip
/// segments that cannot contain it.
fn cmd_has_key(dir : String, key : String) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    match log.get_latest_bloom(@utf8.encode(key)) {
      Some(_) => println("present")
      None => println("absent")
    }
    close_log(log)
  })
}

///|
fn cmd_getkey(dir : String, key : String) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let index = log.build_key_index()
    match log.get_latest(index, @utf8.encode(key)) {
      Some(rec) => print_record(rec)
      None => println("not found")
    }
    close_log(log)
  })
}

///|
/// Latest live value for `key`, treating records older than `ttl` ms as gone.
fn cmd_getkey_live(
  dir : String,
  key : String,
  ttl : String,
) -> Unit raise @io.IoError {
  let ttl_ms = @string.parse_int64(ttl) catch {
    _ => raise @io.IoError::Invalid("invalid ttl: " + ttl)
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let index = log.build_key_index()
    match log.get_latest_at(index, @utf8.encode(key), now_ms(), ttl_ms) {
      Some(rec) => print_record(rec)
      None => println("not found")
    }
    close_log(log)
  })
}

///|
/// Rewrite the directory with only the live keys (latest puts), dropping
/// tombstones and superseded history, then refresh the manifest.
fn cmd_compact(dir : String) -> Unit raise @io.IoError {
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let n = log.compact(on_drop=seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    @backend_native.flush_meta(dir, log)
    println("compacted " + n.to_string() + " records")
    close_log(log)
  })
}

///|
/// Export the whole directory (including tombstones) to a portable record
/// stream file.
fn cmd_export(dir : String, file : String) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let data = log.export_bytes()
    @backend_native.write_file(file, data)
    println("exported " + log.count().to_string() + " records")
    close_log(log)
  })
}

///|
/// Import records from a file produced by `export` into a log directory.
fn cmd_import(dir : String, file : String) -> Unit raise @io.IoError {
  run_locked(dir, true, () => {
    let data = @backend_native.read_file(file)
    let log = open_log(dir)
    let n = log.import_bytes(data)
    @backend_native.flush_meta(dir, log)
    println("imported " + n.to_string() + " records")
    close_log(log)
  })
}

///|
fn dispatch(args : Array[String]) -> Unit raise @io.IoError {
  if args.length() < 2 {
    println(USAGE)
    return
  }
  let cmd = args[1]
  if cmd == "put" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      cmd_put(args[2], args[3], args[4])
    }
  } else if cmd == "put-batch" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      cmd_put_batch(args[2], args)
    }
  } else if cmd == "delete" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_delete(args[2], args[3])
    }
  } else if cmd == "get" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_get(args[2], args[3])
    }
  } else if cmd == "scan" {
    let from = if args.length() > 3 { Some(args[3]) } else { None }
    let to = if args.length() > 4 { Some(args[4]) } else { None }
    cmd_scan(args[2], from, to)
  } else if cmd == "scan-prefix" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_scan_prefix(args[2], args[3])
    }
  } else if cmd == "scan-range" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let hi = if args.length() > 4 { Some(args[4]) } else { None }
      cmd_scan_range(args[2], args[3], hi)
    }
  } else if cmd == "scan-time" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      cmd_scan_time(args[2], args[3], args[4])
    }
  } else if cmd == "recover" || cmd == "stats" {
    cmd_recover(args[2])
  } else if cmd == "fsck" {
    cmd_fsck(args[2])
  } else if cmd == "prune" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_prune(args[2], args[3])
    }
  } else if cmd == "prune-bytes" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_prune_bytes(args[2], args[3])
    }
  } else if cmd == "prune-before" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_prune_before(args[2], args[3])
    }
  } else if cmd == "prune-expired" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_prune_expired(args[2], args[3])
    }
  } else if cmd == "cursor" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      cmd_cursor(args[2], args[3], args[4])
    }
  } else if cmd == "getkey" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_getkey(args[2], args[3])
    }
  } else if cmd == "getkey-live" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      cmd_getkey_live(args[2], args[3], args[4])
    }
  } else if cmd == "has-key" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_has_key(args[2], args[3])
    }
  } else if cmd == "compact" {
    cmd_compact(args[2])
  } else if cmd == "cursor-commit" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_cursor_commit(args[2], args[3])
    }
  } else if cmd == "cursor-save" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      cmd_cursor_save(args[2], args[3], args[4])
    }
  } else if cmd == "cursor-load" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_cursor_load(args[2], args[3])
    }
  } else if cmd == "cursor-list" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      cmd_cursor_list(args[2])
    }
  } else if cmd == "cursor-drop" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_cursor_drop(args[2], args[3])
    }
  } else if cmd == "export" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_export(args[2], args[3])
    }
  } else if cmd == "import" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_import(args[2], args[3])
    }
  } else {
    println(USAGE)
  }
}

///|
fn main {
  let args = @env.args()
  dispatch(args) catch {
    @io.IoError::Closed => println("error: io closed")
    @io.IoError::OutOfBounds(o) =>
      println("error: out of bounds " + o.to_string())
    @io.IoError::Corrupt(o) => println("error: corrupt at " + o.to_string())
    @io.IoError::Syscall(c) => println("error: syscall " + c.to_string())
    @io.IoError::Invalid(m) => println("error: " + m)
  }
}
