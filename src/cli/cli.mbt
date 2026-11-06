///|
/// Command-line front end for the append-only event log. Runs on the native
/// target with a directory of `*.log` segment files as its store.
///
/// Usage:
///   moonlog <command> <dir> [args...]
///
/// Commands:
///   put <dir> <key> <value> [--ts <ms>] [--idempotent]
///                                    append a key/value record; with
///                                    --idempotent a repeated (key, value) is
///                                    recognized and skipped
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
///   ttl-expire <dir> [--dry-run]     differentiated-TTL expiry per <dir>/TTL
///                                    (default/service/level rules); applied
///                                    runs append to TTL_AUDIT.log
///   replicate <src> <dst> [--follow]
///                                    incrementally mirror the source log into
///                                    a complete replica directory (--follow
///                                    repeats on an interval and only warns
///                                    while the source is down); failover =
///                                    point readers/writers at the replica,
///                                    rebalance = replicate back
///   merge <dir> <max-segments>       merge contiguous rolled segments
///   maintain <dir> <max-segments> [ttl]
///                                    merge + prune-superseded + compact-expired
///                                    + compress + fsck
///   serve <dir> <max-segments> [ttl] [--every ms] [--fsck-every N] [--once]
///                                    run maintenance periodically, with an
///                                    optional fast fsck every N cycles
///   follow <dir> [start|-|tail] [--once] [--commit] [--json] [--name <cursor>]
///                                    print new records as they are appended
///   ingest <dir> <file> [--follow] [--once] [--fifo] [--format lines|kv]
///                     [--key <name>] [--key-field <name>] [--ts-field <name>]
///                     [--from <bytes>] [--batch N] [--interval ms]
///                     [--idempotent]
///                                    parse a log file into records (batch
///                                    import, or follow appended lines);
///                                    resumable via the `ingest-<basename>`
///                                    cursor; `--fifo` subscribes to a named
///                                    pipe instead (writers push batches);
///                                    with --idempotent replayed lines whose
///                                    (key, value) matches the latest record
///                                    are skipped
///   http <dir> [--port N] [--queue N] [--batch N] [--backlog-alert N]
///             [--format lines|kv] [--key <name>] [--key-field <name>]
///             [--ts-field <name>] [--idempotent]
///                                    HTTP push endpoint on 127.0.0.1 (POST /
///                                    or /push buffers into a bounded queue
///                                    and answers 202, or 429 + Retry-After
///                                    when the backlog is full — explicit
///                                    backpressure, no silent drops; backlog
///                                    beyond --backlog-alert warns and is
///                                    exposed via /stats; GET /health, /stats)
///   bench-write <dir> <count> [--batch N] [--sync always|batch|never]
///                [--prefix <p>]
///                                    bulk-write benchmark: report throughput,
///                                    then reopen and verify no record was lost
///   search <dir> <text> [--field key|value|both] [--ignore-case] [--limit N]
///                       [--from off] [--to off]
///                                    full-text search (linear scan) over keys
///                                    and/or values
///   context <dir> <offset> [--before N] [--after N]
///                                    print the records around one offset
///   aggregate <dir> [--by key|value|kind|hour|prefix:N] [--kv-field <name>]
///                    [--match <text>] [--top N] [--json]
///                                    multi-dimensional count aggregation
///   cluster <dir> [--match <text>] [--top N]
///                                    error clustering by normalized template
///   trend <dir> [--bucket minute|hour|day] [--match <text>] [--width N]
///                                    time-bucket histogram as text bars
///   alert <dir> <match> --threshold N [--window minute|hour|day]
///                   [--notify-file <path>] [--webhook <url>] [--json]
///                                    threshold alerting per UTC window
///   baseline <dir> [--match <text>] [--window minute|hour|day] [--sigma N]
///                    [--min-windows N] [--notify-file <path>] [--webhook <url>]
///                                    baseline anomaly detection (mean/stddev
///                                    z-score per window)
///   rbac <dir> init <token> | add <name> <token> <allow> | list
///            | remove <name> | check <command>
///                                    manage RBAC roles; once an RBAC file
///                                    exists every command needs a
///                                    MOONLOG_TOKEN role that allows it
///   backup <dir> <dst>               copy a snapshot into dst (incremental
///                                    when dst already holds an earlier backup)
///   restore <src> <dst>              materialize a backup into dst
///   cursor <dir> <start|-> <limit>   poll a consumer cursor batch
///   cursor-lag <dir>                 report each cursor's consumption lag
///   version                          print the moonlog version
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
///   export-jsonl <dir> <file> [base64]
///                                    write all records as JSON Lines
///   import <dir> <file>              replay records from a portable file
///   compact <dir>                    rewrite the directory with live keys
///   compact-expired <dir> <ttl>      rewrite with live keys, dropping expired ones
///   compress <dir> [rle|lzss]        compress rolled-over segments
///   tier <dir> <cold-dir> [--warm N] [--dry-run]
///                                    hot/warm/cold tiering: compress rolled
///                                    segments, move the oldest ones into
///                                    cold-dir behind symlinks
///   fsck <dir> [fast] [--fix] [--dry-run]
///                                    verify integrity; --fix repairs what it
///                                    can; --dry-run only prints the repair plan
///   stats <dir> [json]               print record/segment counts (optionally JSON)
///
/// Writers take an exclusive directory lock; readers take a shared one, so a
/// CLI invocation never observes a half-written directory.
type CliLog = @log.Log[
  @backend_native.NativeFileLog,
  @backend_native.NativeFileLog,
]

///|
/// Shared options for every ingestion path (file, FIFO and HTTP push): the
/// parse format, field extraction rules and write behavior.
struct IngestOptions {
  format : String
  key_bytes : Bytes
  field_bytes : Bytes
  value_field_bytes : Bytes
  ts_field_bytes : Bytes?
  template_bytes : Bytes?
  batch_n : Int32
  idempotent : Bool
  sampling : @core.SamplingConfig?
  from_bytes : Int64?
  schema : Bool
  clock_skew_ms : Int64
  mask : Bool
  mask_extra : Array[Bytes]
  meta_bytes : Bytes?
  partition_ms : Int64
}

///|
const ROLL_SIZE : Int64 = 1_048_576

///|
const MOONLOG_VERSION : String = "0.1.2"

///|
const USAGE : String = "usage: moonlog <put|put-if|put-batch|delete|get|getkey|get-many|getkey-live|has-key|scan|scan-prefix|scan-range|scan-time|tail|follow|ingest|http|bench-write|search|query|context|aggregate|cluster|trend|alert|baseline|rbac|recover|prune|prune-bytes|prune-before|prune-expired|prune-superseded|merge|maintain|serve|ttl-expire|replicate|cursor|cursor-commit|cursor-lag|cursor-save|cursor-load|cursor-list|cursor-drop|export|export-jsonl|import|compact|compact-expired|compress|tier|fsck|stats|partitions|backup|restore> <dir> [args]"

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

///|
/// Partition unit in ms for `--partition day|hour` (0 = time partitioning off).
fn parse_partition(s : String) -> Int64 raise @io.IoError {
  if s == "day" {
    (86_400_000 : Int64)
  } else if s == "hour" {
    (3_600_000 : Int64)
  } else {
    raise @io.IoError::Invalid("invalid partition: " + s + " (day|hour)")
  }
}

///|
fn open_log(dir : String, partition~ : Int64 = 0) -> CliLog raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  let log = @backend_native.open_log_dir(
    dir,
    ROLL_SIZE,
    sync=desired_sync(),
    partition_ms=partition,
  )
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
/// Two hex digits for a value below 256, used by JSON \u00XX escapes.
fn hex2(v : Int32) -> String {
  let d = fn(x : Int32) -> String {
    match x {
      0 => "0"
      1 => "1"
      2 => "2"
      3 => "3"
      4 => "4"
      5 => "5"
      6 => "6"
      7 => "7"
      8 => "8"
      9 => "9"
      10 => "a"
      11 => "b"
      12 => "c"
      13 => "d"
      14 => "e"
      _ => "f"
    }
  }
  d(v / 16) + d(v % 16)
}

///|
/// Escape a string for embedding in a JSON document: quotes, backslashes
/// and control characters are escaped; other characters pass through.
fn json_escape_str(s : String) -> String {
  let sb = StringBuilder()
  for ch in s {
    let c = ch.to_int()
    if c == 34 {
      sb.write_string("\\\"")
    } else if c == 92 {
      sb.write_string("\\\\")
    } else if c == 10 {
      sb.write_string("\\n")
    } else if c == 13 {
      sb.write_string("\\r")
    } else if c == 9 {
      sb.write_string("\\t")
    } else if c == 8 {
      sb.write_string("\\b")
    } else if c == 12 {
      sb.write_string("\\f")
    } else if c < 32 {
      sb.write_string("\\u00" + hex2(c))
    } else {
      sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
/// Print one record as a single-line JSON object (the same shape as
/// `export-jsonl`'s text mode; keys and values are assumed to be UTF-8 text).
fn print_json_record(rec : @core.Record) -> Unit {
  println(
    "{\"offset\":" +
    rec.offset.to_string() +
    ",\"timestamp\":" +
    rec.timestamp.to_string() +
    ",\"kind\":\"" +
    (if rec.is_delete() { "delete" } else { "put" }) +
    "\",\"key\":\"" +
    json_escape_str(bytes_to_string(rec.key)) +
    "\",\"value\":\"" +
    json_escape_str(bytes_to_string(rec.value)) +
    "\"}",
  )
}

///|
fn cmd_put(
  dir : String,
  key : String,
  value : String,
  ts : String?,
  idempotent : Bool,
  partition : Int64,
) -> Unit raise @io.IoError {
  let timestamp = match ts {
    Some(s) =>
      @string.parse_int64(s) catch {
        _ => raise @io.IoError::Invalid("invalid timestamp: " + s)
      }
    None => now_ms()
  }
  run_locked(dir, true, () => {
    let log = open_log(dir, partition~)
    let kb = @utf8.encode(key)
    let vb = @utf8.encode(value)
    let (added, off) = if idempotent {
      log.append_idempotent(kb, vb, timestamp)
    } else {
      let off = log.append(kb, vb, timestamp)
      (true, off)
    }
    if added {
      println("offset " + off.to_string())
      @backend_native.flush_meta(dir, log)
    } else {
      println("skipped " + off.to_string() + " (duplicate)")
    }
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
/// One partition bucket in the `partitions` view.
struct PartitionStat {
  mut segments : Int32
  mut records : Int32
  mut bytes : Int64
  mut min_ts : Int64
  mut max_ts : Int64
}

///|
/// Time-partition view (3.1): group segments by the time bucket of their
/// first record at `--unit day|hour` granularity and report each partition's
/// segment/record/byte totals and UTC span. Retention (prune-before /
/// prune-expired) drops whole segments, so with partitioned writes a bucket
/// can be discarded as a unit; the prune only touches the dropped files and
/// readers on the shared lock are never blocked by it.
fn cmd_partitions(
  dir : String,
  unit : String,
  json : Bool,
) -> Unit raise @io.IoError {
  let unit_ms = match unit {
    "day" => (86_400_000 : Int64)
    "hour" => (3_600_000 : Int64)
    _ => raise @io.IoError::Invalid("invalid unit: " + unit + " (day|hour)")
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let parts : Array[(Int64, PartitionStat)] = []
    for seg in log.segments {
      let first = seg.get(seg.base_offset) catch { _ => None }
      match first {
        Some(rec) => {
          let b = @log.time_bucket(rec.timestamp, unit_ms)
          let last = seg.get(seg.next_offset - (1 : UInt64)) catch { _ => None }
          let mut p_max = rec.timestamp
          match last {
            Some(l) => p_max = l.timestamp
            None => ()
          }
          let mut stat : PartitionStat? = None
          for pair in parts {
            if pair.0 == b {
              stat = Some(pair.1)
            }
          }
          match stat {
            Some(p) => {
              p.segments = p.segments + 1
              p.records = p.records + seg.record_count
              p.bytes = p.bytes + seg.size
              if rec.timestamp < p.min_ts {
                p.min_ts = rec.timestamp
              }
              if p_max > p.max_ts {
                p.max_ts = p_max
              }
            }
            None =>
              parts.push(
                (
                  b,
                  {
                    segments: 1,
                    records: seg.record_count,
                    bytes: seg.size,
                    min_ts: rec.timestamp,
                    max_ts: p_max,
                  },
                ),
              )
          }
        }
        None => ()
      }
    }
    parts
    .mut_view()
    .sort_by(fn(a, c) {
      let d = a.0.compare(c.0)
      if d < 0 {
        -1
      } else if d > 0 {
        1
      } else {
        0
      }
    })
    let label = fn(ms : Int64) -> String {
      @core.format_utc(ms, if unit == "day" { "day" } else { "hour" })
    }
    if json {
      let out = StringBuilder()
      out.write_string("{\"unit\":\"" + unit + "\",\"partitions\":[")
      let mut first_p = true
      for pair in parts {
        let (b, p) = pair
        if !first_p {
          out.write_string(",")
        }
        first_p = false
        out.write_string(
          "{\"bucket\":\"" +
          label(b) +
          "\",\"start_ms\":" +
          b.to_string() +
          ",\"segments\":" +
          p.segments.to_string() +
          ",\"records\":" +
          p.records.to_string() +
          ",\"bytes\":" +
          p.bytes.to_string() +
          ",\"min_ts\":" +
          p.min_ts.to_string() +
          ",\"max_ts\":" +
          p.max_ts.to_string() +
          "}",
        )
      }
      out.write_string("]}")
      println(out.to_string())
    } else {
      for pair in parts {
        let (b, p) = pair
        println(
          label(b) +
          "  segments=" +
          p.segments.to_string() +
          " records=" +
          p.records.to_string() +
          " bytes=" +
          p.bytes.to_string() +
          "  span=" +
          @core.format_utc(p.min_ts, "minute") +
          ".." +
          @core.format_utc(p.max_ts, "minute"),
        )
      }
      println(
        "(" + parts.length().to_string() + " partitions, unit " + unit + ")",
      )
    }
    close_log(log)
  })
}

///|
/// Print per-segment statistics: total counts plus one line per segment,
/// including per-segment and total compression sizes (`bytes` is the logical
/// record size, `disk` what the segment occupies on disk). With a second
/// argument of `json`, emit the same information as JSON.
fn cmd_stats(dir : String, json : Bool) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let detail = log.segment_summaries()
    let mut raw_total : Int64 = 0
    let mut disk_total : Int64 = 0
    for seg in detail {
      raw_total = raw_total + seg.bytes
      disk_total = disk_total + seg.disk_bytes
    }
    if json {
      let mut s = "{\"records\":" +
        log.count().to_string() +
        ",\"segments\":" +
        log.segment_count().to_string() +
        ",\"next_offset\":" +
        log.next_offset().to_string() +
        ",\"raw_bytes\":" +
        raw_total.to_string() +
        ",\"disk_bytes\":" +
        disk_total.to_string() +
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
          ",\"disk_bytes\":" +
          seg.disk_bytes.to_string() +
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
      println("raw_bytes " + raw_total.to_string())
      println("disk_bytes " + disk_total.to_string())
      for seg in detail {
        println(
          "seg " +
          seg.base_offset.to_string() +
          " records=" +
          seg.records.to_string() +
          " bytes=" +
          seg.bytes.to_string() +
          " disk=" +
          seg.disk_bytes.to_string() +
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
/// With `dry`, print only the repair plan (what would be truncated, isolated
/// or removed) and change nothing on disk.
fn cmd_fsck(
  dir : String,
  fast : Bool,
  fix : Bool,
  dry : Bool,
) -> Unit raise @io.IoError {
  if fix {
    run_locked(dir, true, () => {
      let rep = @backend_native.repair_log_dir(dir, ROLL_SIZE, dry_run=dry)
      if dry {
        println(
          "repair plan (dry-run): would truncate " +
          rep.truncated.to_string() +
          " isolate " +
          rep.isolated.to_string() +
          " remove-empty " +
          rep.removed_empty.to_string(),
        )
      } else {
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
      }
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

///|
/// Append a TTL expiry event to `<dir>/TTL_AUDIT.log` (JSONL), so retention
/// actions stay auditable beyond the one-line command output.
fn append_ttl_audit(
  dir : String,
  policy_text : String,
  dropped : Int32,
  expired : Int32,
) -> Unit {
  let path = dir + "/TTL_AUDIT.log"
  let existing = @backend_native.read_file(path)
  let line = "{\"ts\":" +
    now_ms().to_string() +
    ",\"event\":\"ttl_expire\"" +
    ",\"segments_dropped\":" +
    dropped.to_string() +
    ",\"records_expired\":" +
    expired.to_string() +
    ",\"policy\":\"" +
    json_escape_str(policy_text) +
    "\"}\n"
  ignore(
    @backend_native.write_file(path, existing + @utf8.encode(line)) catch {
      _ => ()
    },
  )
}

///|
/// Policy-driven TTL expiry (3.4): read `<dir>/TTL` — `default <days>`,
/// `service <name> <days>` and `level <level> <days>` lines ('#' comments
/// allowed) — evaluate every record (service matches the key, level the
/// parsed level field; the stricter one wins, default otherwise) and drop
/// segments whose records have all expired. `--dry-run` prints the plan
/// without touching data; every applied run appends a JSONL event to
/// `<dir>/TTL_AUDIT.log` so cleanup stays auditable.
fn cmd_ttl_expire(dir : String, dry_run : Bool) -> Unit raise @io.IoError {
  let ppath = dir + "/TTL"
  if !@backend_native.file_exists(ppath) {
    println("no TTL policy file (" + ppath + ") — nothing to do")
    return
  }
  let raw = @backend_native.read_file(ppath)
  let policy = match @core.parse_ttl_policy(raw) {
    Some(p) => p
    None => raise @io.IoError::Invalid("invalid TTL policy file: " + ppath)
  }
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let (dropped, expired) = log.expire_by_policy(
      now_ms(),
      policy,
      apply=!dry_run,
      on_drop=seg => {
        @backend_native.remove_segment_files(dir, seg.base_offset)
        seg.writer.close()
      },
    )
    @backend_native.flush_meta(dir, log)
    close_log(log)
    if dry_run {
      println(
        "dry-run: would drop " +
        dropped.to_string() +
        " segment(s), " +
        expired.to_string() +
        " record(s) expired",
      )
    } else {
      append_ttl_audit(dir, @utf8.decode_lossy(raw), dropped, expired)
      println(
        "dropped " +
        dropped.to_string() +
        " segment(s), " +
        expired.to_string() +
        " record(s) expired (audited)",
      )
    }
  })
}

///|
/// Drop segments whose last record is older than now-ttl.
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
    // Automatic differentiated-TTL expiry when a policy file exists (3.4):
    // every serve/maintain pass re-evaluates retention and audits the run.
    let ttl_path = dir + "/TTL"
    if @backend_native.file_exists(ttl_path) {
      let raw_policy = @backend_native.read_file(ttl_path)
      match @core.parse_ttl_policy(raw_policy) {
        Some(policy) => {
          let (td, te) = log.expire_by_policy(now_ms(), policy, on_drop=seg => {
            @backend_native.remove_segment_files(dir, seg.base_offset)
            seg.writer.close()
          })
          append_ttl_audit(dir, @utf8.decode_lossy(raw_policy), td, te)
        }
        None => ()
      }
    }
    // Build the inverted/field-column sidecars so indexed queries load them
    // instead of rebuilding from data (3.2). Idempotent.
    for seg in log.segments {
      seg.ensure_inv_index()
    }
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
/// segments, fold expired records when a TTL is given, compress rolled-over
/// segments) and flush metadata, then sleep and repeat. `--every ms` (or
/// `MOONLOG_SERVE_INTERVAL`, default 60000) selects the pause between passes;
/// `--fsck-every N` runs a fast fsck every N cycles and prints its report;
/// `--once` runs a single pass and returns, which keeps the command
/// scriptable and testable.
fn cmd_serve(
  dir : String,
  max_str : String,
  ttl : String?,
  every : String?,
  fsck_every : String?,
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
  let fsck_n = match fsck_every {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid fsck interval: " + s)
      }
    None => 0
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
    if fsck_n > 0 && cycle % fsck_n == 0 {
      let lock = @backend_native.DirLock::acquire_timeout(
        dir,
        false,
        lock_timeout_ms(),
      )
      let log = open_log(dir)
      let report = log.verify_fast()
      println("fsck cycle " + cycle.to_string() + ":")
      print_verify(report)
      close_log(log)
      lock.release()
    }
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
/// Tier a directory into hot/warm/cold storage: rolled segments are
/// compressed in place (warm), and segments older than the newest `--warm N`
/// rolled ones are moved into `cold-dir` with symlinks left behind (cold), so
/// readers, verification and backups keep working unchanged. `--dry-run`
/// prints the plan without touching anything.
fn cmd_tier(
  dir : String,
  cold_dir : String,
  warm : String?,
  dry : Bool,
) -> Unit raise @io.IoError {
  let warm_n = match warm {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid warm count: " + s)
      }
    None => 1
  }
  if dry {
    run_locked(dir, false, () => {
      let log = open_log(dir)
      let n = log.segment_count()
      let cut = n - 1 - warm_n
      let to_move = if cut > 0 { cut } else { 0 }
      println(
        "tier plan: " +
        to_move.to_string() +
        " cold of " +
        n.to_string() +
        " segments (warm " +
        warm_n.to_string() +
        ")",
      )
      close_log(log)
    })
  } else {
    run_locked(dir, true, () => {
      let moved = @backend_native.tier_log_dir(dir, cold_dir, ROLL_SIZE, warm_n)
      println("tiered " + moved.to_string() + " segments cold into " + cold_dir)
    })
  }
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
const B64_ALPHABET : Bytes = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
const HEX_DIGITS : Bytes = b"0123456789abcdef"

///|
/// Base64-encode arbitrary bytes (RFC 4648, with `=` padding).
fn b64_encode(data : Bytes) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  let n = data.length()
  let mut i = 0
  while i + 3 <= n {
    let v = (data.at(i).to_int() << 16) |
      (data.at(i + 1).to_int() << 8) |
      data.at(i + 2).to_int()
    out.write_bytes(
      @core.slice(B64_ALPHABET, (v >> 18) & 63, ((v >> 18) & 63) + 1),
    )
    out.write_bytes(
      @core.slice(B64_ALPHABET, (v >> 12) & 63, ((v >> 12) & 63) + 1),
    )
    out.write_bytes(
      @core.slice(B64_ALPHABET, (v >> 6) & 63, ((v >> 6) & 63) + 1),
    )
    out.write_bytes(@core.slice(B64_ALPHABET, v & 63, (v & 63) + 1))
    i = i + 3
  }
  let rem = n - i
  if rem == 1 {
    let v = data.at(i).to_int() << 16
    out.write_bytes(
      @core.slice(B64_ALPHABET, (v >> 18) & 63, ((v >> 18) & 63) + 1),
    )
    out.write_bytes(
      @core.slice(B64_ALPHABET, (v >> 12) & 63, ((v >> 12) & 63) + 1),
    )
    out.write_bytes(b"==")
  } else if rem == 2 {
    let v = (data.at(i).to_int() << 16) | (data.at(i + 1).to_int() << 8)
    out.write_bytes(
      @core.slice(B64_ALPHABET, (v >> 18) & 63, ((v >> 18) & 63) + 1),
    )
    out.write_bytes(
      @core.slice(B64_ALPHABET, (v >> 12) & 63, ((v >> 12) & 63) + 1),
    )
    out.write_bytes(
      @core.slice(B64_ALPHABET, (v >> 6) & 63, ((v >> 6) & 63) + 1),
    )
    out.write_bytes(b"=")
  }
  out.to_bytes()
}

///|
/// Write `data` as a JSON string literal (with surrounding quotes) to `out`.
/// In text mode quotes, backslashes and control characters are escaped and
/// UTF-8 bytes pass through unchanged (output is valid JSON only when the
/// bytes are UTF-8); in base64 mode the bytes are base64 encoded first,
/// which is lossless for arbitrary binary.
fn write_json_string(out : @buffer.Buffer, data : Bytes, b64 : Bool) -> Unit {
  out.write_bytes(b"\"")
  if b64 {
    out.write_bytes(b64_encode(data))
  } else {
    let n = data.length()
    let mut i = 0
    while i < n {
      let b = data.at(i).to_int()
      if b == 34 {
        out.write_bytes(b"\\\"")
      } else if b == 92 {
        out.write_bytes(b"\\\\")
      } else if b == 8 {
        out.write_bytes(b"\\b")
      } else if b == 12 {
        out.write_bytes(b"\\f")
      } else if b == 10 {
        out.write_bytes(b"\\n")
      } else if b == 13 {
        out.write_bytes(b"\\r")
      } else if b == 9 {
        out.write_bytes(b"\\t")
      } else if b < 32 {
        out.write_bytes(b"\\u00")
        out.write_bytes(@core.slice(HEX_DIGITS, b / 16, b / 16 + 1))
        out.write_bytes(@core.slice(HEX_DIGITS, b % 16, b % 16 + 1))
      } else {
        out.write_bytes(@core.slice(data, i, i + 1))
      }
      i = i + 1
    }
  }
  out.write_bytes(b"\"")
}

///|
/// Export every record as JSON Lines (one self-contained JSON object per
/// line: `offset`, `timestamp`, `kind`, `key`, `value`). The default text
/// mode assumes keys/values are UTF-8 text; pass `base64` as the third
/// argument for a lossless encoding of arbitrary bytes.
fn cmd_export_jsonl(
  dir : String,
  file : String,
  mode : String,
) -> Unit raise @io.IoError {
  if mode != "text" && mode != "base64" {
    raise @io.IoError::Invalid("invalid mode: " + mode + " (text|base64)")
  }
  let b64 = mode == "base64"
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let buf = @buffer.Buffer::Buffer()
    let mut count = 0
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      buf.write_bytes(b"{\"offset\":")
      buf.write_bytes(@utf8.encode(rec.offset.to_string()))
      buf.write_bytes(b",\"timestamp\":")
      buf.write_bytes(@utf8.encode(rec.timestamp.to_string()))
      buf.write_bytes(b",\"kind\":")
      buf.write_bytes(if rec.is_delete() { b"\"delete\"" } else { b"\"put\"" })
      buf.write_bytes(b",\"key\":")
      write_json_string(buf, rec.key, b64)
      buf.write_bytes(b",\"value\":")
      write_json_string(buf, rec.value, b64)
      buf.write_bytes(b"}\n")
      count = count + 1
      true
    })
    @backend_native.write_file(file, buf.to_bytes())
    println("exported " + count.to_string() + " records")
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
/// Restore a backup made by `backup` into the empty directory `dst`, then
/// verify the restored copy (fast mode) so a silently corrupt backup is
/// caught before it is put into service.
fn cmd_restore(src : String, dst : String) -> Unit raise @io.IoError {
  let n = @backend_native.restore_log_dir(src, dst)
  println("restored " + n.to_string() + " segments to " + dst)
  run_locked(dst, false, () => {
    let log = open_log(dst)
    let report = log.verify_fast()
    print_verify(report)
    close_log(log)
  })
}

///|
/// Poll interval for `replicate --follow`, overridable with
/// `MOONLOG_REPLICATE_INTERVAL`.
fn replicate_interval_ms() -> Int32 {
  match @env.get_env_var("MOONLOG_REPLICATE_INTERVAL") {
    Some(v) => @string.parse_int(v) catch { _ => 200 }
    None => 200
  }
}

///|
/// One replicate pass: flush the source's data and metadata, then
/// incrementally mirror it into `dst`. Returns the number of segments copied.
/// A missing source fails the pass **without** recreating it — `ensure_dir`
/// would otherwise silently rebuild an empty primary and the following
/// backup pass would then prune the replica down to that empty state,
/// destroying the failover copy.
fn replicate_pass(src : String, dst : String) -> Int32 raise @io.IoError {
  if !@backend_native.file_exists(src) {
    raise @io.IoError::Invalid("source unavailable: " + src)
  }
  run_locked(src, true, () => {
    let log = open_log(src)
    log.flush()
    @backend_native.flush_meta(src, log)
    close_log(log)
    @backend_native.backup_log_dir(src, dst)
  })
}

///|
/// Continuous replica sync (3.5): one pass flushes the source's data and
/// metadata, then incrementally mirrors every changed segment, sidecar and
/// manifest into `dst` — the same engine as `backup`, so `dst` is always a
/// complete, fully usable log with preserved offsets and cursors. With
/// `--follow` the pass repeats on an interval (default 200ms,
/// `MOONLOG_REPLICATE_INTERVAL`); an unreachable, locked or corrupt source
/// only logs a WARN and retries, leaving the replica readable and writable
/// while the primary is down. Failover is directory-level: point reads and
/// writes at the replica (single-writer by convention — no automatic
/// arbitration), and rebalance by running `replicate` back from the promoted
/// replica once the old primary returns.
fn cmd_replicate(
  src : String,
  dst : String,
  follow : Bool,
) -> Unit raise @io.IoError {
  if follow {
    let mut was_ok = true
    while true {
      let n = replicate_pass(src, dst) catch { _ => -1 }
      if n < 0 {
        if was_ok {
          println("WARN replicate: source unavailable, retrying")
          was_ok = false
        }
      } else {
        if n > 0 || !was_ok {
          println("synced " + n.to_string() + " segment(s) to " + dst)
        }
        was_ok = true
      }
      @backend_native.sleep_ms(replicate_interval_ms())
    }
  } else {
    let n = replicate_pass(src, dst)
    println("synced " + n.to_string() + " segment(s) to " + dst)
  }
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
/// default 0); with `--name <cursor>` the persisted cursor is the named one.
/// With `--commit`, each batch advances that cursor so later runs resume
/// past it; run only one committing follower per cursor at a time. With
/// `--json`, records print as single-line JSON objects (UTF-8 text assumed)
/// instead of the plain form. With `--once`, a single pass is made and the
/// command returns (for scripts and tests).
fn cmd_follow(
  dir : String,
  start : String,
  once : Bool,
  commit : Bool,
  json : Bool,
  name : String?,
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
    from = match name {
      Some(n) => @backend_native.load_named_cursor(dir, n)
      None => @backend_native.load_cursor(dir)
    }
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
        if json {
          print_json_record(rec)
        } else {
          print_record(rec)
        }
      }
      fetched = fetched + recs.length()
      from = next
      if commit {
        match name {
          Some(n) => @backend_native.save_named_cursor(dir, n, from)
          None => @backend_native.save_cursor(dir, from)
        }
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
/// The file-name part of a path (after the last '/'), used to key the ingest
/// position cursor per source file.
fn path_basename(path : String) -> String {
  let mut last = -1
  let mut i = 0
  while i < path.length() {
    if path[i].to_int() == 47 {
      last = i
    }
    i = i + 1
  }
  if last < 0 {
    path
  } else {
    path[last + 1:path.length()].to_owned()
  }
}

///|
/// Split `data` into lines (ending at '\n', with a preceding '\r' stripped,
/// empty lines skipped). Returns the lines and how many bytes they occupy.
/// With `include_tail`, a trailing fragment without a newline is also a line
/// and counts as consumed; without it the fragment is left for the next read
/// so a poller never ingests a half-written line.
fn split_complete_lines(
  data : Bytes,
  include_tail : Bool,
) -> (Array[Bytes], Int64) {
  let out : Array[Bytes] = []
  let mut start = 0
  let mut consumed = 0
  let mut i = 0
  while i < data.length() {
    if data.at(i).to_int() == 10 {
      let mut end = i
      if end > start && data.at(end - 1).to_int() == 13 {
        end = end - 1
      }
      if end > start {
        out.push(@core.slice(data, start, end))
      }
      consumed = i + 1
      start = i + 1
    }
    i = i + 1
  }
  if include_tail && start < data.length() {
    let mut end = data.length()
    if end > start && data.at(end - 1).to_int() == 13 {
      end = end - 1
    }
    if end > start {
      out.push(@core.slice(data, start, end))
    }
    consumed = data.length()
  }
  (out, consumed.to_int64())
}

///|
/// Parse one raw line into `name=value` field pairs according to the format:
/// - `kv`: space-separated `name=value` pairs (as-is).
/// - `json`: top-level JSON object fields (numbers/booleans render as text;
///   malformed JSON yields no fields).
/// - `template`: `<name>` placeholders matched against `template`; lines that
///   do not match fall back to the whole line as the value.
/// - `lines`: no fields (the whole line is the value; key is the constant).
/// Returns `(key, value, fields)` where key/value are chosen per the options.
fn parse_ingest_line(
  line : Bytes,
  opts : IngestOptions,
) -> (Bytes, Bytes, Array[(Bytes, Bytes)]) {
  if opts.format == "kv" {
    let pairs = @core.parse_kv_pairs(line)
    let mut k : Bytes = opts.key_bytes
    let v = @buffer.Buffer::Buffer()
    let mut first = true
    for pair in pairs {
      if pair.0 == opts.field_bytes {
        k = pair.1
      } else {
        if !first {
          v.write_bytes(b" ")
        }
        first = false
        v.write_bytes(pair.0)
        v.write_bytes(b"=")
        v.write_bytes(pair.1)
      }
    }
    return (k, v.to_bytes(), pairs)
  }
  if opts.format == "json" {
    let fields = @core.json_object_fields(line) catch { _ => [] }
    return finish_parsed_fields(fields, line, opts)
  }
  if opts.format == "template" {
    return match opts.template_bytes {
      Some(t) =>
        match @core.parse_by_template(line, t) {
          Some(fields) => finish_parsed_fields(fields, line, opts)
          None => (opts.key_bytes, line, [])
        }
      None => (opts.key_bytes, line, [])
    }
  }
  (opts.key_bytes, line, [])
}

///|
/// Common field extraction for the json/template formats: `--key-field`
/// promotes a field to the record key (fallback constant "log"), and
/// `--value-field` picks the value field when given (fallback: the original
/// raw line).
fn finish_parsed_fields(
  fields : Array[(Bytes, Bytes)],
  raw_line : Bytes,
  opts : IngestOptions,
) -> (Bytes, Bytes, Array[(Bytes, Bytes)]) {
  let mut k : Bytes = opts.key_bytes
  let mut v : Bytes = raw_line
  for pair in fields {
    if pair.0 == opts.field_bytes {
      k = pair.1
    } else if pair.0 == opts.value_field_bytes {
      v = pair.1
    }
  }
  (k, v, fields)
}

///|
/// Read `[offset, current end)` of a file, or empty bytes when the file shrank
/// below `offset` or cannot be opened.
fn read_from(path : String, offset : Int64) -> Bytes {
  let size = @backend_native.file_size(path)
  if size <= offset {
    return b""
  }
  let f = @backend_native.NativeFileLog::open_readonly(path) catch {
    _ => return b""
  }
  let data = f.read_at(offset, (size - offset).to_int()) catch { _ => b"" }
  f.close()
  data
}

///|
/// Ingest a log file into the directory: parse each complete line as one
/// record and append it, flushing in batches. `--once` (default) reads up to
/// the current end and returns; `--follow` keeps polling for appended lines.
/// The consumed byte position is persisted as the named cursor
/// `ingest-<basename>` so later runs resume instead of replaying, unless
/// `--from <bytes>` overrides it. A truncated or rotated file (size dropping
/// below the position) restarts from zero, and a missing file is waited for
/// in follow mode.
fn cmd_ingest(
  dir : String,
  file : String,
  follow : Bool,
  fifo : Bool,
  opts : IngestOptions,
  interval : String?,
) -> Unit raise @io.IoError {
  let interval_ms = match interval {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid interval: " + s)
      }
    None => 200
  }
  if fifo {
    cmd_ingest_fifo(dir, file, opts)
    return
  }
  let cursor_name = "ingest-" + path_basename(file)
  let mut pos : Int64 = match opts.from_bytes {
    Some(b) => b
    None =>
      @backend_native.load_named_cursor(dir, cursor_name).reinterpret_as_int64()
  }
  let mut total = 0
  let mut duplicates = 0
  let mut sampled_out = 0
  let mut go = true
  while go {
    let size = @backend_native.file_size(file)
    if size >= (0 : Int64) && size < pos {
      pos = 0
    }
    if size > pos {
      let data = read_from(file, pos)
      let (lines, consumed) = split_complete_lines(data, !follow)
      let (written, sampled) = ingest_lines(dir, lines, opts)
      duplicates = duplicates + (lines.length() - written - sampled)
      sampled_out = sampled_out + sampled
      total = total + written
      pos = pos + consumed
      @backend_native.save_named_cursor(
        dir,
        cursor_name,
        pos.reinterpret_as_uint64(),
      )
    }
    if follow {
      @backend_native.sleep_ms(interval_ms)
    } else {
      go = false
    }
  }
  let dup_note = if duplicates > 0 {
    " (" + duplicates.to_string() + " duplicates skipped)"
  } else {
    ""
  }
  let sampled_note = if sampled_out > 0 {
    " (" + sampled_out.to_string() + " sampled out)"
  } else {
    ""
  }
  println(
    "ingested " +
    total.to_string() +
    " records" +
    dup_note +
    sampled_note +
    " (position " +
    pos.to_string() +
    ", cursor " +
    cursor_name +
    ")",
  )
}

///|
/// Record timestamp for a parsed field set: the `--ts-field` value when
/// present and parsable — through `normalize_ts`, so any numeric precision
/// (s/ms/µs/ns) or ISO-8601 zone offset is accepted — else the fallback
/// (arrival order based).
fn ingest_timestamp(
  fields : Array[(Bytes, Bytes)],
  opts : IngestOptions,
  fallback : Int64,
) -> Int64 {
  match opts.ts_field_bytes {
    Some(fb) => {
      let mut found : Int64? = None
      for pair in fields {
        if pair.0 == fb {
          found = Some(@core.normalize_ts(pair.1, fallback))
        }
      }
      match found {
        Some(t) => t
        None => fallback
      }
    }
    None => fallback
  }
}

///|
/// Unified-schema transform for one parsed line: extract the six canonical
/// fields, promote `service` to the record key, re-serialize the standard
/// fields into the value, and pick up the schema timestamp when present.
/// A line with no canonical fields keeps its original key/value (the ts
/// stays None so the regular timestamp path applies).
fn schema_transform(
  key : Bytes,
  value : Bytes,
  fields : Array[(Bytes, Bytes)],
  fallback_ts : Int64,
) -> (Bytes, Bytes, Int64?) {
  let f = @core.schema_from_fields(fields, fallback_ts)
  let k = match f.service {
    Some(s) => s
    None => key
  }
  let v = @core.schema_value(f)
  let v2 = if v.length() == 0 { value } else { v }
  (k, v2, f.ts)
}

///|
/// Append parsed lines to the log in batches of `opts.batch_n`, flushing and
/// persisting metadata per batch. With `idempotent`, a line whose (key, value)
/// matches the key's latest live record is recognized as a duplicate delivery
/// and skipped. With a sampling config, lines are filtered at the source
/// (severity, include/exclude rules, deterministic rate). Returns `(written,
/// sampled_out)` — the number of records actually appended and how many the
/// sampler dropped.
fn ingest_lines(
  dir : String,
  lines : Array[Bytes],
  opts : IngestOptions,
) -> (Int32, Int32) raise @io.IoError {
  let ts_base = now_ms()
  let mut written = 0
  let mut sampled_out = 0
  let mut i = 0
  while i < lines.length() {
    let chunk_end = if i + opts.batch_n < lines.length() {
      i + opts.batch_n
    } else {
      lines.length()
    }
    let mut chunk_written = 0
    let mut chunk_sampled = 0
    run_locked(dir, true, () => {
      let log = open_log(dir, partition=opts.partition_ms)
      let mut j = i
      while j < chunk_end {
        let (raw_k, raw_v, fields) = parse_ingest_line(lines[j], opts)
        let (k, v, schema_ts) = if opts.schema {
          schema_transform(raw_k, raw_v, fields, ts_base + j.to_int64())
        } else {
          (raw_k, raw_v, None)
        }
        // 2.4: mask sensitive content and append enrichment metadata before
        // the value reaches the log, so nothing sensitive lands on disk and
        // idempotent re-delivery sees the same (key, value).
        let v_masked = if opts.mask {
          @core.mask_sensitive(v, opts.mask_extra)
        } else {
          v
        }
        let v = match opts.meta_bytes {
          Some(m) =>
            if v_masked.length() == 0 {
              m
            } else {
              v_masked + b" " + m
            }
          None => v_masked
        }
        let keep = match opts.sampling {
          Some(cfg) => @core.sampling_allows(lines[j], fields, cfg)
          None => true
        }
        if keep {
          let raw_ts = match schema_ts {
            Some(t) => t
            None => ingest_timestamp(fields, opts, ts_base + j.to_int64())
          }
          // 2.3 clock-skew correction: a fixed offset (ms) applied to every
          // record timestamp, compensating a slow/fast source clock.
          let rec_ts = raw_ts + opts.clock_skew_ms
          if opts.idempotent {
            let (added, _) = log.append_idempotent(k, v, rec_ts)
            if added {
              chunk_written = chunk_written + 1
            }
          } else {
            ignore(log.append(k, v, rec_ts))
            chunk_written = chunk_written + 1
          }
        } else {
          chunk_sampled = chunk_sampled + 1
        }
        j = j + 1
      }
      log.flush()
      @backend_native.flush_meta(dir, log)
      close_log(log)
    })
    written = written + chunk_written
    sampled_out = sampled_out + chunk_sampled
    i = chunk_end
  }
  (written, sampled_out)
}

///|
/// Split a comma-separated CLI value into parts (empty trailing parts kept;
/// callers filter as needed).
fn split_comma(s : String) -> Array[String] {
  let parts : Array[String] = []
  let mut cur = StringBuilder()
  for ch in s {
    if ch == ',' {
      parts.push(cur.to_string())
      cur = StringBuilder()
    } else {
      cur.write_char(ch)
    }
  }
  parts.push(cur.to_string())
  parts
}

///|
/// Encode the non-empty parts of a comma-separated list as Bytes entries.
fn csv_to_bytes_list(s : String) -> Array[Bytes] {
  let arr : Array[Bytes] = []
  for part in split_comma(s) {
    if part.length() > 0 {
      arr.push(@utf8.encode(part))
    }
  }
  arr
}

///|
/// Encode comma-separated `k=v` pairs into a single `k1=v1 k2=v2` bytes
/// sequence appended to every record value (2.4 field enrichment: env,
/// version, region and other deployment metadata).
fn parse_meta_pairs(s : String) -> Bytes raise @io.IoError {
  let buf = @buffer.Buffer::Buffer()
  let mut first = true
  for part in split_comma(s) {
    let kb = StringBuilder()
    let vb = StringBuilder()
    let mut side = 0
    for ch in part {
      if side == 0 {
        if ch == '=' {
          side = 1
        } else {
          kb.write_char(ch)
        }
      } else {
        vb.write_char(ch)
      }
    }
    if side != 1 || kb.to_string().length() == 0 {
      raise @io.IoError::Invalid(
        "invalid meta pair: " + part + " (expected k=v)",
      )
    }
    if !first {
      buf.write_bytes(b" ")
    }
    first = false
    buf.write_bytes(@utf8.encode(kb.to_string()))
    buf.write_bytes(b"=")
    buf.write_bytes(@utf8.encode(vb.to_string()))
  }
  buf.to_bytes()
}

///|
/// Parse the sampling options shared by `ingest` and `http`: `--min-level`,
/// `--level-field`, `--sample-rate`, `--include`, `--exclude`. Returns None
/// when no sampling knob was given (the zero-overhead path).
fn parse_sampling_config(
  min_level_str : String?,
  level_field_str : String?,
  sample_rate_str : String?,
  include_str : String?,
  exclude_str : String?,
) -> @core.SamplingConfig? raise @io.IoError {
  let min_level = match min_level_str {
    Some(s) =>
      match s {
        "debug" => 0
        "info" => 1
        "warn" => 2
        "warning" => 2
        "error" => 3
        "fatal" => 4
        _ =>
          raise @io.IoError::Invalid(
            "invalid level: " + s + " (debug|info|warn|error|fatal)",
          )
      }
    None => -1
  }
  let rate = match sample_rate_str {
    Some(s) => {
      let r = @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid sample rate: " + s)
      }
      if r < 0 || r > 100 {
        raise @io.IoError::Invalid("sample rate must be 0-100")
      }
      r
    }
    None => 100
  }
  let include_bytes = match include_str {
    Some(s) => @utf8.encode(s)
    None => b""
  }
  let exclude_bytes = match exclude_str {
    Some(s) => @utf8.encode(s)
    None => b""
  }
  let level_field = @utf8.encode(
    match level_field_str {
      Some(f) => f
      None => "level"
    },
  )
  if min_level < 0 &&
    rate >= 100 &&
    include_bytes.length() == 0 &&
    exclude_bytes.length() == 0 {
    return None
  }
  Some({
    min_level,
    level_field,
    sample_rate: rate,
    include_text: include_bytes,
    exclude_text: exclude_bytes,
  })
}

///|
/// Apply the sampling pipeline to raw lines before they enter the HTTP queue.
/// Returns the kept lines and how many were sampled out.
fn sampling_filter_lines(
  lines : Array[Bytes],
  opts : IngestOptions,
) -> (Array[Bytes], Int32) {
  match opts.sampling {
    None => (lines, 0)
    Some(cfg) => {
      let kept : Array[Bytes] = []
      let mut dropped = 0
      for line in lines {
        let (_, _, fields) = parse_ingest_line(line, opts)
        if @core.sampling_allows(line, fields, cfg) {
          kept.push(line)
        } else {
          dropped = dropped + 1
        }
      }
      (kept, dropped)
    }
  }
}

///|
/// Subscribe to a FIFO (named pipe): block until a writer appears, ingest the
/// complete lines it writes until it closes, then wait for the next writer.
/// A partially written trailing line is held until the following chunk.
fn cmd_ingest_fifo(
  dir : String,
  path : String,
  opts : IngestOptions,
) -> Unit raise @io.IoError {
  let mut total = 0
  while true {
    let fd = @backend_native.open_read_blocking(path)
    if fd < 0 {
      raise @io.IoError::Syscall(fd)
    }
    let mut leftover = b""
    let mut eof = false
    while !eof {
      let chunk = @backend_native.read_blocking(fd, 4096)
      if chunk.length() == 0 {
        eof = true
      } else {
        let data = leftover + chunk
        let (lines, consumed) = split_complete_lines(data, false)
        leftover = @core.slice(data, consumed.to_int(), data.length())
        if lines.length() > 0 {
          let (written, _) = ingest_lines(dir, lines, opts)
          total = total + written
        }
      }
    }
    @backend_native.close_fd(fd)
    println("ingested " + total.to_string() + " records (fifo " + path + ")")
  }
}

///|
/// Index just past the header terminator (`\r\n\r\n`), or -1 when not yet seen.
fn find_header_end(data : Bytes) -> Int32 {
  let mut i = 0
  while i + 3 < data.length() {
    if data.at(i).to_int() == 13 &&
      data.at(i + 1).to_int() == 10 &&
      data.at(i + 2).to_int() == 13 &&
      data.at(i + 3).to_int() == 10 {
      return i + 4
    }
    i = i + 1
  }
  -1
}

///|
/// Write one HTTP response with a JSON (or plain) body and close the
/// connection (`Connection: close`).
fn http_respond(conn : Int32, status : Int32, body : String) -> Unit {
  let reason = if status == 200 {
    "OK"
  } else if status == 202 {
    "Accepted"
  } else if status == 400 {
    "Bad Request"
  } else if status == 404 {
    "Not Found"
  } else if status == 429 {
    "Too Many Requests"
  } else {
    "Error"
  }
  let retry = if status == 429 { "Retry-After: 1\r\n" } else { "" }
  let body_bytes = @utf8.encode(body)
  let head = "HTTP/1.1 " +
    status.to_string() +
    " " +
    reason +
    "\r\n" +
    retry +
    "Content-Type: application/json\r\nContent-Length: " +
    body_bytes.length().to_string() +
    "\r\nConnection: close\r\n\r\n"
  ignore(@backend_native.conn_write(conn, @utf8.encode(head)))
  ignore(@backend_native.conn_write(conn, body_bytes))
}

///|
/// Bounded in-flight queue for the HTTP push server: received lines wait here
/// while the writer drains them in batches of `batch`. When a request would
/// exceed `capacity`, it is rejected with 429 (explicit backpressure — the
/// client retries, nothing is dropped silently). Sustained backlog beyond
/// `alert_threshold` raises a warning and increments `alerts`.
struct HttpQueue {
  mut lines : Array[Bytes]
  mut head : Int32
  mut pending : Int32
  capacity : Int32
  batch : Int32
  alert_threshold : Int32
  mut alerts : Int32
  opts : IngestOptions
}

///|
/// Offer `lines` to the queue; false when they would exceed the capacity.
fn http_queue_enqueue(q : HttpQueue, lines : Array[Bytes]) -> Bool {
  if q.pending + lines.length() > q.capacity {
    return false
  }
  for line in lines {
    q.lines.push(line)
  }
  q.pending = q.pending + lines.length()
  true
}

///|
/// Write one batch from the queue head, compact the backing array periodically,
/// and raise a warning when the backlog exceeds the alert threshold.
fn http_queue_drain(q : HttpQueue, dir : String) -> Unit raise @io.IoError {
  if q.pending <= 0 {
    return
  }
  let take = if q.pending < q.batch { q.pending } else { q.batch }
  let chunk : Array[Bytes] = []
  let mut i = 0
  while i < take {
    chunk.push(q.lines[q.head + i])
    i = i + 1
  }
  q.head = q.head + take
  q.pending = q.pending - take
  ignore(ingest_lines(dir, chunk, q.opts))
  if q.head > 4096 && q.head * 2 > q.lines.length() {
    let rest : Array[Bytes] = []
    let mut j = q.head
    while j < q.lines.length() {
      rest.push(q.lines[j])
      j = j + 1
    }
    q.lines = rest
    q.head = 0
  }
  if q.pending > q.alert_threshold {
    q.alerts = q.alerts + 1
    println(
      "WARN backlog " +
      q.pending.to_string() +
      " lines (threshold " +
      q.alert_threshold.to_string() +
      ")",
    )
  }
}

///|
/// Handle one HTTP connection: read the head and body, route, respond. POST
/// payloads are buffered into `q` (the drain loop writes them); the writer's
/// parsing options live with the queue.
fn handle_http_connection(
  dir : String,
  conn : Int32,
  q : HttpQueue,
) -> Unit raise @io.IoError {
  let mut head = b""
  let mut header_end = -1
  let mut rounds = 0
  while header_end < 0 && rounds < 16 {
    let chunk = @backend_native.conn_read(conn, 4096)
    if chunk.length() == 0 {
      break
    }
    head = head + chunk
    header_end = find_header_end(head)
    rounds = rounds + 1
  }
  if header_end < 0 {
    http_respond(conn, 400, "{\"error\":\"bad request\"}")
    return
  }
  let request = match
    @core.parse_http_request(@core.slice(head, 0, header_end)) {
    Some(r) => r
    None => {
      http_respond(conn, 400, "{\"error\":\"bad request line\"}")
      return
    }
  }
  let mut body = @core.slice(head, header_end, head.length())
  while body.length() < request.content_length && body.length() < 1_048_576 {
    let chunk = @backend_native.conn_read(conn, 4096)
    if chunk.length() == 0 {
      break
    }
    body = body + chunk
  }
  let is_get = request.verb == b"GET"
  let is_post = request.verb == b"POST"
  if is_get && request.path == b"/health" {
    http_respond(conn, 200, "{\"status\":\"ok\"}")
  } else if is_get && request.path == b"/stats" {
    run_locked(dir, false, () => {
      let log = open_log(dir)
      let payload = "{\"records\":" +
        log.count().to_string() +
        ",\"segments\":" +
        log.segment_count().to_string() +
        ",\"next_offset\":" +
        log.next_offset().to_string() +
        ",\"pending\":" +
        q.pending.to_string() +
        ",\"backlog_alerts\":" +
        q.alerts.to_string() +
        "}"
      http_respond(conn, 200, payload)
      close_log(log)
    })
  } else if is_post && (request.path == b"/" || request.path == b"/push") {
    let (lines, _) = split_complete_lines(body, true)
    if lines.length() > 10000 {
      http_respond(conn, 400, "{\"error\":\"too many lines\"}")
      return
    }
    // Source-side sampling runs before the queue, so the capacity below counts
    // only lines that will actually be written.
    let (kept, sampled_out) = sampling_filter_lines(lines, q.opts)
    if http_queue_enqueue(q, kept) {
      http_respond(
        conn,
        202,
        "{\"accepted\":" +
        kept.length().to_string() +
        ",\"sampled_out\":" +
        sampled_out.to_string() +
        ",\"pending\":" +
        q.pending.to_string() +
        "}",
      )
    } else {
      // Explicit backpressure: the request was not buffered, so the client can
      // retry the same payload — nothing is dropped silently.
      http_respond(
        conn,
        429,
        "{\"error\":\"backlog full\",\"pending\":" +
        q.pending.to_string() +
        ",\"retry_after_ms\":1000}",
      )
    }
  } else {
    http_respond(conn, 404, "{\"error\":\"not found\"}")
  }
}

///|
/// Serve an HTTP push endpoint on 127.0.0.1:`port`: `POST /` (or `/push`) with
/// a body of log lines ingests them (same `--format`/`--key-field`/`--ts-field`
/// parsing as `ingest`), `GET /health` returns status, `GET /stats` returns
/// record/segment counts. Connections are handled serially; run until
/// interrupted.
fn cmd_http(
  dir : String,
  port : String?,
  queue_cap : String?,
  batch : String?,
  backlog_alert : String?,
  opts : IngestOptions,
) -> Unit raise @io.IoError {
  if opts.format != "lines" && opts.format != "kv" {
    raise @io.IoError::Invalid("invalid format: " + opts.format + " (lines|kv)")
  }
  let port_n = match port {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid port: " + s)
      }
    None => 8080
  }
  let queue_cap_n = match queue_cap {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid queue size: " + s)
      }
    None => 10000
  }
  let batch_n = match batch {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid batch: " + s)
      }
    None => 256
  }
  let backlog_alert_n = match backlog_alert {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid backlog alert: " + s)
      }
    None => 5000
  }
  if queue_cap_n <= 0 || batch_n <= 0 || backlog_alert_n < 0 {
    raise @io.IoError::Invalid(
      "queue and batch must be positive, backlog alert non-negative",
    )
  }
  let listen_fd = @backend_native.tcp_listen(port_n)
  if listen_fd < 0 {
    raise @io.IoError::Invalid(
      "cannot listen on 127.0.0.1:" +
      port_n.to_string() +
      " (code " +
      listen_fd.to_string() +
      ")",
    )
  }
  println(
    "moonlog http listening on http://127.0.0.1:" +
    port_n.to_string() +
    "  (POST / or /push, GET /health, GET /stats; queue " +
    queue_cap_n.to_string() +
    " lines, batch " +
    batch_n.to_string() +
    ", backlog alert " +
    backlog_alert_n.to_string() +
    ")",
  )
  let q : HttpQueue = {
    lines: [],
    head: 0,
    pending: 0,
    capacity: queue_cap_n,
    batch: batch_n,
    alert_threshold: backlog_alert_n,
    alerts: 0,
    opts,
  }
  @backend_native.install_shutdown_handler()
  let mut stopping = false
  while !stopping {
    // Drain one batch first, so a burst backlog keeps shrinking even while no
    // new client connects (the accept below times out and loops back here).
    http_queue_drain(q, dir)
    stopping = @backend_native.shutdown_requested()
    if !stopping {
      let conn = @backend_native.tcp_accept_timeout(listen_fd, 200)
      if conn >= 0 {
        handle_http_connection(dir, conn, q)
        @backend_native.close_fd(conn)
      }
    }
  }
  // Graceful shutdown: write every buffered line before exiting, so nothing
  // accepted with 202 is lost.
  while q.pending > 0 {
    http_queue_drain(q, dir)
  }
  println(
    "moonlog http shut down (backlog drained, " +
    q.alerts.to_string() +
    " backlog alerts total)",
  )
}

///|
/// Match `needle` inside `hay`, optionally folding ASCII case.
fn match_needle(hay : Bytes, needle : Bytes, ignore_case : Bool) -> Bool {
  if ignore_case {
    @core.bytes_contains_ci(hay, needle)
  } else {
    @core.bytes_contains(hay, needle)
  }
}

///|
/// Full-text search: stream records in offset order and print those whose key
/// and/or value contains `text`. The linear scan costs O(records) per query;
/// with `--inverted` the per-segment inverted index (built lazily on first
/// use, persisted as the `<base>.log.inv` sidecar) preselects candidates and
/// a record matches when any query token occurs as a full word in its key or
/// value (ASCII case-folded) — word-level semantics, unlike the substring
/// scan. `--field`
/// selects `both` (default), `key` or `value` (ignored with `--inverted`);
/// `--ignore-case` folds ASCII
/// case; `--limit` stops early; `--from`/`--to` bound the offset range.
fn cmd_search(
  dir : String,
  text : String,
  field : String,
  ignore_case : Bool,
  limit : String?,
  from : String?,
  to : String?,
  inverted : Bool,
) -> Unit raise @io.IoError {
  if field != "both" && field != "key" && field != "value" {
    raise @io.IoError::Invalid("invalid field: " + field + " (both|key|value)")
  }
  let needle = @utf8.encode(text)
  let max_hits = match limit {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid limit: " + s)
      }
    None => -1
  }
  if inverted {
    let toks = @segment.tokenize(@utf8.encode(text), 16)
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
      let mut hits = 0
      let mut stop = false
      for seg in log.segments {
        if stop {
          break
        }
        seg.ensure_inv_index()
        let seen : @hashmap.HashMap[UInt64, Bool] = @hashmap.HashMap::HashMap([])
        for tok in toks {
          for idx in seg.inv_term_postings(tok) {
            let off = seg.base_offset + idx.to_uint64()
            if off >= lo && off < hi {
              seen.set(off, true)
            }
          }
        }
        let cands : Array[UInt64] = []
        seen.each(fn(k, _) { cands.push(k) })
        cands
        .mut_view()
        .sort_by(fn(a, b) {
          let d = a.compare(b)
          if d < 0 {
            -1
          } else if d > 0 {
            1
          } else {
            0
          }
        })
        for off in cands {
          if max_hits >= 0 && hits >= max_hits {
            stop = true
            break
          }
          let rec = log.get(off) catch { _ => None }
          match rec {
            Some(r) => {
              print_record(r)
              hits = hits + 1
            }
            None => ()
          }
        }
      }
      println("(" + hits.to_string() + " matches) (inverted)")
      close_log(log)
    })
    return
  }
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
    let mut hits = 0
    log.for_each_while(lo, hi, rec => {
      let hit = if field == "key" {
        match_needle(rec.key, needle, ignore_case)
      } else if field == "value" {
        match_needle(rec.value, needle, ignore_case)
      } else {
        match_needle(rec.key, needle, ignore_case) ||
        match_needle(rec.value, needle, ignore_case)
      }
      if hit {
        print_record(rec)
        hits = hits + 1
      }
      max_hits < 0 || hits < max_hits
    })
    println("(" + hits.to_string() + " matches)")
    close_log(log)
  })
}

///|
/// Unified-schema query: stream records in offset order and keep those that
/// match every given condition (AND). `--service` matches the record key
/// (schema ingest stores the service name as the key) or a parsed service
/// field; `--level`, `--host` and `--trace-id` match parsed fields;
/// `--contains` matches the raw value as an ASCII case-insensitive substring;
/// `--since`/`--until` bound the record timestamp (epoch ms, inclusive);
/// `--limit` stops early. With `--sort-by-time`, matches are collected and
/// printed ordered by event time (ties keep offset order) instead of the
/// arrival (offset) order — the standard answer to out-of-order delivery.
/// With `--indexed`, the first given equality filter (`--level`/`--service`/
/// `--host`/`--trace-id`) preselects candidates through the per-segment
/// field-column index (`name=value` postings, service also via the record
/// key) before the full AND refinement — no equality filter falls back to
/// the linear scan. Output is the standard record line, or JSON with
/// `--json`. Non-schema records still match `--service` via the key and
/// `--contains` via the value, so mixed directories stay queryable.
fn cmd_query(
  dir : String,
  level : String?,
  service : String?,
  host : String?,
  trace_id : String?,
  contains : String?,
  since : String?,
  until : String?,
  limit : String?,
  indexed : Bool,
  sort_by_time : Bool,
  json : Bool,
) -> Unit raise @io.IoError {
  let level_b : Bytes? = match level {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  let service_b : Bytes? = match service {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  let host_b : Bytes? = match host {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  let trace_b : Bytes? = match trace_id {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  let contains_b : Bytes? = match contains {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  let since_ts : Int64? = match since {
    Some(s) =>
      Some(
        @string.parse_int64(s) catch {
          _ => raise @io.IoError::Invalid("invalid since: " + s)
        },
      )
    None => None
  }
  let until_ts : Int64? = match until {
    Some(s) =>
      Some(
        @string.parse_int64(s) catch {
          _ => raise @io.IoError::Invalid("invalid until: " + s)
        },
      )
    None => None
  }
  let max_hits = match limit {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid limit: " + s)
      }
    None => -1
  }
  // --indexed: the first given equality filter preselects candidates through
  // the per-segment field-column index; the full AND refinement still runs.
  let idx_sel : (Bytes, Bytes, Bool)? = if indexed {
    match level_b {
      Some(l) => Some((b"level", l, false))
      None =>
        match service_b {
          Some(s) => Some((b"service", s, true))
          None =>
            match host_b {
              Some(h) => Some((b"host", h, false))
              None =>
                match trace_b {
                  Some(t) => Some((b"trace_id", t, false))
                  None => None
                }
            }
        }
    }
  } else {
    None
  }
  match idx_sel {
    Some((fname, fval, also_key)) => {
      run_locked(dir, false, () => {
        let log = open_log(dir)
        let mut hits = 0
        let mut stop = false
        for seg in log.segments {
          if stop {
            break
          }
          seg.ensure_inv_index()
          let seen : @hashmap.HashMap[UInt64, Bool] = @hashmap.HashMap::HashMap([],
          )
          for i2 in seg.inv_field_postings(fname, fval) {
            let off = seg.base_offset + i2.to_uint64()
            seen.set(off, true)
          }
          if also_key {
            for i2 in seg.inv_field_postings(b"__key__", fval) {
              let off = seg.base_offset + i2.to_uint64()
              seen.set(off, true)
            }
          }
          let cands : Array[UInt64] = []
          seen.each(fn(k, _) { cands.push(k) })
          cands
          .mut_view()
          .sort_by(fn(a, b) {
            let d = a.compare(b)
            if d < 0 {
              -1
            } else if d > 0 {
              1
            } else {
              0
            }
          })
          for off in cands {
            if max_hits >= 0 && hits >= max_hits {
              stop = true
              break
            }
            let rec = log.get(off) catch { _ => None }
            match rec {
              Some(r) => {
                let mut hit = true
                match since_ts {
                  Some(t) => if r.timestamp < t { hit = false }
                  None => ()
                }
                match until_ts {
                  Some(t) => if r.timestamp > t { hit = false }
                  None => ()
                }
                if hit {
                  let fields = @core.parse_kv_pairs(r.value)
                  hit = @core.schema_matches(
                    fields,
                    r.key,
                    r.value,
                    level_b,
                    service_b,
                    host_b,
                    trace_b,
                    contains_b,
                  )
                }
                if hit {
                  if json {
                    print_json_record(r)
                  } else {
                    print_record(r)
                  }
                  hits = hits + 1
                }
              }
              None => ()
            }
          }
        }
        println("(" + hits.to_string() + " matches) (indexed)")
        close_log(log)
      })
      return
    }
    None => ()
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let mut hits = 0
    let collected : Array[@core.Record] = []
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      let mut hit = true
      match since_ts {
        Some(t) => if rec.timestamp < t { hit = false }
        None => ()
      }
      match until_ts {
        Some(t) => if rec.timestamp > t { hit = false }
        None => ()
      }
      if hit {
        let fields = @core.parse_kv_pairs(rec.value)
        hit = @core.schema_matches(
          fields,
          rec.key,
          rec.value,
          level_b,
          service_b,
          host_b,
          trace_b,
          contains_b,
        )
      }
      if hit {
        if sort_by_time {
          collected.push(rec)
        } else if json {
          print_json_record(rec)
        } else {
          print_record(rec)
        }
        hits = hits + 1
      }
      max_hits < 0 || hits < max_hits
    })
    if sort_by_time {
      collected
      .mut_view()
      .sort_by(fn(a, b) {
        let c = a.timestamp.compare(b.timestamp)
        if c < 0 {
          -1
        } else if c > 0 {
          1
        } else {
          let d = a.offset.compare(b.offset)
          if d < 0 {
            -1
          } else if d > 0 {
            1
          } else {
            0
          }
        }
      })
      for rec in collected {
        if json {
          print_json_record(rec)
        } else {
          print_record(rec)
        }
      }
    }
    println("(" + hits.to_string() + " matches)")
    close_log(log)
  })
}

///|
/// Print the records around `offset`: up to `--before N` (default 3) before
/// and `--after N` (default 3) after it, clamped to the log bounds. The
/// target record itself is included (crossing segment boundaries as needed).
fn cmd_context(
  dir : String,
  offset : String,
  before : String?,
  after : String?,
) -> Unit raise @io.IoError {
  let target = parse_offset(offset)
  let b = match before {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid before: " + s)
      }
    None => 3
  }
  let a = match after {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid after: " + s)
      }
    None => 3
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let next = log.next_offset()
    let bu = b.to_uint64()
    let au = (a + 1).to_uint64()
    let lo = if target > bu { target - bu } else { (0 : UInt64) }
    let hi = if target + au < next { target + au } else { next }
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
/// Increment the count for a byte-keyed bucket.
fn bump_bytes(counts : @hashmap.HashMap[Bytes, Int32], key : Bytes) -> Unit {
  match counts.get(key) {
    Some(c) => counts.set(key, c + 1)
    None => counts.set(key, 1)
  }
}

///|
/// Increment the count for a string-keyed bucket.
fn bump_string(counts : @hashmap.HashMap[String, Int32], key : String) -> Unit {
  match counts.get(key) {
    Some(c) => counts.set(key, c + 1)
    None => counts.set(key, 1)
  }
}

///|
/// Sort `(bucket, count)` pairs by count descending and keep the top `top_n`.
fn top_counts(
  items : Array[(Bytes, Int32)],
  top_n : Int32,
) -> Array[(Bytes, Int32)] {
  items.sort_by(fn(a, b) {
    if a.1 > b.1 {
      -1
    } else if a.1 < b.1 {
      1
    } else {
      0
    }
  })
  let out : Array[(Bytes, Int32)] = []
  let n = if items.length() < top_n { items.length() } else { top_n }
  let mut i = 0
  while i < n {
    out.push(items[i])
    i = i + 1
  }
  out
}

///|
/// Multi-dimensional aggregation: count records per bucket and print the top
/// buckets. `--by` selects the dimension: `key` (default), `value`, `kind`,
/// `hour` (UTC hour label) or `prefix:<N>` (first N key bytes). `--kv-field
/// <name>` instead buckets by the `name=value` field inside the value
/// (records without it bucket as `<missing>`). `--match <text>` limits to
/// records containing the text (ASCII case-insensitive, key or value).
/// `--json` emits the buckets as JSON.
fn cmd_aggregate(
  dir : String,
  by : String,
  kv_field : String?,
  match_text : String?,
  top : String?,
  json : Bool,
) -> Unit raise @io.IoError {
  let top_n = match top {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid top count: " + s)
      }
    None => 20
  }
  let is_prefix = by.has_prefix("prefix:")
  let prefix_n = if is_prefix {
    @string.parse_int(by[7:by.length()].to_owned()) catch {
      _ => raise @io.IoError::Invalid("invalid prefix dimension: " + by)
    }
  } else {
    0
  }
  if by != "key" && by != "value" && by != "kind" && by != "hour" && !is_prefix {
    raise @io.IoError::Invalid(
      "invalid dimension: " + by + " (key|value|kind|hour|prefix:N)",
    )
  }
  let needle : Bytes? = match match_text {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  let field : Bytes? = match kv_field {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let counts : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([])
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      let pass = match needle {
        Some(n) =>
          match_needle(rec.key, n, true) || match_needle(rec.value, n, true)
        None => true
      }
      if pass {
        let bucket : Bytes = match field {
          Some(f) => {
            let pairs = @core.parse_kv_pairs(rec.value)
            let mut found : Bytes? = None
            for pair in pairs {
              if pair.0 == f {
                found = Some(pair.1)
              }
            }
            match found {
              Some(v) => v
              None => b"<missing>"
            }
          }
          None =>
            if by == "value" {
              rec.value
            } else if by == "kind" {
              if rec.is_delete() {
                b"delete"
              } else {
                b"put"
              }
            } else if by == "hour" {
              @utf8.encode(@core.format_utc(rec.timestamp, "hour"))
            } else if is_prefix {
              let len = if prefix_n < rec.key.length() {
                prefix_n
              } else {
                rec.key.length()
              }
              @core.slice(rec.key, 0, len)
            } else {
              rec.key
            }
        }
        bump_bytes(counts, bucket)
      }
      true
    })
    let items : Array[(Bytes, Int32)] = []
    for k in counts.keys() {
      match counts.get(k) {
        Some(c) => items.push((k, c))
        None => ()
      }
    }
    let shown = top_counts(items, top_n)
    if json {
      let by_label = match kv_field {
        Some(f) => "kv:" + f
        None => by
      }
      let mut s = "{\"by\":\"" + by_label + "\",\"buckets\":["
      let mut first = true
      for item in shown {
        if !first {
          s = s + ","
        }
        first = false
        s = s +
          "{\"bucket\":\"" +
          json_escape_str(bytes_to_string(item.0)) +
          "\",\"count\":" +
          item.1.to_string() +
          "}"
      }
      s = s + "],\"total_buckets\":" + counts.length().to_string() + "}"
      println(s)
    } else {
      println("count  bucket")
      for item in shown {
        println(item.1.to_string() + "  " + bytes_to_string(item.0))
      }
      println("(" + counts.length().to_string() + " buckets)")
    }
    close_log(log)
  })
}

///|
/// Error clustering: normalize each matching line into a template (digit
/// runs, hex and quoted spans replaced) and count templates, so variable
/// content collapses into message shapes. `--match` (default "error") selects
/// lines (ASCII case-insensitive, key or value; an empty string matches
/// everything). `--top N` prints the N most frequent templates (default 20).
fn cmd_cluster(
  dir : String,
  match_text : String?,
  top : String?,
) -> Unit raise @io.IoError {
  let top_n = match top {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid top count: " + s)
      }
    None => 20
  }
  let needle = @utf8.encode(
    match match_text {
      Some(s) => s
      None => "error"
    },
  )
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let counts : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([])
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      if match_needle(rec.key, needle, true) ||
        match_needle(rec.value, needle, true) {
        bump_bytes(counts, @core.normalize_log_template(rec.value))
      }
      true
    })
    let items : Array[(Bytes, Int32)] = []
    for k in counts.keys() {
      match counts.get(k) {
        Some(c) => items.push((k, c))
        None => ()
      }
    }
    let shown = top_counts(items, top_n)
    println("count  template")
    for item in shown {
      println(item.1.to_string() + "  " + bytes_to_string(item.0))
    }
    println("(" + counts.length().to_string() + " templates)")
    close_log(log)
  })
}

///|
/// Trend histogram: count records per time bucket and print a text bar chart
/// in chronological order. `--bucket minute|hour|day` (default hour) selects
/// UTC granularity; `--match <text>` filters records (ASCII case-insensitive,
/// key or value); `--width N` sets the longest bar width (default 40).
fn cmd_trend(
  dir : String,
  bucket : String,
  match_text : String?,
  width : String?,
) -> Unit raise @io.IoError {
  if bucket != "minute" && bucket != "hour" && bucket != "day" {
    raise @io.IoError::Invalid(
      "invalid bucket: " + bucket + " (minute|hour|day)",
    )
  }
  let bar_width = match width {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid width: " + s)
      }
    None => 40
  }
  let needle : Bytes? = match match_text {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let counts : @hashmap.HashMap[String, Int32] = @hashmap.HashMap::HashMap([])
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      let pass = match needle {
        Some(n) =>
          match_needle(rec.key, n, true) || match_needle(rec.value, n, true)
        None => true
      }
      if pass {
        bump_string(counts, @core.format_utc(rec.timestamp, bucket))
      }
      true
    })
    let labels : Array[String] = []
    for k in counts.keys() {
      labels.push(k)
    }
    labels.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
    let mut max_count : Int32 = 0
    for label in labels {
      match counts.get(label) {
        Some(c) => if c > max_count { max_count = c }
        None => ()
      }
    }
    for label in labels {
      match counts.get(label) {
        Some(c) => {
          let bars = if max_count > 0 { c * bar_width / max_count } else { 0 }
          let bar = StringBuilder()
          let mut i = 0
          while i < bars {
            bar.write_string("█")
            i = i + 1
          }
          println(label + "  " + bar.to_string() + " " + c.to_string())
        }
        None => ()
      }
    }
    println(
      "(max " +
      max_count.to_string() +
      ", " +
      labels.length().to_string() +
      " buckets)",
    )
    close_log(log)
  })
}

///|
/// Newton's method square root (no math library dependency).
fn sqrt_double(x : Double) -> Double {
  if x <= 0.0 {
    return 0.0
  }
  let mut r = x
  let mut i = 0
  while i < 32 {
    r = 0.5 * (r + x / r)
    i = i + 1
  }
  r
}

///|
fn abs_double(v : Double) -> Double {
  if v < 0.0 {
    -v
  } else {
    v
  }
}

///|
/// Deliver an alert event to the configured external channels: append it as a
/// JSON line to `--notify-file` and/or POST it to `--webhook` via curl. The
/// caller prints the human-readable line itself.
fn dispatch_notification(
  event_json : String,
  notify_file : String?,
  webhook : String?,
) -> Unit raise @io.IoError {
  match notify_file {
    Some(path) => {
      let existing = @backend_native.read_file(path)
      @backend_native.write_file(
        path,
        existing + @utf8.encode(event_json + "\n"),
      )
    }
    None => ()
  }
  match webhook {
    Some(url) => {
      let cmd = "curl -s -m 5 -X POST -H 'Content-Type: application/json' --data " +
        @core.shell_quote(event_json) +
        " " +
        @core.shell_quote(url)
      let rc = @backend_native.run_command(cmd)
      if rc != 0 {
        println(
          "warning: webhook delivery failed (exit " + rc.to_string() + ")",
        )
      }
    }
    None => ()
  }
}

///|
/// Threshold alerting: count records matching `--match` per UTC window and
/// alert on every window whose count exceeds `--threshold`. Alerts print to
/// stdout and may additionally be delivered to `--notify-file` (JSON lines)
/// and `--webhook` (curl POST). `--json` prints the alert events as JSON.
fn cmd_alert(
  dir : String,
  match_text : String,
  threshold : String,
  window : String,
  notify_file : String?,
  webhook : String?,
  json : Bool,
) -> Unit raise @io.IoError {
  if window != "minute" && window != "hour" && window != "day" {
    raise @io.IoError::Invalid(
      "invalid window: " + window + " (minute|hour|day)",
    )
  }
  let threshold_n = @string.parse_int(threshold) catch {
    _ => raise @io.IoError::Invalid("invalid threshold: " + threshold)
  }
  let needle = @utf8.encode(match_text)
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let counts : @hashmap.HashMap[String, Int32] = @hashmap.HashMap::HashMap([])
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      if match_needle(rec.key, needle, true) ||
        match_needle(rec.value, needle, true) {
        bump_string(counts, @core.format_utc(rec.timestamp, window))
      }
      true
    })
    let labels : Array[String] = []
    for k in counts.keys() {
      labels.push(k)
    }
    labels.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
    let mut alerts = 0
    for label in labels {
      let c = match counts.get(label) {
        Some(c) => c
        None => 0
      }
      if c > threshold_n {
        alerts = alerts + 1
        let event = "{\"kind\":\"threshold\",\"window\":\"" +
          label +
          "\",\"count\":" +
          c.to_string() +
          ",\"threshold\":" +
          threshold_n.to_string() +
          "}"
        if json {
          println(event)
        } else {
          println(
            "ALERT " +
            label +
            " count=" +
            c.to_string() +
            " threshold=" +
            threshold_n.to_string(),
          )
        }
        dispatch_notification(event, notify_file, webhook)
      }
    }
    println(
      "(windows " +
      labels.length().to_string() +
      ", alerts " +
      alerts.to_string() +
      ")",
    )
    close_log(log)
  })
}

///|
/// Baseline anomaly detection: count records matching `--match` per UTC
/// window, compute the mean and standard deviation of the window counts, and
/// flag windows whose z-score exceeds `--sigma` (default 3) — provided at
/// least `--min-windows` (default 3) windows exist. Flagged windows print to
/// stdout and may be delivered to `--notify-file` (JSON lines).
fn cmd_baseline(
  dir : String,
  match_text : String?,
  window : String,
  sigma : String?,
  min_windows : String?,
  notify_file : String?,
  webhook : String?,
) -> Unit raise @io.IoError {
  if window != "minute" && window != "hour" && window != "day" {
    raise @io.IoError::Invalid(
      "invalid window: " + window + " (minute|hour|day)",
    )
  }
  let sigma_i = match sigma {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid sigma: " + s)
      }
    None => 3
  }
  let sigma_v = sigma_i.to_double()
  let min_n = match min_windows {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid min-windows: " + s)
      }
    None => 3
  }
  let needle : Bytes? = match match_text {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let counts : @hashmap.HashMap[String, Int32] = @hashmap.HashMap::HashMap([])
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      let pass = match needle {
        Some(n) =>
          match_needle(rec.key, n, true) || match_needle(rec.value, n, true)
        None => true
      }
      if pass {
        bump_string(counts, @core.format_utc(rec.timestamp, window))
      }
      true
    })
    let labels : Array[String] = []
    for k in counts.keys() {
      labels.push(k)
    }
    labels.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
    if labels.length() < min_n {
      println(
        "(insufficient windows: " +
        labels.length().to_string() +
        " < " +
        min_n.to_string() +
        ")",
      )
    } else {
      let n = labels.length()
      let mut sum = 0.0
      for label in labels {
        match counts.get(label) {
          Some(c) => sum = sum + c.to_double()
          None => ()
        }
      }
      let mean = sum / n.to_double()
      let mut var_sum = 0.0
      for label in labels {
        match counts.get(label) {
          Some(c) => {
            let d = c.to_double() - mean
            var_sum = var_sum + d * d
          }
          None => ()
        }
      }
      let stddev = sqrt_double(var_sum / n.to_double())
      let mut anomalies = 0
      for label in labels {
        let c = match counts.get(label) {
          Some(c) => c
          None => 0
        }
        let z = if stddev > 0.0 { (c.to_double() - mean) / stddev } else { 0.0 }
        let abnormal = abs_double(z) > sigma_v
        if abnormal {
          anomalies = anomalies + 1
          let event = "{\"kind\":\"baseline\",\"window\":\"" +
            label +
            "\",\"count\":" +
            c.to_string() +
            ",\"z\":" +
            z.to_string() +
            "}"
          dispatch_notification(event, notify_file, webhook)
        }
        println(
          label +
          "  count=" +
          c.to_string() +
          "  mean=" +
          mean.to_string() +
          "  sd=" +
          stddev.to_string() +
          "  z=" +
          z.to_string() +
          (if abnormal { "  ANOMALY" } else { "" }),
        )
      }
      println(
        "(windows " +
        n.to_string() +
        ", anomalies " +
        anomalies.to_string() +
        ")",
      )
    }
    close_log(log)
  })
}

///|
/// Load the RBAC rules from `<dir>/RBAC` (empty when the file is missing or
/// unreadable).
fn load_rbac_rules(dir : String) -> Array[@core.RbacRole] {
  let data = @backend_native.read_file(dir + "/RBAC")
  let rules : Array[@core.RbacRole] = []
  let mut start = 0
  let mut i = 0
  while i <= data.length() {
    if i == data.length() || data.at(i).to_int() == 10 {
      let line = @core.slice(data, start, i)
      if line.length() > 0 {
        match @core.parse_rbac_line(line) {
          Some(r) => rules.push(r)
          None => ()
        }
      }
      start = i + 1
    }
    i = i + 1
  }
  rules
}

///|
/// Whether `cmd` may run against `dir`: unrestricted when no RBAC file exists
/// (the local CLI default), otherwise MOONLOG_TOKEN must match a role whose
/// allow list contains the command (or `*`).
fn rbac_check(dir : String, cmd : String) -> Bool {
  if !@backend_native.file_exists(dir + "/RBAC") {
    return true
  }
  let rules = load_rbac_rules(dir)
  let token = match @env.get_env_var("MOONLOG_TOKEN") {
    Some(t) => @utf8.encode(t)
    None => b""
  }
  match @core.rbac_find(rules, token) {
    Some(role) => @core.rbac_allows(role, @utf8.encode(cmd))
    None => false
  }
}

///|
/// Append a denial to the directory's audit log (`AUDIT.log`) when RBAC is in
/// force, so unrestricted directories stay untouched.
fn record_denied(dir : String, cmd : String) -> Unit {
  if !@backend_native.file_exists(dir + "/RBAC") {
    return
  }
  let path = dir + "/AUDIT.log"
  let existing = @backend_native.read_file(path)
  let line = "{\"ts\":" +
    now_ms().to_string() +
    ",\"command\":\"" +
    json_escape_str(cmd) +
    "\",\"decision\":\"deny\"}\n"
  ignore(
    @backend_native.write_file(path, existing + @utf8.encode(line)) catch {
      _ => ()
    },
  )
}

///|
/// Mask a token for display: keep at most the last four characters.
fn mask_token(token : String) -> String {
  let n = token.length()
  if n <= 4 {
    "****"
  } else {
    "****" + token[n - 4:n].to_owned()
  }
}

///|
/// Join an allow list back into `a,b,c` text.
fn allow_text(allow : Array[Bytes]) -> String {
  let sb = StringBuilder()
  let mut first = true
  for a in allow {
    if !first {
      sb.write_string(",")
    }
    first = false
    sb.write_string(bytes_to_string(a))
  }
  sb.to_string()
}

///|
/// Manage the directory's RBAC rules. `init <token>` bootstraps an admin role;
/// `add <name> <token> <allow>` appends a role (allow is a comma list or `*`);
/// `list` prints roles with masked tokens; `remove <name>` deletes one;
/// `check <command>` reports whether the current MOONLOG_TOKEN may run it.
fn cmd_rbac(
  dir : String,
  sub : String,
  args : Array[String],
  start : Int32,
) -> Unit raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  if sub == "init" {
    if args.length() <= start {
      raise @io.IoError::Invalid("usage: rbac <dir> init <token>")
    }
    let token = args[start]
    let path = dir + "/RBAC"
    if @backend_native.file_exists(path) {
      raise @io.IoError::Invalid("RBAC already initialized: " + path)
    }
    @backend_native.write_file(
      path,
      @utf8.encode("role=admin token=" + token + " allow=*\n"),
    )
    println("rbac initialized: admin role created (token hidden)")
  } else if sub == "add" {
    if args.length() < start + 3 {
      raise @io.IoError::Invalid("usage: rbac <dir> add <name> <token> <allow>")
    }
    let name = args[start]
    let token = args[start + 1]
    let allow = args[start + 2]
    let path = dir + "/RBAC"
    let existing = @backend_native.read_file(path)
    @backend_native.write_file(
      path,
      existing +
      @utf8.encode(
        "role=" + name + " token=" + token + " allow=" + allow + "\n",
      ),
    )
    println("role added: " + name)
  } else if sub == "list" {
    let rules = load_rbac_rules(dir)
    for r in rules {
      println(
        "role=" +
        bytes_to_string(r.name) +
        " allow=" +
        allow_text(r.allow) +
        " token=" +
        mask_token(bytes_to_string(r.token)),
      )
    }
    println("(" + rules.length().to_string() + " roles)")
  } else if sub == "remove" {
    if args.length() <= start {
      raise @io.IoError::Invalid("usage: rbac <dir> remove <name>")
    }
    let name = @utf8.encode(args[start])
    let rules = load_rbac_rules(dir)
    let buf = @buffer.Buffer::Buffer()
    for r in rules {
      if r.name != name {
        buf.write_bytes(
          @utf8.encode(
            "role=" +
            bytes_to_string(r.name) +
            " token=" +
            bytes_to_string(r.token) +
            " allow=" +
            allow_text(r.allow) +
            "\n",
          ),
        )
      }
    }
    @backend_native.write_file(dir + "/RBAC", buf.to_bytes())
    println("role removed: " + args[start])
  } else if sub == "check" {
    if args.length() <= start {
      raise @io.IoError::Invalid("usage: rbac <dir> check <command>")
    }
    let command = args[start]
    if rbac_check(dir, command) {
      println("allowed: " + command)
    } else {
      println("denied: " + command)
    }
  } else {
    raise @io.IoError::Invalid(
      "unknown rbac action: " + sub + " (init|add|list|remove|check)",
    )
  }
}

///|
/// Fixed 128-byte payload used by the write benchmark.
fn make_bench_value() -> Bytes {
  let chunk = b"0123456789abcdef0123456789abcdef"
  let mut v : Bytes = b""
  while v.length() < 128 {
    v = v + chunk
  }
  @core.slice(v, 0, 128)
}

///|
/// Bulk-write benchmark: append `count` records in batches of `--batch`
/// (default 1000) under the given `--sync` policy, report throughput, then
/// reopen the directory and verify that every record survived (exact count,
/// contiguous offsets, clean fast fsck). Use an empty directory — the
/// verification expects exactly `count` records.
fn cmd_bench_write(
  dir : String,
  count_str : String,
  batch_str : String?,
  sync_str : String?,
  prefix : String,
) -> Unit raise @io.IoError {
  let total = @string.parse_int64(count_str) catch {
    _ => raise @io.IoError::Invalid("invalid count: " + count_str)
  }
  let batch_n : Int64 = match batch_str {
    Some(s) =>
      @string.parse_int64(s) catch {
        _ => raise @io.IoError::Invalid("invalid batch: " + s)
      }
    None => 1000
  }
  if total <= (0 : Int64) || batch_n <= (0 : Int64) {
    raise @io.IoError::Invalid("count and batch must be positive")
  }
  let sync = match sync_str {
    Some("always") => @log.SyncPolicy::Always
    Some("never") => @log.SyncPolicy::Never
    Some("batch") => @log.SyncPolicy::Batch
    Some(other) =>
      raise @io.IoError::Invalid(
        "invalid sync: " + other + " (always|batch|never)",
      )
    None => @log.SyncPolicy::Batch
  }
  let sync_label = if sync is @log.SyncPolicy::Always {
    "always"
  } else if sync is @log.SyncPolicy::Never {
    "never"
  } else {
    "batch"
  }
  let value = make_bench_value()
  let run_start = now_ms()
  run_locked(dir, true, () => {
    let log = @backend_native.open_log_dir(dir, ROLL_SIZE, sync~)
    let ts = now_ms()
    let mut written : Int64 = 0
    while written < total {
      let n = if total - written < batch_n { total - written } else { batch_n }
      let records : Array[(Bytes, Bytes, Int64)] = []
      let mut i : Int64 = 0
      while i < n {
        let idx = written + i
        records.push((@utf8.encode(prefix + idx.to_string()), value, ts + idx))
        i = i + 1
      }
      ignore(log.append_batch(records))
      written = written + n
    }
    log.flush()
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
  let elapsed = now_ms() - run_start
  let qps = if elapsed > (0 : Int64) {
    total * 1000 / elapsed
  } else {
    total * 1000
  }
  println(
    "wrote " +
    total.to_string() +
    " records in " +
    elapsed.to_string() +
    " ms (" +
    qps.to_string() +
    " records/s), batch " +
    batch_n.to_string() +
    ", sync " +
    sync_label,
  )
  // Two-phase check: the writer closed the directory; reopening here proves
  // the batch persisted with no loss.
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let recs = log.scan() catch { _ => panic() }
    let count = recs.length().to_int64()
    let mut continuous = count == total
    let mut i = 0
    while i < recs.length() {
      if recs[i].offset != i.to_uint64() {
        continuous = false
      }
      i = i + 1
    }
    let report = log.verify_fast()
    let ok = continuous &&
      report.first_bad_offset is None &&
      report.first_bad_checksum is None
    println(
      "verify: records " +
      count.to_string() +
      " (expected " +
      total.to_string() +
      "), continuous " +
      continuous.to_string() +
      ", " +
      (if ok { "ok (no loss)" } else { "FAILED" }),
    )
    close_log(log)
    if !ok {
      raise @io.IoError::Invalid("bench-write verification failed")
    }
  })
}

///|
fn dispatch(args : Array[String]) -> Unit raise @io.IoError {
  if args.length() < 2 {
    println(USAGE)
    return
  }
  let cmd = args[1]
  if cmd == "version" || cmd == "--version" {
    println("moonlog " + MOONLOG_VERSION)
    return
  }
  if args.length() < 3 {
    println(USAGE)
    return
  }
  // RBAC enforcement: once a directory has an RBAC file, every command except
  // `rbac init` (bootstrapping) and `rbac check` (pure diagnosis) requires a
  // MOONLOG_TOKEN role that allows it.
  let bootstrapping = cmd == "rbac" &&
    args.length() > 3 &&
    (args[3] == "init" || args[3] == "check")
  if !bootstrapping && !rbac_check(args[2], cmd) {
    record_denied(args[2], cmd)
    println(
      "permission denied: '" +
      cmd +
      "' requires MOONLOG_TOKEN with a permitted role",
    )
    return
  }
  if cmd == "put" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      let mut ts : String? = (None : String?)
      let mut idempotent = false
      let mut partition_str : String? = (None : String?)
      let mut i = 5
      while i < args.length() {
        if args[i] == "--ts" && i + 1 < args.length() {
          ts = Some(args[i + 1])
          i = i + 1
        } else if args[i] == "--idempotent" {
          idempotent = true
        } else if args[i] == "--partition" && i + 1 < args.length() {
          partition_str = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      let partition = match partition_str {
        Some(s) => parse_partition(s)
        None => 0
      }
      cmd_put(args[2], args[3], args[4], ts, idempotent, partition)
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
  } else if cmd == "partitions" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut unit = "day"
      let mut json = false
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--unit" && i + 1 < args.length() {
          unit = args[i + 1]
          i = i + 1
        } else if a == "--json" {
          json = true
        }
        i = i + 1
      }
      cmd_partitions(args[2], unit, json)
    }
  } else if cmd == "fsck" {
    let mut fast = false
    let mut fix = false
    let mut dry = false
    let mut i = 3
    while i < args.length() {
      if args[i] == "fast" {
        fast = true
      } else if args[i] == "--fix" {
        fix = true
      } else if args[i] == "--dry-run" {
        fix = true
        dry = true
      }
      i = i + 1
    }
    cmd_fsck(args[2], fast, fix, dry)
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
    let mut json = false
    let mut name : String? = (None : String?)
    let mut i = 3
    while i < args.length() {
      let a = args[i]
      if a == "--once" {
        once = true
      } else if a == "--commit" {
        commit = true
      } else if a == "--json" {
        json = true
      } else if a == "--name" && i + 1 < args.length() {
        name = Some(args[i + 1])
        i = i + 1
      } else {
        start = a
      }
      i = i + 1
    }
    cmd_follow(args[2], start, once, commit, json, name)
  } else if cmd == "ingest" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut follow = false
      let mut fifo = false
      let mut format = "lines"
      let mut key = "log"
      let mut key_field = "key"
      let mut value_field = ""
      let mut ts_field : String? = (None : String?)
      let mut template : String? = (None : String?)
      let mut idempotent = false
      let mut schema = false
      let mut clock_skew : String? = (None : String?)
      let mut mask = false
      let mut mask_fields : String? = (None : String?)
      let mut meta_str : String? = (None : String?)
      let mut partition_str : String? = (None : String?)
      let mut from_str : String? = (None : String?)
      let mut batch : String? = (None : String?)
      let mut interval : String? = (None : String?)
      let mut min_level : String? = (None : String?)
      let mut level_field : String? = (None : String?)
      let mut sample_rate : String? = (None : String?)
      let mut include_str : String? = (None : String?)
      let mut exclude_str : String? = (None : String?)
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--follow" {
          follow = true
        } else if a == "--fifo" {
          fifo = true
        } else if a == "--once" {
          follow = false
        } else if a == "--format" && i + 1 < args.length() {
          format = args[i + 1]
          i = i + 1
        } else if a == "--key" && i + 1 < args.length() {
          key = args[i + 1]
          i = i + 1
        } else if a == "--key-field" && i + 1 < args.length() {
          key_field = args[i + 1]
          i = i + 1
        } else if a == "--value-field" && i + 1 < args.length() {
          value_field = args[i + 1]
          i = i + 1
        } else if a == "--from" && i + 1 < args.length() {
          from_str = Some(args[i + 1])
          i = i + 1
        } else if a == "--batch" && i + 1 < args.length() {
          batch = Some(args[i + 1])
          i = i + 1
        } else if a == "--interval" && i + 1 < args.length() {
          interval = Some(args[i + 1])
          i = i + 1
        } else if a == "--ts-field" && i + 1 < args.length() {
          ts_field = Some(args[i + 1])
          i = i + 1
        } else if a == "--template" && i + 1 < args.length() {
          template = Some(args[i + 1])
          i = i + 1
        } else if a == "--idempotent" {
          idempotent = true
        } else if a == "--min-level" && i + 1 < args.length() {
          min_level = Some(args[i + 1])
          i = i + 1
        } else if a == "--level-field" && i + 1 < args.length() {
          level_field = Some(args[i + 1])
          i = i + 1
        } else if a == "--sample-rate" && i + 1 < args.length() {
          sample_rate = Some(args[i + 1])
          i = i + 1
        } else if a == "--include" && i + 1 < args.length() {
          include_str = Some(args[i + 1])
          i = i + 1
        } else if a == "--exclude" && i + 1 < args.length() {
          exclude_str = Some(args[i + 1])
          i = i + 1
        } else if a == "--schema" {
          schema = true
        } else if a == "--clock-skew" && i + 1 < args.length() {
          clock_skew = Some(args[i + 1])
          i = i + 1
        } else if a == "--mask" {
          mask = true
        } else if a == "--mask-fields" && i + 1 < args.length() {
          mask_fields = Some(args[i + 1])
          i = i + 1
        } else if a == "--meta" && i + 1 < args.length() {
          meta_str = Some(args[i + 1])
          i = i + 1
        } else if a == "--partition" && i + 1 < args.length() {
          partition_str = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      let sampling = parse_sampling_config(
        min_level, level_field, sample_rate, include_str, exclude_str,
      )
      let batch_n = match batch {
        Some(s) =>
          @string.parse_int(s) catch {
            _ => raise @io.IoError::Invalid("invalid batch: " + s)
          }
        None => 256
      }
      let from_bytes : Int64? = match from_str {
        Some(s) =>
          Some(
            @string.parse_int64(s) catch {
              _ => raise @io.IoError::Invalid("invalid offset: " + s)
            },
          )
        None => None
      }
      let skew_ms : Int64 = match clock_skew {
        Some(s) =>
          @string.parse_int64(s) catch {
            _ => raise @io.IoError::Invalid("invalid clock skew: " + s)
          }
        None => 0
      }
      let opts : IngestOptions = {
        format,
        key_bytes: @utf8.encode(key),
        field_bytes: @utf8.encode(key_field),
        value_field_bytes: @utf8.encode(value_field),
        ts_field_bytes: match ts_field {
          Some(f) => Some(@utf8.encode(f))
          None => None
        },
        template_bytes: match template {
          Some(t) => Some(@utf8.encode(t))
          None => None
        },
        batch_n,
        idempotent,
        sampling,
        from_bytes,
        schema,
        clock_skew_ms: skew_ms,
        mask,
        mask_extra: match mask_fields {
          Some(s) => csv_to_bytes_list(s)
          None => []
        },
        meta_bytes: match meta_str {
          Some(s) => Some(parse_meta_pairs(s))
          None => None
        },
        partition_ms: match partition_str {
          Some(s) => parse_partition(s)
          None => 0
        },
      }
      cmd_ingest(args[2], args[3], follow, fifo, opts, interval)
    }
  } else if cmd == "http" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut port : String? = (None : String?)
      let mut queue_cap : String? = (None : String?)
      let mut batch : String? = (None : String?)
      let mut backlog_alert : String? = (None : String?)
      let mut format = "lines"
      let mut key = "log"
      let mut key_field = "key"
      let mut value_field = ""
      let mut ts_field : String? = (None : String?)
      let mut template : String? = (None : String?)
      let mut idempotent = false
      let mut schema = false
      let mut clock_skew : String? = (None : String?)
      let mut mask = false
      let mut mask_fields : String? = (None : String?)
      let mut meta_str : String? = (None : String?)
      let mut partition_str : String? = (None : String?)
      let mut min_level : String? = (None : String?)
      let mut level_field : String? = (None : String?)
      let mut sample_rate : String? = (None : String?)
      let mut include_str : String? = (None : String?)
      let mut exclude_str : String? = (None : String?)
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--port" && i + 1 < args.length() {
          port = Some(args[i + 1])
          i = i + 1
        } else if a == "--queue" && i + 1 < args.length() {
          queue_cap = Some(args[i + 1])
          i = i + 1
        } else if a == "--batch" && i + 1 < args.length() {
          batch = Some(args[i + 1])
          i = i + 1
        } else if a == "--backlog-alert" && i + 1 < args.length() {
          backlog_alert = Some(args[i + 1])
          i = i + 1
        } else if a == "--format" && i + 1 < args.length() {
          format = args[i + 1]
          i = i + 1
        } else if a == "--key" && i + 1 < args.length() {
          key = args[i + 1]
          i = i + 1
        } else if a == "--key-field" && i + 1 < args.length() {
          key_field = args[i + 1]
          i = i + 1
        } else if a == "--value-field" && i + 1 < args.length() {
          value_field = args[i + 1]
          i = i + 1
        } else if a == "--ts-field" && i + 1 < args.length() {
          ts_field = Some(args[i + 1])
          i = i + 1
        } else if a == "--template" && i + 1 < args.length() {
          template = Some(args[i + 1])
          i = i + 1
        } else if a == "--idempotent" {
          idempotent = true
        } else if a == "--min-level" && i + 1 < args.length() {
          min_level = Some(args[i + 1])
          i = i + 1
        } else if a == "--level-field" && i + 1 < args.length() {
          level_field = Some(args[i + 1])
          i = i + 1
        } else if a == "--sample-rate" && i + 1 < args.length() {
          sample_rate = Some(args[i + 1])
          i = i + 1
        } else if a == "--include" && i + 1 < args.length() {
          include_str = Some(args[i + 1])
          i = i + 1
        } else if a == "--exclude" && i + 1 < args.length() {
          exclude_str = Some(args[i + 1])
          i = i + 1
        } else if a == "--schema" {
          schema = true
        } else if a == "--clock-skew" && i + 1 < args.length() {
          clock_skew = Some(args[i + 1])
          i = i + 1
        } else if a == "--mask" {
          mask = true
        } else if a == "--mask-fields" && i + 1 < args.length() {
          mask_fields = Some(args[i + 1])
          i = i + 1
        } else if a == "--meta" && i + 1 < args.length() {
          meta_str = Some(args[i + 1])
          i = i + 1
        } else if a == "--partition" && i + 1 < args.length() {
          partition_str = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      let sampling = parse_sampling_config(
        min_level, level_field, sample_rate, include_str, exclude_str,
      )
      let batch_n = match batch {
        Some(s) =>
          @string.parse_int(s) catch {
            _ => raise @io.IoError::Invalid("invalid batch: " + s)
          }
        None => 256
      }
      let skew_ms : Int64 = match clock_skew {
        Some(s) =>
          @string.parse_int64(s) catch {
            _ => raise @io.IoError::Invalid("invalid clock skew: " + s)
          }
        None => 0
      }
      let opts : IngestOptions = {
        format,
        key_bytes: @utf8.encode(key),
        field_bytes: @utf8.encode(key_field),
        value_field_bytes: @utf8.encode(value_field),
        ts_field_bytes: match ts_field {
          Some(f) => Some(@utf8.encode(f))
          None => None
        },
        template_bytes: match template {
          Some(t) => Some(@utf8.encode(t))
          None => None
        },
        batch_n,
        idempotent,
        sampling,
        from_bytes: None,
        schema,
        clock_skew_ms: skew_ms,
        mask,
        mask_extra: match mask_fields {
          Some(s) => csv_to_bytes_list(s)
          None => []
        },
        meta_bytes: match meta_str {
          Some(s) => Some(parse_meta_pairs(s))
          None => None
        },
        partition_ms: match partition_str {
          Some(s) => parse_partition(s)
          None => 0
        },
      }
      cmd_http(args[2], port, queue_cap, batch, backlog_alert, opts)
    }
  } else if cmd == "bench-write" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut batch : String? = (None : String?)
      let mut sync : String? = (None : String?)
      let mut prefix = "bench:"
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--batch" && i + 1 < args.length() {
          batch = Some(args[i + 1])
          i = i + 1
        } else if a == "--sync" && i + 1 < args.length() {
          sync = Some(args[i + 1])
          i = i + 1
        } else if a == "--prefix" && i + 1 < args.length() {
          prefix = args[i + 1]
          i = i + 1
        }
        i = i + 1
      }
      cmd_bench_write(args[2], args[3], batch, sync, prefix)
    }
  } else if cmd == "search" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut field = "both"
      let mut ignore_case = false
      let mut inverted = false
      let mut limit : String? = (None : String?)
      let mut from : String? = (None : String?)
      let mut to : String? = (None : String?)
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--ignore-case" {
          ignore_case = true
        } else if a == "--inverted" {
          inverted = true
        } else if a == "--field" && i + 1 < args.length() {
          field = args[i + 1]
          i = i + 1
        } else if a == "--limit" && i + 1 < args.length() {
          limit = Some(args[i + 1])
          i = i + 1
        } else if a == "--from" && i + 1 < args.length() {
          from = Some(args[i + 1])
          i = i + 1
        } else if a == "--to" && i + 1 < args.length() {
          to = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_search(
        args[2],
        args[3],
        field,
        ignore_case,
        limit,
        from,
        to,
        inverted,
      )
    }
  } else if cmd == "query" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut level : String? = (None : String?)
      let mut service : String? = (None : String?)
      let mut host : String? = (None : String?)
      let mut trace_id : String? = (None : String?)
      let mut contains : String? = (None : String?)
      let mut since : String? = (None : String?)
      let mut until : String? = (None : String?)
      let mut limit : String? = (None : String?)
      let mut indexed = false
      let mut sort_by_time = false
      let mut json = false
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--level" && i + 1 < args.length() {
          level = Some(args[i + 1])
          i = i + 1
        } else if a == "--service" && i + 1 < args.length() {
          service = Some(args[i + 1])
          i = i + 1
        } else if a == "--host" && i + 1 < args.length() {
          host = Some(args[i + 1])
          i = i + 1
        } else if a == "--trace-id" && i + 1 < args.length() {
          trace_id = Some(args[i + 1])
          i = i + 1
        } else if a == "--contains" && i + 1 < args.length() {
          contains = Some(args[i + 1])
          i = i + 1
        } else if a == "--since" && i + 1 < args.length() {
          since = Some(args[i + 1])
          i = i + 1
        } else if a == "--until" && i + 1 < args.length() {
          until = Some(args[i + 1])
          i = i + 1
        } else if a == "--limit" && i + 1 < args.length() {
          limit = Some(args[i + 1])
          i = i + 1
        } else if a == "--indexed" {
          indexed = true
        } else if a == "--sort-by-time" {
          sort_by_time = true
        } else if a == "--json" {
          json = true
        }
        i = i + 1
      }
      cmd_query(
        args[2],
        level,
        service,
        host,
        trace_id,
        contains,
        since,
        until,
        limit,
        indexed,
        sort_by_time,
        json,
      )
    }
  } else if cmd == "context" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut before : String? = (None : String?)
      let mut after : String? = (None : String?)
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--before" && i + 1 < args.length() {
          before = Some(args[i + 1])
          i = i + 1
        } else if a == "--after" && i + 1 < args.length() {
          after = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_context(args[2], args[3], before, after)
    }
  } else if cmd == "aggregate" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut by = "key"
      let mut kv_field : String? = (None : String?)
      let mut match_text : String? = (None : String?)
      let mut top : String? = (None : String?)
      let mut json = false
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--json" {
          json = true
        } else if a == "--by" && i + 1 < args.length() {
          by = args[i + 1]
          i = i + 1
        } else if a == "--kv-field" && i + 1 < args.length() {
          kv_field = Some(args[i + 1])
          i = i + 1
        } else if a == "--match" && i + 1 < args.length() {
          match_text = Some(args[i + 1])
          i = i + 1
        } else if a == "--top" && i + 1 < args.length() {
          top = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_aggregate(args[2], by, kv_field, match_text, top, json)
    }
  } else if cmd == "cluster" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut match_text : String? = (None : String?)
      let mut top : String? = (None : String?)
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--match" && i + 1 < args.length() {
          match_text = Some(args[i + 1])
          i = i + 1
        } else if a == "--top" && i + 1 < args.length() {
          top = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_cluster(args[2], match_text, top)
    }
  } else if cmd == "trend" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut bucket = "hour"
      let mut match_text : String? = (None : String?)
      let mut width : String? = (None : String?)
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--bucket" && i + 1 < args.length() {
          bucket = args[i + 1]
          i = i + 1
        } else if a == "--match" && i + 1 < args.length() {
          match_text = Some(args[i + 1])
          i = i + 1
        } else if a == "--width" && i + 1 < args.length() {
          width = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_trend(args[2], bucket, match_text, width)
    }
  } else if cmd == "alert" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut threshold : String? = (None : String?)
      let mut window = "hour"
      let mut notify_file : String? = (None : String?)
      let mut webhook : String? = (None : String?)
      let mut json = false
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--json" {
          json = true
        } else if a == "--threshold" && i + 1 < args.length() {
          threshold = Some(args[i + 1])
          i = i + 1
        } else if a == "--window" && i + 1 < args.length() {
          window = args[i + 1]
          i = i + 1
        } else if a == "--notify-file" && i + 1 < args.length() {
          notify_file = Some(args[i + 1])
          i = i + 1
        } else if a == "--webhook" && i + 1 < args.length() {
          webhook = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      match threshold {
        Some(t) =>
          cmd_alert(args[2], args[3], t, window, notify_file, webhook, json)
        None => raise @io.IoError::Invalid("alert requires --threshold")
      }
    }
  } else if cmd == "baseline" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut match_text : String? = (None : String?)
      let mut window = "hour"
      let mut sigma : String? = (None : String?)
      let mut min_windows : String? = (None : String?)
      let mut notify_file : String? = (None : String?)
      let mut webhook : String? = (None : String?)
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--match" && i + 1 < args.length() {
          match_text = Some(args[i + 1])
          i = i + 1
        } else if a == "--window" && i + 1 < args.length() {
          window = args[i + 1]
          i = i + 1
        } else if a == "--sigma" && i + 1 < args.length() {
          sigma = Some(args[i + 1])
          i = i + 1
        } else if a == "--min-windows" && i + 1 < args.length() {
          min_windows = Some(args[i + 1])
          i = i + 1
        } else if a == "--notify-file" && i + 1 < args.length() {
          notify_file = Some(args[i + 1])
          i = i + 1
        } else if a == "--webhook" && i + 1 < args.length() {
          webhook = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_baseline(
        args[2],
        match_text,
        window,
        sigma,
        min_windows,
        notify_file,
        webhook,
      )
    }
  } else if cmd == "serve" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut ttl : String? = (None : String?)
      let mut every : String? = (None : String?)
      let mut fsck_every : String? = (None : String?)
      let mut once = false
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--once" {
          once = true
        } else if a == "--every" && i + 1 < args.length() {
          every = Some(args[i + 1])
          i = i + 1
        } else if a == "--fsck-every" && i + 1 < args.length() {
          fsck_every = Some(args[i + 1])
          i = i + 1
        } else {
          match ttl {
            None => ttl = Some(a)
            Some(_) => ()
          }
        }
        i = i + 1
      }
      cmd_serve(args[2], args[3], ttl, every, fsck_every, once)
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
  } else if cmd == "ttl-expire" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut dry = false
      let mut i = 3
      while i < args.length() {
        if args[i] == "--dry-run" {
          dry = true
        }
        i = i + 1
      }
      cmd_ttl_expire(args[2], dry)
    }
  } else if cmd == "replicate" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut follow = false
      let mut i = 4
      while i < args.length() {
        if args[i] == "--follow" {
          follow = true
        }
        i = i + 1
      }
      cmd_replicate(args[2], args[3], follow)
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
  } else if cmd == "tier" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut warm : String? = (None : String?)
      let mut dry = false
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--dry-run" {
          dry = true
        } else if a == "--warm" && i + 1 < args.length() {
          warm = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_tier(args[2], args[3], warm, dry)
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
  } else if cmd == "export-jsonl" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mode = if args.length() > 4 { args[4] } else { "text" }
      cmd_export_jsonl(args[2], args[3], mode)
    }
  } else if cmd == "import" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_import(args[2], args[3])
    }
  } else if cmd == "rbac" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_rbac(args[2], args[3], args, 4)
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
