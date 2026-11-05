///|
/// Command-line front end for the append-only event log. Runs on the native
/// target with a directory of `*.log` segment files as its store.
///
/// Usage:
///   moonlog <command> <dir> [args...]
///
/// Commands:
///   put <dir> <key> <value>          append a key/value record
///   put-if <dir> <key> <expected|-> <value>
///                                    append only if live value == expected
///   put-batch <dir> <k> <v> ...      append several key/value records at once
///   delete <dir> <key>               append a tombstone for a key
///   get <dir> <offset>               fetch one record by offset
///   scan <dir> [from] [to]           list records in [from, to)
///   scan-prefix <dir> <prefix>       list live keys beginning with a prefix
///   scan-range <dir> <lo> [hi]       list live keys in [lo, hi), hi optional
///   scan-time <dir> <lo> <hi>        list records with timestamp in [lo, hi)
///   tail <dir> <n>                   list the most recent n records
///   recover <dir>                    open + recover, then report counts
///   prune <dir> <keep-segments>      keep only the newest segments
///   prune-bytes <dir> <bytes>        drop oldest segments over a byte budget
///   prune-before <dir> <timestamp>   drop segments last updated before a time
///   prune-expired <dir> <ttl>        drop segments last updated before now-ttl
///   prune-superseded <dir>           drop segments fully superseded by later records
///   merge <dir> <max-segments>       merge contiguous rolled segments
///   maintain <dir> <max-segments> [ttl]
///                                    merge + prune-superseded + compact-expired
///                                    + compress + fsck
///   serve <dir> <max-segments> [ttl] [--every ms] [--once]
///                                    run maintenance periodically
///   follow <dir> [start|-|tail] [--once] [--commit]
///                                    print new records as they are appended
///   backup <dir> <dst>               copy a snapshot into dst (incremental
///                                    when dst already holds an earlier backup)
///   restore <src> <dst>              materialize a backup into dst
///   cursor <dir> <start|-> <limit>   poll a consumer cursor batch
///   cursor-lag <dir>                 report each cursor's consumption lag
///   cursor-commit <dir> <position>   persist the consumer position
///   cursor-save <dir> <name> <pos>   persist a named consumer position
///   cursor-load <dir> <name>         read a named consumer position
///   cursor-list <dir>                list named consumer positions
///   cursor-drop <dir> <name>         delete a named consumer position
///   getkey <dir> <key>               fetch the latest value for a key
///   get-many <dir> <key> ...         fetch the latest value for several keys
///   getkey-live <dir> <key> <ttl>    fetch a value unless it has expired
///   has-key <dir> <key>              report presence via the segment Bloom filters
///   export <dir> <file>              write all records to a portable file
///   import <dir> <file>              replay records from a portable file
///   compact <dir>                    rewrite the directory with live keys
///   compact-expired <dir> <ttl>      rewrite with live keys, dropping expired ones
///   compress <dir> [rle|lzss]        compress rolled-over segments
///   fsck <dir> [fast] [--fix]        verify integrity; --fix repairs what it can
///   stats <dir> [json]               print record/segment counts (optionally JSON)
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
const USAGE : String = "usage: moonlog <put|put-if|put-batch|delete|get|getkey|get-many|getkey-live|has-key|scan|scan-prefix|scan-range|scan-time|tail|follow|recover|prune|prune-bytes|prune-before|prune-expired|prune-superseded|merge|maintain|serve|cursor|cursor-commit|cursor-lag|cursor-save|cursor-load|cursor-list|cursor-drop|export|import|compact|compact-expired|compress|fsck|stats|backup|restore> <dir> [args]"

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
/// Smallest committed cursor position across the default and all named
/// cursors, or `None` when no cursor exists (nothing to protect).
fn min_cursor_guard(dir : String) -> UInt64? {
  let positions = @backend_native.list_cursor_positions(dir) catch { _ => [] }
  let mut min : UInt64? = (None : UInt64?)
  for pair in positions {
    let (_name, pos) = pair
    match min {
      Some(m) => if pos < m { min = Some(pos) }
      None => min = Some(pos)
    }
  }
  min
}

///|
fn open_log(dir : String) -> CliLog raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  let log = @backend_native.open_log_dir(dir, ROLL_SIZE, sync=desired_sync())
  log.set_cursor_guard(min_cursor_guard(dir))
  log
}

///|
fn close_log(log : CliLog) -> Unit {
  for seg in log.segments {
    seg.writer.close()
  }
}

///|
/// How long a CLI invocation waits for a busy directory lock before failing.
/// Overridable with `MOONLOG_LOCK_TIMEOUT` (milliseconds); defaults to 5000.
fn lock_timeout_ms() -> Int32 {
  match @env.get_env_var("MOONLOG_LOCK_TIMEOUT") {
    Some(v) => @string.parse_int(v) catch { _ => 5000 }
    None => 5000
  }
}

///|
/// Run `action` while holding the directory lock (exclusive for writers) and
/// return its result. Waits up to `lock_timeout_ms()` for a busy lock so
/// concurrent writers can queue.
fn[T] run_locked(
  dir : String,
  exclusive : Bool,
  action : () -> T raise @io.IoError,
) -> T raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  let lock = @backend_native.DirLock::acquire_timeout(
    dir,
    exclusive,
    lock_timeout_ms(),
  )
  let result = action()
  lock.release()
  result
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
/// Append `value` for `key` only when the current live value equals
/// `expected`; pass `-` to require that the key does not exist yet.
fn cmd_put_if(
  dir : String,
  key : String,
  expected : String,
  value : String,
) -> Unit raise @io.IoError {
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let expected_bytes : Bytes? = if expected == "-" {
      (None : Bytes?)
    } else {
      Some(@utf8.encode(expected))
    }
    let result = log.compare_and_swap(
      @utf8.encode(key),
      expected_bytes,
      @utf8.encode(value),
      now_ms(),
    )
    match result {
      Some(off) => println("offset " + off.to_string())
      None => println("condition not met")
    }
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
    // Streamed: large ranges never materialise in memory.
    let mut count = 0
    log.for_each_while(lo, hi, rec => {
      print_record(rec)
      count = count + 1
      true
    })
    println("(" + count.to_string() + " records)")
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
    let mut count = 0
    log.for_each_time_range(lo_ts, hi_ts, rec => {
      print_record(rec)
      count = count + 1
      true
    })
    println("(" + count.to_string() + " records)")
    close_log(log)
  })
}

///|
/// List the most recent `n` records in append order, streamed.
fn cmd_tail(dir : String, n : String) -> Unit raise @io.IoError {
  let count_req = parse_count(n)
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let total = log.next_offset()
    let un = count_req.to_uint64()
    let from = if total > un { total - un } else { (0 : UInt64) }
    let mut count = 0
    log.for_each_while(from, total, rec => {
      print_record(rec)
      count = count + 1
      true
    })
    println("(" + count.to_string() + " records)")
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
/// Print per-segment statistics: total counts plus one line per segment. With
/// a second argument of `json`, emit the same information as JSON.
fn cmd_stats(dir : String, json : Bool) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let detail = log.segment_summaries()
    if json {
      let mut s = "{\"records\":" +
        log.count().to_string() +
        ",\"segments\":" +
        log.segment_count().to_string() +
        ",\"next_offset\":" +
        log.next_offset().to_string() +
        ",\"detail\":["
      let mut first = true
      for seg in detail {
        if !first {
          s = s + ","
        }
        first = false
        s = s +
          "{\"base\":" +
          seg.base_offset.to_string() +
          ",\"records\":" +
          seg.records.to_string() +
          ",\"bytes\":" +
          seg.bytes.to_string() +
          ",\"compressed\":" +
          (if seg.compressed { "true" } else { "false" })
        if seg.has_span {
          s = s +
            ",\"min_ts\":" +
            seg.min_ts.to_string() +
            ",\"max_ts\":" +
            seg.max_ts.to_string()
        }
        s = s + "}"
      }
      println(s + "]}")
    } else {
      println("records " + log.count().to_string())
      println("segments " + log.segment_count().to_string())
      println("next_offset " + log.next_offset().to_string())
      for seg in detail {
        println(
          "seg " +
          seg.base_offset.to_string() +
          " records=" +
          seg.records.to_string() +
          " bytes=" +
          seg.bytes.to_string() +
          " compressed=" +
          (if seg.compressed { "true" } else { "false" }),
        )
      }
    }
    close_log(log)
  })
}

///|
/// Print a VerifyReport in the shared fsck/maintain format.
fn print_verify(report : @log.VerifyReport) -> Unit {
  println("segments " + report.segments.to_string())
  println("records " + report.records.to_string())
  let mut ok = true
  match report.first_bad_offset {
    Some(off) => {
      ok = false
      println("corrupt: offset mismatch at " + off.to_string())
    }
    None => ()
  }
  match report.first_bad_checksum {
    Some(off) => {
      ok = false
      println("corrupt: checksum mismatch at " + off.to_string())
    }
    None => ()
  }
  if ok {
    println("ok")
  }
}

///|
/// Sweep the log and report whether offsets are contiguous throughout. With
/// `fast`, only segment metadata and stored whole-segment checksums are
/// checked (no record decoding) — much cheaper on large directories, but it
/// cannot detect corruption inside individual records. With `fix`, run a
/// repair pass first (quarantine segments failing their checksum, cut torn
/// tails, rebuild the manifest and sidecars) and then verify the result.
fn cmd_fsck(dir : String, fast : Bool, fix : Bool) -> Unit raise @io.IoError {
  if fix {
    run_locked(dir, true, () => {
      let rep = @backend_native.repair_log_dir(dir, ROLL_SIZE)
      println(
        "repaired truncated " +
        rep.truncated.to_string() +
        " isolated " +
        rep.isolated.to_string() +
        " removed-empty " +
        rep.removed_empty.to_string(),
      )
      let log = open_log(dir)
      let report = if fast { log.verify_fast() } else { log.verify() }
      println("mode " + (if fast { "fast" } else { "full" }) + " (post-fix)")
      print_verify(report)
      close_log(log)
    })
  } else {
    run_locked(dir, false, () => {
      let log = open_log(dir)
      let report = if fast { log.verify_fast() } else { log.verify() }
      println("mode " + (if fast { "fast" } else { "full" }))
      print_verify(report)
      close_log(log)
    })
  }
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
/// Drop rolled-over segments whose records have all been superseded by later
/// records for the same key (no live data is lost).
fn cmd_prune_superseded(dir : String, dry_run : Bool) -> Unit raise @io.IoError {
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let index = log.build_key_index()
    if dry_run {
      let would = log.count_superseded(index)
      println("would drop " + would.to_string() + " segments")
    } else {
      let dropped = log.prune_superseded(index, seg => {
        @backend_native.remove_segment_files(dir, seg.base_offset)
        seg.writer.close()
      })
      println("dropped " + dropped.to_string())
      @backend_native.flush_meta(dir, log)
    }
    close_log(log)
  })
}

///|
/// Merge contiguous rolled-over segments until at most `max_segments` remain.
fn cmd_merge(dir : String, max_str : String) -> Unit raise @io.IoError {
  let max = @string.parse_int(max_str) catch {
    _ => raise @io.IoError::Invalid("invalid segment count: " + max_str)
  }
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let merged = log.merge_segments(max, seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    println("merged " + merged.to_string())
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
}

///|
/// One maintenance pass inside the exclusive lock: merge contiguous
/// rolled-over segments down to `max_segments`, drop fully-superseded
/// segments, fold away expired records when `ttl_ms` is given, then flush the
/// manifest and sidecars. Returns `(merged, dropped, folded)`; `folded` is -1
/// when no TTL was given.
fn run_maintenance(
  dir : String,
  max_segments : Int32,
  ttl_ms : Int64?,
) -> (Int32, Int32, Int32, Int32) raise @io.IoError {
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let merged = log.merge_segments(max_segments, seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    let index = log.build_key_index()
    let dropped = log.prune_superseded(index, seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    let folded : Int32 = match ttl_ms {
      Some(t) =>
        log.compact_expired(now_ms(), t, on_drop=seg => {
          @backend_native.remove_segment_files(dir, seg.base_offset)
          seg.writer.close()
        })
      None => -1
    }
    let packed = @backend_native.compress_rolled_segments(dir, log)
    @backend_native.flush_meta(dir, log)
    close_log(log)
    (merged, dropped, folded, packed)
  })
}

///|
/// Parse a `maintain`/`serve` TTL argument (milliseconds).
fn parse_ttl(ttl : String?) -> Int64? raise @io.IoError {
  match ttl {
    Some(s) =>
      Some(
        @string.parse_int64(s) catch {
          _ => raise @io.IoError::Invalid("invalid ttl: " + s)
        },
      )
    None => (None : Int64?)
  }
}

///|
/// One-shot maintenance: merge contiguous rolled-over segments down to
/// `max_segments`, drop fully-superseded segments, fold away expired records
/// when `ttl` is given, then finish with an fsck report.
fn cmd_maintain(
  dir : String,
  max_str : String,
  ttl : String?,
) -> Unit raise @io.IoError {
  let max = @string.parse_int(max_str) catch {
    _ => raise @io.IoError::Invalid("invalid segment count: " + max_str)
  }
  let ttl_ms = parse_ttl(ttl)
  let (merged, dropped, folded, packed) = run_maintenance(dir, max, ttl_ms)
  println("merged " + merged.to_string())
  println("superseded dropped " + dropped.to_string())
  println("compressed " + packed.to_string())
  match ttl_ms {
    Some(_) => println("expired folded " + folded.to_string())
    None => ()
  }
  run_locked(dir, false, () => {
    let reopened = open_log(dir)
    let report = reopened.verify()
    print_verify(report)
    close_log(reopened)
  })
}

///|
/// Periodic maintenance loop: run the one-shot `maintain` pipeline (merge
/// contiguous rolled segments down to `max_segments`, prune superseded
/// segments, fold expired records when a TTL is given) and flush metadata,
/// then sleep and repeat. `--every ms` (or `MOONLOG_SERVE_INTERVAL`, default
/// 60000) selects the pause between passes; `--once` runs a single pass and
/// returns, which keeps the command scriptable and testable.
fn cmd_serve(
  dir : String,
  max_str : String,
  ttl : String?,
  every : String?,
  once : Bool,
) -> Unit raise @io.IoError {
  let max = @string.parse_int(max_str) catch {
    _ => raise @io.IoError::Invalid("invalid segment count: " + max_str)
  }
  let ttl_ms = parse_ttl(ttl)
  let every_ms = match every {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid interval: " + s)
      }
    None =>
      match @env.get_env_var("MOONLOG_SERVE_INTERVAL") {
        Some(v) => @string.parse_int(v) catch { _ => 60000 }
        None => 60000
      }
  }
  let mut cycle = 0
  let mut go = true
  while go {
    let (merged, dropped, folded, packed) = run_maintenance(dir, max, ttl_ms)
    cycle = cycle + 1
    let mut line = "cycle " +
      cycle.to_string() +
      ": merged " +
      merged.to_string() +
      " superseded dropped " +
      dropped.to_string() +
      " compressed " +
      packed.to_string()
    match ttl_ms {
      Some(_) => line = line + " expired folded " + folded.to_string()
      None => ()
    }
    println(line)
    if once {
      go = false
    } else {
      @backend_native.sleep_ms(every_ms)
    }
  }
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
/// Report how far every persisted consumer cursor (default and named) trails
/// the log's end, so stalled consumers are visible at a glance.
fn cmd_cursor_lag(dir : String) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let next = log.next_offset()
    let positions = @backend_native.list_cursor_positions(dir)
    if positions.length() == 0 {
      println("(no cursors)")
    }
    for pair in positions {
      let (name, pos) = pair
      let label = if name.length() == 0 { "-" } else { name }
      let lag = if next > pos { next - pos } else { (0 : UInt64) }
      println(
        "cursor " +
        label +
        " position " +
        pos.to_string() +
        " lag " +
        lag.to_string(),
      )
    }
    println("next_offset " + next.to_string())
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
/// Read keys from a file, one per line (blank lines skipped).
fn keys_from_file(file : String) -> Array[Bytes] {
  let data = @backend_native.read_file(file)
  let out : Array[Bytes] = []
  let n = data.length()
  let mut start = 0
  let mut i = 0
  while i <= n {
    if i == n || data.at(i) == (10 : Byte) {
      if i > start {
        out.push(@core.slice(data, start, i))
      }
      start = i + 1
    }
    i = i + 1
  }
  out
}

///|
/// Latest live value for each of several keys, in the given order.
fn cmd_get_many(dir : String, keys : Array[Bytes]) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let recs = log.get_many(keys)
    let mut i = 0
    for rec in recs {
      match rec {
        Some(r) => print_record(r)
        None => println(bytes_to_string(keys[i]) + ": not found")
      }
      i = i + 1
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
    println("warning: offsets renumbered; reset any cursors (cursor-commit 0)")
    close_log(log)
  })
}

///|
/// Rewrite the directory with unexpired live keys: like `compact`, but keys
/// whose latest record has expired (`now - ts > ttl`) are dropped too.
/// Offsets are renumbered from 0.
fn cmd_compact_expired(dir : String, ttl : String) -> Unit raise @io.IoError {
  let ttl_ms = @string.parse_int64(ttl) catch {
    _ => raise @io.IoError::Invalid("invalid ttl: " + ttl)
  }
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let n = log.compact_expired(now_ms(), ttl_ms, on_drop=seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    @backend_native.flush_meta(dir, log)
    println("compacted " + n.to_string() + " records")
    println("warning: offsets renumbered; reset any cursors (cursor-commit 0)")
    close_log(log)
  })
}

///|
/// Compress every rolled-over (non-active) segment in place. The active segment
/// keeps growing, so it is left uncompressed. `algo` is `rle` or `lzss`
/// (default).
fn cmd_compress(
  dir : String,
  algo : String,
  dry_run : Bool,
) -> Unit raise @io.IoError {
  let a = if algo == "rle" {
    1
  } else if algo == "lzss" || algo == "lz" {
    2
  } else {
    raise @io.IoError::Invalid("unknown compression algorithm: " + algo)
  }
  run_locked(dir, true, () => {
    if dry_run {
      let would = @backend_native.count_compressible_segments(dir, ROLL_SIZE)
      println("would compress " + would.to_string() + " segments")
    } else {
      let n = @backend_native.compress_log_dir(dir, ROLL_SIZE, algo=a)
      println("compressed " + n.to_string() + " segments")
    }
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
    println("warning: offsets renumbered; reset any cursors (cursor-commit 0)")
    close_log(log)
  })
}

///|
/// Take a physical backup of `src` into the empty directory `dst`: hold the
/// exclusive lock, flush data and metadata, then copy the segment files,
/// sidecars and manifest. Offsets are preserved, so the restored copy
/// continues where the source stopped and committed cursor positions remain
/// meaningful against it.
fn cmd_backup(src : String, dst : String) -> Unit raise @io.IoError {
  run_locked(src, true, () => {
    let log = open_log(src)
    log.flush()
    @backend_native.flush_meta(src, log)
    close_log(log)
    let n = @backend_native.backup_log_dir(src, dst)
    println("backed up " + n.to_string() + " segments to " + dst)
  })
}

///|
/// Restore a backup made by `backup` into the empty directory `dst`.
fn cmd_restore(src : String, dst : String) -> Unit raise @io.IoError {
  let n = @backend_native.restore_log_dir(src, dst)
  println("restored " + n.to_string() + " segments to " + dst)
}

///|
/// Poll interval for `follow`, overridable with `MOONLOG_FOLLOW_INTERVAL`.
fn follow_interval_ms() -> Int32 {
  match @env.get_env_var("MOONLOG_FOLLOW_INTERVAL") {
    Some(v) => @string.parse_int(v) catch { _ => 200 }
    None => 200
  }
}

///|
/// Tail the log: print new records as they are appended, polling the
/// directory until interrupted. `start` selects the first offset to print
/// (`-` resumes from the persisted cursor, `tail` starts at the current end,
/// default 0). With `--commit`, each batch advances the persisted consumer
/// cursor so `cursor -` and the next `follow -` resume past it; run only one
/// committing follower at a time. With `--once`, a single pass is made and
/// the command returns (for scripts and tests).
fn cmd_follow(
  dir : String,
  start : String,
  once : Bool,
  commit : Bool,
) -> Unit raise @io.IoError {
  let mut from : UInt64 = (0 : UInt64)
  if start == "tail" {
    let lock = @backend_native.DirLock::acquire_timeout(
      dir,
      false,
      lock_timeout_ms(),
    )
    let log = open_log(dir)
    from = log.next_offset()
    close_log(log)
    lock.release()
  } else if start == "-" {
    from = @backend_native.load_cursor(dir)
  } else {
    from = parse_offset(start)
  }
  let interval = follow_interval_ms()
  let mut fetched = 0
  let mut go = true
  while go {
    let lock = @backend_native.DirLock::acquire_timeout(
      dir,
      false,
      lock_timeout_ms(),
    )
    let log = open_log(dir)
    let next = log.next_offset()
    if next > from {
      let recs = log.scan_range(from, next)
      for rec in recs {
        print_record(rec)
      }
      fetched = fetched + recs.length()
      from = next
      if commit {
        @backend_native.save_cursor(dir, from)
      }
    }
    close_log(log)
    lock.release()
    if once {
      go = false
    } else {
      @backend_native.sleep_ms(interval)
    }
  }
  println(
    "(" + fetched.to_string() + " records, cursor " + from.to_string() + ")",
  )
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
  } else if cmd == "put-if" {
    if args.length() < 6 {
      println(USAGE)
    } else {
      cmd_put_if(args[2], args[3], args[4], args[5])
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
  } else if cmd == "tail" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_tail(args[2], args[3])
    }
  } else if cmd == "recover" {
    cmd_recover(args[2])
  } else if cmd == "stats" {
    let json = args.length() > 3 && args[3] == "json"
    cmd_stats(args[2], json)
  } else if cmd == "fsck" {
    let mut fast = false
    let mut fix = false
    let mut i = 3
    while i < args.length() {
      if args[i] == "fast" {
        fast = true
      } else if args[i] == "--fix" {
        fix = true
      }
      i = i + 1
    }
    cmd_fsck(args[2], fast, fix)
  } else if cmd == "backup" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_backup(args[2], args[3])
    }
  } else if cmd == "restore" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_restore(args[2], args[3])
    }
  } else if cmd == "follow" {
    let mut start = "0"
    let mut once = false
    let mut commit = false
    let mut i = 3
    while i < args.length() {
      let a = args[i]
      if a == "--once" {
        once = true
      } else if a == "--commit" {
        commit = true
      } else {
        start = a
      }
      i = i + 1
    }
    cmd_follow(args[2], start, once, commit)
  } else if cmd == "serve" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut ttl : String? = (None : String?)
      let mut every : String? = (None : String?)
      let mut once = false
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--once" {
          once = true
        } else if a == "--every" && i + 1 < args.length() {
          every = Some(args[i + 1])
          i = i + 1
        } else {
          match ttl {
            None => ttl = Some(a)
            Some(_) => ()
          }
        }
        i = i + 1
      }
      cmd_serve(args[2], args[3], ttl, every, once)
    }
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
  } else if cmd == "prune-superseded" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      cmd_prune_superseded(args[2], args.length() > 3 && args[3] == "dry-run")
    }
  } else if cmd == "merge" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_merge(args[2], args[3])
    }
  } else if cmd == "maintain" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let ttl : String? = if args.length() > 4 {
        Some(args[4])
      } else {
        (None : String?)
      }
      cmd_maintain(args[2], args[3], ttl)
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
  } else if cmd == "get-many" {
    if args.length() < 4 {
      println(USAGE)
    } else if args[3] == "--keys" {
      if args.length() < 5 {
        println(USAGE)
      } else {
        cmd_get_many(args[2], keys_from_file(args[4]))
      }
    } else {
      let keys : Array[Bytes] = []
      let mut i = 3
      while i < args.length() {
        keys.push(@utf8.encode(args[i]))
        i = i + 1
      }
      cmd_get_many(args[2], keys)
    }
  } else if cmd == "has-key" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_has_key(args[2], args[3])
    }
  } else if cmd == "compact" {
    cmd_compact(args[2])
  } else if cmd == "compact-expired" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_compact_expired(args[2], args[3])
    }
  } else if cmd == "compress" {
    let mut algo = "lzss"
    let mut dry = false
    let mut i = 3
    while i < args.length() {
      if args[i] == "dry-run" {
        dry = true
      } else {
        algo = args[i]
      }
      i = i + 1
    }
    cmd_compress(args[2], algo, dry)
  } else if cmd == "cursor-commit" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_cursor_commit(args[2], args[3])
    }
  } else if cmd == "cursor-lag" {
    cmd_cursor_lag(args[2])
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
