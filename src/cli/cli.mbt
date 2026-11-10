///|
/// Command-line front end for the append-only event log. Runs on the native
/// target with a directory of `*.log` segment files as its store.
///
/// Usage:
///   moonlog <command> <dir> [args...]
///
/// Commands:
///   put <dir> <key> <value> [--ts <ms>] [--idempotent] [--dedup-id <id>]
///                                    append a key/value record; with
///                                    --idempotent a repeated (key, value) is
///                                    recognized and skipped; --dedup-id makes
///                                    it an explicit unique ID: a repeated ID
///                                    is skipped even with a different value
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
///   ttl-expire <dir> [--dry-run] [--json]
///                                    differentiated-TTL expiry per <dir>/TTL
///                                    (default/service/level rules); applied
///                                    runs append to TTL_AUDIT.log
///   replicate <src> <dst> [--follow]
///                                    incrementally mirror the source log into
///                                    a complete replica directory (--follow
///                                    repeats on an interval and only warns
///                                    while the source is down); a promoted
///                                    replica rejects forward sync so outage
///                                    writes are never trimmed
///   ha-failover <primary> <replica> [--active <link>] [--json]
///                                    promote the replica (role=primary),
///                                    mark a reachable old primary standby and
///                                    atomically repoint the stable link
///   ha-status <primary> <replica> [--json]
///                                    show roles, reachability and switch time
///   ha-rebalance <old-primary> <new-primary> [--json]
///                                    mirror the promoted primary back onto the
///                                    old directory and mark it standby
///   ha-watch <primary> <replica> --active <link>
///            [--interval ms] [--fail-threshold N] [--json] [--once]
///                                    promote automatically after N failed
///                                    probes; exits after a promotion
///   archive <dir> <file> [--list] [--extract --into <dir>]
///                                    pack a log directory into a single
///                                    self-contained archive file (CRC32) for
///                                    object-storage upload; list or extract
///                                    and restore its contents
///   merge <dir> <max-segments>       merge contiguous rolled segments
///   maintain <dir> <max-segments> [ttl]
///                                    merge + prune-superseded + compact-expired
///                                    + compress + fsck
///   serve <dir> <max-segments> [ttl] [--every ms] [--fsck-every N] [--once]
///                                    run maintenance periodically, with an
///                                    optional fast fsck every N cycles
///   follow <dir> [start|-|tail] [--once] [--commit] [--json]
///            [--name <cursor>] [--match <text>] [--level-min <lv>]
///            [--service <svc>] [--flush]
///                                    print new records as they are appended
///                                    (live tail); the filters narrow the
///                                    printed stream without moving the
///                                    cursor and understand JSON/KV values —
///                                    end-to-end latency is bounded by the
///                                    poll interval (default 200ms), and the
///                                    closing summary reports filtered count
///                                    and max live lag
///   ingest <dir> <file> [--follow] [--once] [--fifo] [--format lines|kv]
///                     [--key <name>] [--key-field <name>] [--ts-field <name>]
///                     [--from <bytes>] [--batch N] [--interval ms]
///                     [--idempotent] [--dedup-field <name>]
///                     [--clock-skew <ms>] [--clock-skew-field <name>]
///                                    parse a log file into records (batch
///                                    import, or follow appended lines);
///                                    resumable via the `ingest-<basename>`
///                                    cursor; `--fifo` subscribes to a named
///                                    pipe instead (writers push batches) and
///                                    exits cleanly on SIGTERM/SIGINT after
///                                    flushing accepted lines;
///                                    with --idempotent replayed lines whose
///                                    (key, value) matches the latest record
///                                    are skipped; --dedup-field treats that
///                                    parsed field as a unique record ID (seen
///                                    IDs persist in <dir>/DEDUP, so a replay
///                                    is skipped even when its value differs);
///                                    --clock-skew adds a fixed timestamp
///                                    offset, --clock-skew-field reads a
///                                    per-record offset from that field (ms)
///   http <dir> [--port N] [--queue N] [--queue-bytes N] [--batch N]
///             [--backlog-alert N]
///             [--format lines|kv] [--key <name>] [--key-field <name>]
///             [--ts-field <name>] [--idempotent] [--dedup-field <name>]
///             [--clock-skew <ms>] [--clock-skew-field <name>]
///                                    HTTP push endpoint on 127.0.0.1 (POST /
///                                    or /push buffers into a bounded queue
///                                    and answers 202, or 429 + Retry-After
///                                    when the backlog (or the optional
///                                    --queue-bytes byte budget) is full —
///                                    explicit backpressure, no silent drops;
///                                    backlog beyond --backlog-alert emits one
///                                    WARN on entry and one RESOLVED when it
///                                    drains (/stats: pending, pending_peak,
///                                    rejected_requests/lines, backlog_alerts);
///                                    backlog drains at full speed with Batch
///                                    durability (one fsync per --batch);
///                                    /stats also reports
///                                    accepted/written/sampled_out counters
///                                    and duplicates; --dedup-field treats
///                                    that parsed field as a unique record ID
///                                    (repeated IDs are skipped even if the
///                                    payload differs);
///                                    GET /health, /stats. A connection that
///                                    stalls mid-request is bounded by a
///                                    per-read timeout plus a 10s request
///                                    deadline, so one slow client cannot
///                                    wedge the serial accept loop; a short
///                                    body is rejected with 400 instead of
///                                    persisting a truncated line)
///   parse-check <file> [--format lines|kv|json|template] [--template <tpl>]
///               [--sample N] [--json]
///                                    parse a sample log file with the same
///                                    extractors as ingest and report per-line
///                                    fields plus accuracy (parsed / lines);
///                                    read-only, useful to validate a template
///                                    or JSON shape before wiring a source
///   bench-write <dir> <count> [--batch N] [--sync always|batch|never]
///                [--prefix <p>] [--warmup N]
///                                    bulk-write benchmark: report the
///                                    write-path throughput (the final
///                                    durability flush is timed separately),
///                                    optionally after N warm-up records,
///                                    then reopen and verify no record was lost
///   search <dir> <text> [--field key|value|both] [--ignore-case] [--limit N]
///                       [--from off] [--to off] [--inverted] [--wildcard]
///                       [--since <ms>] [--until <ms>] [--require-time]
///                       [--timeout <ms>]
///                                    full-text search over keys and/or values
///                                    (substring; --wildcard adds * and ?;
///                                    --inverted uses the ASCII term index for
///                                    single tokens; phrases and CJK queries
///                                    take the exact substring path); without
///                                    --since the search is scoped to the
///                                    default window (--since 0 for everything,
///                                    --require-time rejects unbounded scans);
///                                    shares the 4.6 guards with query
///                                    (concurrency slot, timeout, scan budget)
///                                    and stops at MOONLOG_MAX_RESULTS (default
///                                    1000) unless --limit is given
///                                    (--limit -1 removes the cap)
///   context <dir> <offset> [--before N] [--after N]
///                           [--trace-id <id|auto>] [--thread-id <id|auto>]
///                           [--service <svc>] [--sort-by-time]
///                                    print the records around one offset; with
///                                    correlation options only records sharing
///                                    the trace/thread (auto = extracted from
///                                    the anchor, KV or JSON) and service are
///                                    part of the context, skipping interleaved
///                                    traffic; --sort-by-time orders the window
///                                    by event time (ties keep offset order)
///   aggregate <dir> [--by key|value|kind|hour|prefix:N] [--kv-field <name>]
///                    [--match <text>] [--top N] [--json]
///                    [--quantile <field>] [--since <ts>] [--until <ts>]
///                                    multi-dimensional count aggregation;
///                                    with --quantile, report count/min/avg/
///                                    p50/p95/p99/max of the numeric field
///                                    per bucket instead of counts only;
///                                    field values may be KV or JSON;
///                                    default window is the last 24h
///                                    (--since 0 for everything), pushed
///                                    down to segment min_ts/max_ts; shares
///                                    the query slot/timeout/scan budget and
///                                    does not hold the writer lock
///   cluster <dir> [--match <text>] [--top N] [--stacks] [--json]
///               [--since <ts>] [--until <ts>]
///                                    error clustering by normalized template;
///                                    --stacks merges frame lines into the
///                                    nearest matched header (frames are kept
///                                    even when they do not match --match),
///                                    recognizes Java/Python/.NET/Node/Rust/Go
///                                    frames, and clusters JSON records by
///                                    their embedded stack field; --json
///                                    emits machine-readable clusters;
///                                    default window is the last 24h
///                                    (--since 0 for everything), pushed down
///                                    to segments; shares the query guards and
///                                    scans without the writer lock
///   trend <dir> [--bucket minute|hour|day] [--match <text>] [--width N]
///               [--since <ts>] [--until <ts>]
///                                    time-bucket histogram as text bars;
///                                    default window is the last 24h
///                                    (--since 0 for everything), pushed
///                                    down to segments; shares the query
///                                    guards and scans without the writer lock
///   dashboard <dir> [--last sec] [--since ms] [--until ms]
///            [--bucket minute|hour|day] [--by service|level|host|key]
///            [--service <svc>] [--quantile-field <f>] [--top N] [--json]
///                                    ops panel for daily inspection (5.5):
///                                    volume/error histogram, per-bucket
///                                    latency trend (p50/p95/p99), window
///                                    totals, dimension breakdown;
///                                    --since/--until drills into a
///                                    historical incident window
///   anomalies <dir> [--baseline sec] [--recent sec] [--since ms] [--until ms]
///            [--service <svc>] [--sigma N] [--min-count N] [--top N] [--json]
///                                    automatic anomaly detection (5.6) —
///                                    volume spikes, NEW error patterns vs
///                                    the baseline period, hour-of-day
///                                    seasonal deviations; no rules needed;
///                                    KV/JSON values, --since/--until for
///                                    historical triage
///   audit <dir> [--actor <name>] [--action <cmd>] [--decision allow|deny]
///               [--since ms] [--until ms] [--limit N] [--json] [--all]
///               [--verify] [--rotate --keep N]
///                                    query the operation audit trail (6.3):
///                                    filter by actor/action/decision and
///                                    event-time window, newest first;
///                                    --json prints raw JSONL, --all includes
///                                    rotated files, --verify checks line
///                                    integrity, --rotate archives AUDIT

///|
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
///   tier <dir> <cold-dir> [--warm N] [--dry-run] [--json]
///                                    hot/warm/cold tiering: compress rolled
///                                    segments, move the oldest ones into
///                                    cold-dir behind symlinks (cold-dir must
///                                    be an absolute path; relative paths are
///                                    rejected because the symlink resolves
///                                    relative to the log directory)
///   fsck <dir> [fast] [--fix] [--dry-run]
///                                    verify integrity; --fix repairs what it
///                                    can; --dry-run only prints the repair plan
///   stats <dir> [json]               print record/segment counts (optionally JSON)
///   partitions <dir> [--unit day|hour] [--json]
///                                    group segments by event-time partition
///                                    bucket (segment count/records/bytes/UTC span)
///   partition-policy <dir> [day|hour|off] [--json]
///                                    show or persist the directory-level
///                                    partition policy: write commands without
///                                    --partition then roll partitions
///                                    automatically (explicit flags override)
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
  // Explicit unique-ID dedup: when set, the parsed field with this name is a
  // record ID. Seen IDs are kept in `<dir>/DEDUP` and a repeated ID is skipped
  // even when the payload differs; the ID is also embedded in the value so the
  // set can be rebuilt from the log after a crash.
  dedup_field_bytes : Bytes?
  sampling : @core.SamplingConfig?
  from_bytes : Int64?
  schema : Bool
  clock_skew_ms : Int64
  // Per-record clock-skew offset field (milliseconds), added on top of the
  // global --clock-skew: deployments with several agents can carry each
  // source's drift in the line instead of one fixed offset.
  clock_skew_field_bytes : Bytes?
  mask : Bool
  mask_extra : Array[Bytes]
  meta_bytes : Bytes?
  partition_ms : Int64
  // 6.2: the HTTP push server accounts each tenant's write quota when the
  // request is accepted (202), so its drain path must not account again.
  skip_quota : Bool
  // Durability policy for this ingest pipeline. Commands keep the CLI default
  // (Always, MOONLOG_SYNC overridable); the HTTP drain uses Batch so backlog
  // recovery fsyncs once per --batch instead of once per line.
  sync : @log.SyncPolicy
}

///|
const ROLL_SIZE : Int64 = 1_048_576

///|
const MOONLOG_VERSION : String = "0.1.3"

///|
const USAGE : String = "usage: moonlog <put|put-if|put-batch|delete|get|getkey|get-many|getkey-live|has-key|scan|scan-prefix|scan-range|scan-time|tail|follow|ingest|http|parse-check|bench-write|search|query|context|aggregate|cluster|trend|alert|baseline|rbac|quota|drill|selfmon|recover|prune|prune-bytes|prune-before|prune-expired|prune-superseded|merge|maintain|serve|ttl-expire|replicate|ha-failover|ha-status|ha-rebalance|ha-watch|archive|cursor|cursor-commit|cursor-lag|cursor-save|cursor-load|cursor-list|cursor-drop|export|export-jsonl|purge|import|compact|compact-expired|compress|tier|fsck|stats|partitions|partition-policy|backup|restore> <dir> [args]"

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
/// Partition unit in ms for `--partition day|hour|off` (0 = time partitioning
/// off).
fn parse_partition(s : String) -> Int64 raise @io.IoError {
  if s == "day" {
    (86_400_000 : Int64)
  } else if s == "hour" {
    (3_600_000 : Int64)
  } else if s == "off" {
    (0 : Int64)
  } else {
    raise @io.IoError::Invalid("invalid partition: " + s + " (day|hour|off)")
  }
}

///|
/// Directory-level partition policy `<dir>/PARTITION` (one line: day|hour|off).
/// Persisting it lets every write command roll partitions without repeating
/// `--partition`; an explicit flag still overrides it. A missing or malformed
/// file means off (safe fallback, no data impact).
const PARTITION_FILE : String = "PARTITION"

///|
fn partition_unit_name(ms : Int64) -> String {
  if ms == (86_400_000 : Int64) {
    "day"
  } else if ms == (3_600_000 : Int64) {
    "hour"
  } else {
    "off"
  }
}

///|
fn load_partition_policy(dir : String) -> Int64 {
  let path = dir + "/" + PARTITION_FILE
  if !@backend_native.file_exists(path) {
    return (0 : Int64)
  }
  let data = @backend_native.read_file(path)
  let (lines, _) = split_complete_lines(data, true)
  for line in lines {
    let s = @utf8.decode_lossy(line).trim()
    if s == "day" {
      return (86_400_000 : Int64)
    }
    if s == "hour" {
      return (3_600_000 : Int64)
    }
  }
  (0 : Int64)
}

///|
fn save_partition_policy(dir : String, unit : String) -> Unit raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  @backend_native.write_file(
    dir + "/" + PARTITION_FILE,
    @utf8.encode(unit + "\n"),
  )
}

///|
fn open_log_sync(
  dir : String,
  partition : Int64,
  policy : @log.SyncPolicy,
) -> CliLog raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  let log = @backend_native.open_log_dir(
    dir,
    ROLL_SIZE,
    sync=policy,
    partition_ms=partition,
  )
  log.set_cursor_guard(min_cursor_guard(dir))
  log
}

///|
fn open_log(dir : String, partition~ : Int64 = 0) -> CliLog raise @io.IoError {
  open_log_sync(dir, partition, desired_sync())
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
/// Open the log under a short shared lock, release the lock, then run the
/// read action against the opened snapshot (4.6). Segments are append-only
/// and the reader keeps its fds, so a scan no longer holds the directory
/// lock: one slow query cannot stall ingestion. New records appended after
/// the snapshot are simply outside this query's view (snapshot semantics);
/// a concurrent compaction may unlink a segment file, but the open fd keeps
/// the snapshot readable.
fn[T] run_read_snapshot(
  dir : String,
  action : (CliLog) -> T raise @io.IoError,
) -> T raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  let lock = @backend_native.DirLock::acquire_timeout(
    dir,
    false,
    lock_timeout_ms(),
  )
  let log = open_log(dir)
  lock.release()
  let result = action(log)
  close_log(log)
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
fn ctx_is_sep(c : Int32) -> Bool {
  c == 46 || c == 45 || c == 95 || c == 64
}

///|
/// ASCII case-insensitive byte equality for correlation identifiers.
fn ctx_bytes_eq_ci(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    let ca = a.at(i).to_int()
    let cb = b.at(i).to_int()
    let la = if ca >= 65 && ca <= 90 { ca + 32 } else { ca }
    let lb = if cb >= 65 && cb <= 90 { cb + 32 } else { cb }
    if la != lb {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Compare field names after ASCII lowercasing and dropping `.`, `-`, `_` and
/// `@`, so `trace_id`, `traceId` and `trace.id` are equivalent (same
/// normalization as the unified schema, 2.2).
fn ctx_name_eq(a : Bytes, b : Bytes) -> Bool {
  let mut ia = 0
  let mut ib = 0
  while true {
    while ia < a.length() && ctx_is_sep(a.at(ia).to_int()) {
      ia = ia + 1
    }
    while ib < b.length() && ctx_is_sep(b.at(ib).to_int()) {
      ib = ib + 1
    }
    if ia >= a.length() || ib >= b.length() {
      return ia >= a.length() && ib >= b.length()
    }
    let ca = a.at(ia).to_int()
    let cb = b.at(ib).to_int()
    let la = if ca >= 65 && ca <= 90 { ca + 32 } else { ca }
    let lb = if cb >= 65 && cb <= 90 { cb + 32 } else { cb }
    if la != lb {
      return false
    }
    ia = ia + 1
    ib = ib + 1
  }
  false
}

///|
/// Parse a record value into field pairs: JSON objects are flattened (2.1),
/// anything else uses the kv parser.
fn ctx_value_fields(value : Bytes) -> Array[(Bytes, Bytes)] {
  if value.length() > 0 && value.at(0).to_int() == 123 {
    return @core.json_object_fields(value) catch { _ => [] }
  }
  @core.parse_kv_pairs(value)
}

///|
fn ctx_field_from_pairs(
  fields : Array[(Bytes, Bytes)],
  names : Array[Bytes],
) -> Bytes? {
  for pair in fields {
    for name in names {
      if ctx_name_eq(pair.0, name) {
        return Some(pair.1)
      }
    }
  }
  None
}

///|
/// Extract the first matching correlation field from a record value. KV pairs
/// are scanned first; JSON-object values are flattened (2.1) only then, so
/// `{"trace_id":"t9"}` works for `--trace-id auto` without a schema.
fn ctx_field_value(value : Bytes, names : Array[Bytes]) -> Bytes? {
  ctx_field_from_pairs(ctx_value_fields(value), names)
}

///|
fn cmd_put(
  dir : String,
  key : String,
  value : String,
  ts : String?,
  idempotent : Bool,
  dedup_id : String?,
  partition : Int64,
) -> Unit raise @io.IoError {
  let timestamp = match ts {
    Some(s) =>
      @string.parse_int64(s) catch {
        _ => raise @io.IoError::Invalid("invalid timestamp: " + s)
      }
    None => now_ms()
  }
  let uid : Bytes? = match dedup_id {
    Some(s) => {
      let u = @utf8.encode(s)
      if !dedup_uid_ok(u) {
        raise @io.IoError::Invalid("dedup id contains a tab/newline")
      }
      Some(u)
    }
    None => None
  }
  run_locked(dir, true, () => {
    let rule = active_quota_rule(dir)
    let kb = @utf8.encode(key)
    require_scope(dir, "put", kb)
    let vb0 = @utf8.encode(value)
    let vb = match uid {
      Some(u) => dedup_attach_uid(vb0, u)
      None => vb0
    }
    let incoming : Int64 = (kb.length() + vb.length()).to_int64()
    match quota_write_error(dir, rule, incoming) {
      Some(msg) => raise @io.IoError::Invalid(msg)
      None => ()
    }
    let log = open_log(dir, partition~)
    let seen = match uid {
      Some(_) => Some(load_dedup_locked(dir, log))
      None => None
    }
    let dup = match (seen, uid) {
      (Some(s), Some(u)) => s.contains(u)
      _ => false
    }
    if dup {
      println("skipped (duplicate id)")
    } else {
      let (added, off) = if idempotent {
        log.append_idempotent(kb, vb, timestamp)
      } else {
        let off = log.append(kb, vb, timestamp)
        (true, off)
      }
      if added {
        match (seen, uid) {
          (Some(s), Some(u)) => {
            s.set(u, true)
            dedup_append_entries(dir, [(off, u)])
          }
          _ => ()
        }
        quota_record_write(dir, rule, incoming)
        println("offset " + off.to_string())
        @backend_native.flush_meta(dir, log)
      } else {
        println("skipped " + off.to_string() + " (duplicate)")
      }
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
    let rule = active_quota_rule(dir)
    let kb = @utf8.encode(key)
    require_scope(dir, "put-if", kb)
    let vb = @utf8.encode(value)
    let incoming : Int64 = (kb.length() + vb.length()).to_int64()
    match quota_write_error(dir, rule, incoming) {
      Some(msg) => raise @io.IoError::Invalid(msg)
      None => ()
    }
    let log = open_log(dir)
    let expected_bytes : Bytes? = if expected == "-" {
      (None : Bytes?)
    } else {
      Some(@utf8.encode(expected))
    }
    let result = log.compare_and_swap(kb, expected_bytes, vb, now_ms())
    match result {
      Some(off) => {
        quota_record_write(dir, rule, incoming)
        println("offset " + off.to_string())
      }
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
    let rule = active_quota_rule(dir)
    let recs : Array[(Bytes, Bytes, Int64)] = []
    let mut incoming : Int64 = 0
    let mut i = 3
    while i < n {
      let kb = @utf8.encode(args[i])
      require_scope(dir, "put-batch", kb)
      let vb = @utf8.encode(args[i + 1])
      incoming = incoming + (kb.length() + vb.length()).to_int64()
      recs.push((kb, vb, now_ms()))
      i = i + 2
    }
    match quota_write_error(dir, rule, incoming) {
      Some(msg) => raise @io.IoError::Invalid(msg)
      None => ()
    }
    let log = open_log(dir)
    let offsets = log.append_batch(recs)
    quota_record_write(dir, rule, incoming)
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
    let kb = @utf8.encode(key)
    require_scope(dir, "delete", kb)
    let log = open_log(dir)
    let off = log.delete(kb, now_ms())
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
      Some(rec) => {
        require_scope(dir, "get", rec.key)
        print_record(rec)
      }
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
    let scope = active_scope(dir)
    let mut count = 0
    log.for_each_while(lo, hi, rec => {
      if !scope_allows_key(scope, rec.key) {
        return true
      }
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
    let scope = active_scope(dir)
    let recs = log.scan_prefix(@utf8.encode(prefix))
    let mut count = 0
    for rec in recs {
      if scope_allows_key(scope, rec.key) {
        print_record(rec)
        count = count + 1
      }
    }
    println("(" + count.to_string() + " records)")
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
    let scope = active_scope(dir)
    let recs = log.scan_key_range(@utf8.encode(lo), hi_bytes)
    let mut count = 0
    for rec in recs {
      if scope_allows_key(scope, rec.key) {
        print_record(rec)
        count = count + 1
      }
    }
    println("(" + count.to_string() + " records)")
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
    let scope = active_scope(dir)
    let mut count = 0
    log.for_each_time_range(lo_ts, hi_ts, rec => {
      if !scope_allows_key(scope, rec.key) {
        return true
      }
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
    let scope = active_scope(dir)
    let mut count = 0
    log.for_each_while(from, total, rec => {
      if !scope_allows_key(scope, rec.key) {
        return true
      }
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

///|
/// Show or set the directory-level partition policy (`PARTITION`). With no
/// unit it prints the current policy; `day|hour|off` persists it so later
/// write commands roll partitions without repeating `--partition`.
fn cmd_partition_policy(
  dir : String,
  unit : String?,
  json : Bool,
) -> Unit raise @io.IoError {
  match unit {
    Some(u) => {
      if u != "day" && u != "hour" && u != "off" {
        raise @io.IoError::Invalid(
          "invalid partition: " + u + " (day|hour|off)",
        )
      }
      save_partition_policy(dir, u)
    }
    None => ()
  }
  let name = partition_unit_name(load_partition_policy(dir))
  if json {
    println("{\"partition\":\"" + name + "\"}")
  } else {
    println("partition: " + name + " (dir " + dir + ")")
  }
}

///|
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
      out.write_string(
        "{\"unit\":\"" +
        unit +
        "\",\"policy\":\"" +
        partition_unit_name(load_partition_policy(dir)) +
        "\",\"partitions\":[",
      )
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
        "(" +
        parts.length().to_string() +
        " partitions, unit " +
        unit +
        ", policy " +
        partition_unit_name(load_partition_policy(dir)) +
        ")",
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

///|
/// Parse a sample file with the same field extractors used by ingest and
/// report per-line extraction plus an accuracy summary. Read-only: use it to
/// validate `--format json|kv|template` and a template before wiring a source.
fn cmd_parse_check(
  file : String,
  format : String,
  template : String?,
  sample_n : Int32,
  as_json : Bool,
  schema : Bool,
) -> Unit raise @io.IoError {
  if format != "lines" &&
    format != "kv" &&
    format != "json" &&
    format != "template" {
    raise @io.IoError::Invalid(
      "invalid format: " + format + " (lines|kv|json|template)",
    )
  }
  let tpl = match template {
    Some(s) => @utf8.encode(s)
    None => b""
  }
  if format == "template" && tpl.length() == 0 {
    raise @io.IoError::Invalid("template format requires --template")
  }
  if !@backend_native.file_exists(file) {
    raise @io.IoError::Invalid("file not found: " + file)
  }
  let data = @backend_native.read_file(file)
  let (rows, _) = split_complete_lines(data, true)
  let mut parsed = 0
  let mut failed = 0
  let mut fields_total = 0
  let mut empty_fields = 0
  let mut schema_present = 0
  let samples : Array[String] = []
  let json_samples : Array[String] = []
  let mut i = 0
  while i < rows.length() {
    let line = rows[i]
    let mut ok = true
    let mut fields : Array[(Bytes, Bytes)] = []
    if format == "json" {
      let maybe : Array[(Bytes, Bytes)]? = Some(@core.json_object_fields(line)) catch {
        _ => None
      }
      match maybe {
        Some(f) => fields = f
        None => ok = false
      }
    } else if format == "template" {
      match @core.parse_by_template(line, tpl) {
        Some(f) => fields = f
        None => ok = false
      }
    } else if format == "kv" {
      fields = @core.parse_kv_pairs(line)
    }
    if ok {
      parsed = parsed + 1
    } else {
      failed = failed + 1
    }
    if schema {
      let sf = @core.schema_from_fields(fields, (0 : Int64))
      let norm : Array[(Bytes, Bytes)] = []
      match sf.ts {
        Some(t) => norm.push((b"ts", @utf8.encode(t.to_string())))
        None => ()
      }
      match sf.level {
        Some(v) => norm.push((b"level", v))
        None => ()
      }
      match sf.service {
        Some(v) => norm.push((b"service", v))
        None => ()
      }
      match sf.host {
        Some(v) => norm.push((b"host", v))
        None => ()
      }
      match sf.trace_id {
        Some(v) => norm.push((b"trace_id", v))
        None => ()
      }
      match sf.message {
        Some(v) => norm.push((b"message", v))
        None => ()
      }
      fields = norm
      schema_present = schema_present + norm.length()
    }
    fields_total = fields_total + fields.length()
    for pair in fields {
      if pair.1.length() == 0 {
        empty_fields = empty_fields + 1
      }
    }
    if samples.length() < sample_n {
      let mut text = "line " + (i + 1).to_string() + ": "
      if !ok {
        text = text + "<unparsed>"
      } else if fields.length() == 0 {
        text = text + "<no fields>"
      } else {
        let mut first = true
        for pair in fields {
          if !first {
            text = text + " "
          }
          first = false
          text = text +
            (@utf8.decode(pair.0) catch { _ => "" }) +
            "=" +
            (@utf8.decode(pair.1) catch { _ => "" })
        }
      }
      samples.push(text)
      let mut js = "{\"line\":" +
        (i + 1).to_string() +
        ",\"ok\":" +
        (if ok { "true" } else { "false" }) +
        ",\"fields\":["
      let mut first_field = true
      for pair in fields {
        if !first_field {
          js = js + ","
        }
        first_field = false
        js = js +
          "[\"" +
          json_escape_str(@utf8.decode(pair.0) catch { _ => "" }) +
          "\",\"" +
          json_escape_str(@utf8.decode(pair.1) catch { _ => "" }) +
          "\"]"
      }
      js = js + "]}"
      json_samples.push(js)
    }
    i = i + 1
  }
  let pct = if rows.length() == 0 { 100 } else { parsed * 100 / rows.length() }
  if as_json {
    let mut out = "{\"lines\":" +
      rows.length().to_string() +
      ",\"parsed\":" +
      parsed.to_string() +
      ",\"failed\":" +
      failed.to_string() +
      ",\"accuracy_pct\":" +
      pct.to_string() +
      ",\"fields\":" +
      fields_total.to_string() +
      ",\"empty_fields\":" +
      empty_fields.to_string() +
      (if schema {
        ",\"schema_fields\":" + schema_present.to_string()
      } else {
        ""
      }) +
      ",\"samples\":["
    let mut first = true
    for s in json_samples {
      if !first {
        out = out + ","
      }
      first = false
      out = out + s
    }
    out = out + "]}"
    println(out)
  } else {
    println(
      "parse-check: " +
      rows.length().to_string() +
      " lines, " +
      parsed.to_string() +
      " parsed (" +
      pct.to_string() +
      "%), " +
      failed.to_string() +
      " failed, " +
      fields_total.to_string() +
      " fields, " +
      empty_fields.to_string() +
      " empty" +
      (if schema {
        ", schema " + schema_present.to_string() + " fields"
      } else {
        ""
      }),
    )
    for s in samples {
      println(s)
    }
  }
}

///|
fn cmd_stats(dir : String, json : Bool) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let detail = log.segment_summaries()
    let mut raw_total : Int64 = 0
    let mut disk_total : Int64 = 0
    let actual_disk : Array[Int64] = []
    for seg in detail {
      raw_total = raw_total + seg.bytes
      // Use the real file size (following cold-tier symlinks): a compressed
      // segment's `reader.length()` is its logical size, which would hide the
      // compression gain in `stats`.
      let d = @backend_native.file_size(
        dir + "/" + @segment.segment_file_name(seg.base_offset),
      )
      actual_disk.push(d)
      disk_total = disk_total + d
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
      let mut i = 0
      while i < detail.length() {
        let seg = detail[i]
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
          actual_disk[i].to_string() +
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
        i = i + 1
      }
      println(s + "]}")
    } else {
      println("records " + log.count().to_string())
      println("segments " + log.segment_count().to_string())
      println("next_offset " + log.next_offset().to_string())
      println("raw_bytes " + raw_total.to_string())
      println("disk_bytes " + disk_total.to_string())
      let mut i = 0
      while i < detail.length() {
        let seg = detail[i]
        println(
          "seg " +
          seg.base_offset.to_string() +
          " records=" +
          seg.records.to_string() +
          " bytes=" +
          seg.bytes.to_string() +
          " disk=" +
          actual_disk[i].to_string() +
          " compressed=" +
          (if seg.compressed { "true" } else { "false" }),
        )
        i = i + 1
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
/// Append a TTL expiry event to `<dir>/TTL_AUDIT` (JSONL), so retention
/// actions stay auditable beyond the one-line command output. Atomic append
/// (O_APPEND), so concurrent maintain passes never overwrite each other.
fn append_ttl_audit(
  dir : String,
  policy_text : String,
  dropped : Int32,
  expired : Int32,
  trigger : String,
) -> Unit {
  let path = ttl_audit_path(dir)
  let line = "{\"ts\":" +
    now_ms().to_string() +
    ",\"event\":\"ttl_expire\"" +
    ",\"trigger\":\"" +
    json_escape_str(trigger) +
    "\"" +
    ",\"segments_dropped\":" +
    dropped.to_string() +
    ",\"records_expired\":" +
    expired.to_string() +
    ",\"policy\":\"" +
    json_escape_str(policy_text) +
    "\"}\n"
  ignore(
    @backend_native.append_file(path, @utf8.encode(line)) catch {
      _ => ()
    },
  )
}

///|
/// The TTL audit path (6.3): `<dir>/TTL_AUDIT` — renamed from the legacy
/// `TTL_AUDIT.log` (whose `.log` suffix made recovery treat it as a
/// segment) on first use, keeping prior history.
fn ttl_audit_path(dir : String) -> String {
  let legacy = dir + "/TTL_AUDIT.log"
  if @backend_native.file_exists(legacy) {
    ignore(@backend_native.rename_file(legacy, dir + "/TTL_AUDIT"))
  }
  dir + "/TTL_AUDIT"
}

///|
/// Policy-driven TTL expiry (3.4): read `<dir>/TTL` — `default <days>`,
/// `service <name> <days>` and `level <level> <days>` lines ('#' comments
/// allowed) — evaluate every record (service matches the key, level the
/// parsed level field; the stricter one wins, default otherwise) and drop
/// segments whose records have all expired. `--dry-run` prints the plan
/// without touching data; every applied run appends a JSONL event to
/// `<dir>/TTL_AUDIT` so cleanup stays auditable.
fn cmd_ttl_expire(
  dir : String,
  dry_run : Bool,
  json : Bool,
) -> Unit raise @io.IoError {
  let ppath = dir + "/TTL"
  let raw = if @backend_native.file_exists(ppath) {
    @backend_native.read_file(ppath)
  } else {
    b""
  }
  let base : @core.TtlPolicy = if raw.length() == 0 {
    { default_days: -1, rules: [], }
  } else {
    match @core.parse_ttl_policy(raw) {
      Some(p) => p
      None => raise @io.IoError::Invalid("invalid TTL policy file: " + ppath)
    }
  }
  // 6.2: per-tenant retain-days overrides join as prefix rules (strictest
  // matching rule wins, so quotas only tighten file-based retention). Apply
  // them even when the TTL file is absent: a QUOTA-only retention policy must
  // not silently no-op.
  let policy = effective_ttl_policy(dir, base)
  if policy.default_days < 0 && policy.rules.length() == 0 {
    if json {
      println(
        "{\"policy\":false,\"dry_run\":" +
        (if dry_run { "true" } else { "false" }) +
        ",\"segments_dropped\":0,\"records_expired\":0}",
      )
    } else {
      println(
        "no retention policy (TTL absent and no QUOTA retain-days) — nothing to do",
      )
    }
    return
  }
  let audit_policy = if raw.length() > 0 {
    @utf8.decode_lossy(raw)
  } else {
    "from QUOTA retain-days"
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
    if !dry_run {
      quota_recalc_storage_quiet(dir)
      append_ttl_audit(dir, audit_policy, dropped, expired, "cli")
    }
    if json {
      println(
        "{\"policy\":true,\"dry_run\":" +
        (if dry_run { "true" } else { "false" }) +
        ",\"segments_dropped\":" +
        dropped.to_string() +
        ",\"records_expired\":" +
        expired.to_string() +
        ",\"audited\":" +
        (if dry_run { "false" } else { "true" }) +
        "}",
      )
    } else if dry_run {
      println(
        "dry-run: would drop " +
        dropped.to_string() +
        " segment(s), " +
        expired.to_string() +
        " record(s) expired",
      )
    } else {
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
    let raw_policy = if @backend_native.file_exists(ttl_path) {
      @backend_native.read_file(ttl_path)
    } else {
      b""
    }
    let base_policy : @core.TtlPolicy = if raw_policy.length() == 0 {
      { default_days: -1, rules: [], }
    } else {
      match @core.parse_ttl_policy(raw_policy) {
        Some(p) => p
        None => { default_days: -1, rules: [], }
      }
    }
    let policy = effective_ttl_policy(dir, base_policy)
    if policy.default_days >= 0 || policy.rules.length() > 0 {
      let (td, te) = log.expire_by_policy(now_ms(), policy, on_drop=seg => {
        @backend_native.remove_segment_files(dir, seg.base_offset)
        seg.writer.close()
      })
      let audit_policy = if raw_policy.length() > 0 {
        @utf8.decode_lossy(raw_policy)
      } else {
        "from QUOTA retain-days"
      }
      append_ttl_audit(dir, audit_policy, td, te, "maintain")
    }
    // Build the inverted/field-column sidecars so indexed queries load them
    // instead of rebuilding from data (3.2). Idempotent.
    for seg in log.segments {
      seg.ensure_inv_index()
    }
    @backend_native.flush_meta(dir, log)
    close_log(log)
    quota_recalc_storage_quiet(dir)
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
    let kb = @utf8.encode(key)
    require_scope(dir, "has-key", kb)
    let log = open_log(dir)
    match log.get_latest_bloom(kb) {
      Some(_) => println("present")
      None => println("absent")
    }
    close_log(log)
  })
}

///|
fn cmd_getkey(dir : String, key : String) -> Unit raise @io.IoError {
  run_locked(dir, false, () => {
    let kb = @utf8.encode(key)
    require_scope(dir, "getkey", kb)
    let log = open_log(dir)
    let index = log.build_key_index()
    match log.get_latest(index, kb) {
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
    for k in keys {
      require_scope(dir, "get-many", k)
    }
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
    let kb = @utf8.encode(key)
    require_scope(dir, "getkey-live", kb)
    let log = open_log(dir)
    let index = log.build_key_index()
    match log.get_latest_at(index, kb, now_ms(), ttl_ms) {
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
    quota_recalc_storage_quiet(dir)
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
    quota_recalc_storage_quiet(dir)
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
  json : Bool,
) -> Unit raise @io.IoError {
  // A relative cold path would make the per-segment symlink resolve relative
  // to the main directory and silently point at nothing (segments become
  // unreadable). Demand an absolute path so tiering cannot break reads.
  if cold_dir.length() == 0 || cold_dir.at(0).to_int() != 47 {
    raise @io.IoError::Invalid("cold-dir must be an absolute path: " + cold_dir)
  }
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
      close_log(log)
      if json {
        println(
          "{\"dry_run\":true,\"segments\":" +
          n.to_string() +
          ",\"cold\":" +
          to_move.to_string() +
          ",\"warm\":" +
          warm_n.to_string() +
          ",\"cold_dir\":\"" +
          json_escape_str(cold_dir) +
          "\"}",
        )
      } else {
        println(
          "tier plan: " +
          to_move.to_string() +
          " cold of " +
          n.to_string() +
          " segments (warm " +
          warm_n.to_string() +
          ")",
        )
      }
    })
  } else {
    run_locked(dir, true, () => {
      let moved = @backend_native.tier_log_dir(dir, cold_dir, ROLL_SIZE, warm_n)
      if json {
        println(
          "{\"dry_run\":false,\"moved\":" +
          moved.to_string() +
          ",\"warm\":" +
          warm_n.to_string() +
          ",\"cold_dir\":\"" +
          json_escape_str(cold_dir) +
          "\"}",
        )
      } else {
        println(
          "tiered " + moved.to_string() + " segments cold into " + cold_dir,
        )
      }
    })
  }
}

///|
const ARCHIVE_MAGIC : UInt32 = 0x4D4C4152

///|
fn archive_u32(data : Bytes, pos : Int32) -> UInt32 {
  data.at(pos).to_uint() |
  (data.at(pos + 1).to_uint() << 8) |
  (data.at(pos + 2).to_uint() << 16) |
  (data.at(pos + 3).to_uint() << 24)
}

///|
/// Log data files worth archiving (6.5): the manifest, segment files, every
/// sidecar (.index/.keys/.inv) and the operator policy files (RBAC/TTL/
/// QUOTA) — the same durable set a backup carries, so an extracted archive
/// also restores the configuration.
fn archive_file_names(dir : String) -> Array[String] raise @io.IoError {
  let out : Array[String] = []
  for name in @backend_native.list_dir(dir) {
    if name == "MANIFEST" ||
      name.has_suffix(".log") ||
      name.has_suffix(".log.index") ||
      name.has_suffix(".log.keys") ||
      name.has_suffix(".log.inv") ||
      name == "RBAC" ||
      name == "TTL" ||
      name == "QUOTA" ||
      name == "PARTITION" ||
      name == "AUDIT" ||
      name == "TTL_AUDIT" {
      out.push(name)
    }
  }
  out
}

///|
/// Pack `dir`'s log data files (MANIFEST, segments, sidecars) into the single
/// archive `file` — magic, version, file table, contents, trailing CRC32 — a
/// self-contained artifact that one PUT can place into any object store (3.6).
/// Returns the number of files packed.
fn archive_pack(dir : String, file : String) -> Int32 raise @io.IoError {
  let names = archive_file_names(dir)
  if names.length() == 0 {
    raise @io.IoError::Invalid("no log data files in " + dir)
  }
  let body = @buffer.Buffer::Buffer()
  body.write_uint_le(ARCHIVE_MAGIC)
  body.write_uint_le((1 : UInt32))
  body.write_uint_le(names.length().reinterpret_as_uint())
  for name in names {
    let content = @backend_native.read_file(dir + "/" + name)
    let nb = @utf8.encode(name)
    body.write_uint_le(nb.length().reinterpret_as_uint())
    body.write_bytes(nb)
    body.write_uint_le(content.length().reinterpret_as_uint())
    body.write_bytes(content)
  }
  let bytes = body.to_bytes()
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(bytes)
  out.write_uint_le(@core.crc32(bytes))
  @backend_native.write_file(file, out.to_bytes())
  names.length()
}

///|
/// Parse and validate an archive produced by `archive_pack`: magic, version
/// and the trailing CRC32; returns (name, content) pairs in order. Malformed
/// archives raise `IoError::Invalid` (the CLI-level error type).
fn archive_entries(data : Bytes) -> Array[(String, Bytes)] raise @io.IoError {
  let bad = fn(why : String) -> @io.IoError {
    @io.IoError::Invalid("invalid archive file: " + why)
  }
  let total = data.length()
  if total < 20 {
    raise bad("truncated")
  }
  if archive_u32(data, 0) != ARCHIVE_MAGIC {
    raise bad("bad magic")
  }
  if archive_u32(data, 4) != (1 : UInt32) {
    raise bad("bad version")
  }
  let body_end = total - 4
  let expected = archive_u32(data, body_end)
  let actual = @core.crc32_range(data, 0, body_end)
  if expected != actual {
    raise bad("crc mismatch")
  }
  let count = archive_u32(data, 8).reinterpret_as_int()
  let out : Array[(String, Bytes)] = []
  let mut pos = 12
  let mut i = 0
  while i < count {
    // Entry layout (matching archive_pack): name_len u32, name bytes,
    // content_len u32, content bytes.
    if pos + 4 > body_end {
      raise bad("truncated entry header")
    }
    let name_len = archive_u32(data, pos).reinterpret_as_int()
    if name_len < 0 {
      raise bad("bad name length")
    }
    let name_start = pos + 4
    let len_at = name_start + name_len
    if len_at + 4 > body_end {
      raise bad("truncated entry header")
    }
    let content_len = archive_u32(data, len_at).reinterpret_as_int()
    let content_start = len_at + 4
    if content_len < 0 || content_start + content_len > body_end {
      raise bad("truncated entry")
    }
    let name = bytes_to_string(
      @core.slice(data, name_start, name_start + name_len),
    )
    out.push(
      (name, @core.slice(data, content_start, content_start + content_len)),
    )
    pos = content_start + content_len
    i = i + 1
  }
  if pos != body_end {
    raise bad("trailing garbage")
  }
  out
}

///|
/// Object-storage archive for tiered logs (3.6): pack a directory's log data
/// files into a single self-contained file (CRC32 checked) that one PUT can
/// upload to any object store. `--list` prints the contents; `--extract
/// --into <dir>` restores them into a directory (validated).
fn cmd_archive(
  dir : String,
  file : String,
  list : Bool,
  extract : Bool,
  into : String?,
) -> Unit raise @io.IoError {
  if list {
    let entries = archive_entries(@backend_native.read_file(file))
    for pair in entries {
      println(pair.0 + "  " + pair.1.length().to_string() + " bytes")
    }
    println("(" + entries.length().to_string() + " files)")
    return
  }
  if extract {
    let dst = match into {
      Some(d) => d
      None => raise @io.IoError::Invalid("--extract requires --into <dir>")
    }
    ignore(@backend_native.ensure_dir(dst))
    let entries = archive_entries(@backend_native.read_file(file))
    for pair in entries {
      @backend_native.write_file(dst + "/" + pair.0, pair.1)
      println("extracted " + pair.0)
    }
    return
  }
  let n = archive_pack(dir, file)
  let size = @backend_native.file_size(file)
  println(
    "archived " +
    n.to_string() +
    " file(s) to " +
    file +
    " (" +
    size.to_string() +
    " bytes)",
  )
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
/// Whether `data` starts with `prefix` byte for byte (CLI-side helper; the
/// core one is private to ttlpolicy).
fn bytes_has_prefix_cli(data : Bytes, prefix : Bytes) -> Bool {
  if data.length() < prefix.length() {
    return false
  }
  let mut i = 0
  while i < prefix.length() {
    if data.at(i) != prefix.at(i) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Export records as JSON Lines (one self-contained JSON object per line:
/// `offset`, `timestamp`, `kind`, `key`, `value`). The default text
/// mode assumes keys/values are UTF-8 text; pass `base64` as the third
/// argument for a lossless encoding of arbitrary bytes. Optional filters
/// (6.6) narrow the export to a key `--prefix`, a `--match` substring over
/// key/value, or a `--from/--until` timestamp window — a query result can
/// then be handed off in a universally parseable format.
fn cmd_export_jsonl(
  dir : String,
  file : String,
  mode : String,
  prefix : String?,
  match_text : String?,
  from_ts : String?,
  until_ts : String?,
) -> Unit raise @io.IoError {
  if mode != "text" && mode != "base64" {
    raise @io.IoError::Invalid("invalid mode: " + mode + " (text|base64)")
  }
  let b64 = mode == "base64"
  let pb : Bytes = match prefix {
    Some(p) => @utf8.encode(p)
    None => b""
  }
  let has_prefix = prefix is Some(_)
  let mb : Bytes = match match_text {
    Some(m) => @utf8.encode(m)
    None => b""
  }
  let has_match = match_text is Some(_)
  let from = match from_ts {
    Some(s) =>
      Some(
        @string.parse_int64(s) catch {
          _ => raise @io.IoError::Invalid("invalid --from: " + s)
        },
      )
    None => None
  }
  let until = match until_ts {
    Some(s) =>
      Some(
        @string.parse_int64(s) catch {
          _ => raise @io.IoError::Invalid("invalid --until: " + s)
        },
      )
    None => None
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    let scope = active_scope(dir)
    let buf = @buffer.Buffer::Buffer()
    let mut count = 0
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      if !scope_allows_key(scope, rec.key) {
        return true
      }
      if has_prefix && !bytes_has_prefix_cli(rec.key, pb) {
        return true
      }
      if has_match &&
        !@core.bytes_contains(rec.key, mb) &&
        !@core.bytes_contains(rec.value, mb) {
        return true
      }
      match from {
        Some(f) => if rec.timestamp < f { return true }
        None => ()
      }
      match until {
        Some(u) => if rec.timestamp >= u { return true }
        None => ()
      }
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
/// Compliance purge (6.6): delete every live record whose key starts with
/// `prefix` — the erasure path for a data subject's records. With
/// `--into <file>` the matching records are first exported as JSONL (a
/// universally parseable retention copy), then tombstones are written and
/// the directory is physically compacted, so the erased records and their
/// tombstones are gone from disk. The sweep afterwards verifies zero
/// remaining matches and the report states `PURGE status=ok|fail`.
/// Offsets are renumbered by the compaction (cursors need resetting).
fn cmd_purge(
  dir : String,
  prefix : String,
  into : String?,
) -> Unit raise @io.IoError {
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let pb = @utf8.encode(prefix)
    let now = now_ms()
    let buf = @buffer.Buffer::Buffer()
    let mut exported = 0
    let mut matched_records = 0
    let keys : Array[Bytes] = []
    // Sweep once: retention copy and key collection over the live records.
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      if !rec.is_delete() && bytes_has_prefix_cli(rec.key, pb) {
        matched_records = matched_records + 1
        match into {
          Some(_) => {
            buf.write_bytes(b"{\"offset\":")
            buf.write_bytes(@utf8.encode(rec.offset.to_string()))
            buf.write_bytes(b",\"timestamp\":")
            buf.write_bytes(@utf8.encode(rec.timestamp.to_string()))
            buf.write_bytes(b",\"kind\":")
            buf.write_bytes(
              if rec.is_delete() {
                b"\"delete\""
              } else {
                b"\"put\""
              },
            )
            buf.write_bytes(b",\"key\":")
            write_json_string(buf, rec.key, false)
            buf.write_bytes(b",\"value\":")
            write_json_string(buf, rec.value, false)
            buf.write_bytes(b"}\n")
            exported = exported + 1
          }
          None => ()
        }
        let mut seen = false
        for k in keys {
          if k == rec.key {
            seen = true
          }
        }
        if !seen {
          keys.push(rec.key)
        }
      }
      true
    })
    match into {
      Some(file) => @backend_native.write_file(file, buf.to_bytes())
      None => ()
    }
    // Erase: tombstone every matched key, then physically compact so the
    // records and their tombstones leave the segment files.
    for k in keys {
      ignore(log.delete(k, now))
    }
    let live = log.compact(on_drop=seg => {
      @backend_native.remove_segment_files(dir, seg.base_offset)
      seg.writer.close()
    })
    @backend_native.flush_meta(dir, log)
    // Verify (6.6): after compaction nothing matching the prefix remains.
    let mut remaining = 0
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      if !rec.is_delete() && bytes_has_prefix_cli(rec.key, pb) {
        remaining = remaining + 1
      }
      true
    })
    close_log(log)
    let status = if remaining == 0 { "ok" } else { "fail" }
    println("PURGE status=" + status)
    println("prefix: " + prefix)
    match into {
      Some(file) =>
        println(
          "exported: " +
          exported.to_string() +
          " records -> " +
          file +
          " (parseable JSONL retention copy)",
        )
      None => ()
    }
    println(
      "deleted: keys=" +
      keys.length().to_string() +
      " records=" +
      matched_records.to_string(),
    )
    println("compacted: live_records=" + live.to_string())
    println(
      "verified: remaining=" +
      remaining.to_string() +
      " (prefix scan after physical compaction)",
    )
    println("warning: offsets renumbered; reset any cursors (cursor-commit 0)")
    quota_recalc_storage_quiet(dir)
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
/// Remove a directory tree (contents first, then the directory itself);
/// best effort — cleanup failures never break a drill.
fn remove_tree(path : String) -> Unit {
  let names = @backend_native.list_dir(path) catch { _ => [] }
  for name in names {
    ignore(@backend_native.remove_file(path + "/" + name))
  }
  ignore(@backend_native.remove_file(path))
}

///|
/// Configuration-consistency check for a recovery drill (6.5): across the
/// policy files the result is "absent" when neither side carries any,
/// "ok" when every present policy matches byte for byte, and "mismatch"
/// otherwise — a diverging policy would silently change retention or
/// access behavior on the restored copy.
fn drill_config_check(dir : String, rst : String) -> String {
  let files = ["RBAC", "TTL", "QUOTA", "PARTITION"]
  let mut result = "absent"
  for f in files {
    let src_has = @backend_native.file_exists(dir + "/" + f)
    let dst_has = @backend_native.file_exists(rst + "/" + f)
    let state = if src_has && dst_has {
      let a = @backend_native.read_file(dir + "/" + f)
      let b = @backend_native.read_file(rst + "/" + f)
      if a == b {
        "ok"
      } else {
        "mismatch"
      }
    } else if src_has || dst_has {
      "mismatch"
    } else {
      "absent"
    }
    if state == "mismatch" {
      result = "mismatch"
    } else if state == "ok" && result == "absent" {
      result = "ok"
    }
  }
  result
}

///|
/// One-key recovery drill (6.5): back `dir` up into a scratch directory,
/// restore it into a second one, fast-verify the restored copy, reconcile
/// record counts and offsets against the live directory, compare the policy
/// files and spot-read the first and last record — proving a real restore
/// succeeds end to end. The live directory is only ever read (under its
/// shared lock) and the scratch directories are removed unless `--keep`.
fn cmd_drill(dir : String, keep : Bool) -> Unit raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  let bak = dir + ".drill-backup"
  let rst = dir + ".drill-restore"
  remove_tree(bak)
  remove_tree(rst)
  let mut backup_files = 0
  let mut restored_segs = 0
  let mut verify_status = "fail"
  let mut verify_records = -1
  let mut src_records = -1
  let mut match_ok = false
  let mut config_status = "absent"
  let mut spot_ok = false

  // 1. Backup: flush data and metadata, then copy the durable set under the
  // exclusive lock.
  run_locked(dir, true, () => {
    let log = open_log(dir)
    log.flush()
    @backend_native.flush_meta(dir, log)
    close_log(log)
    ignore(@backend_native.backup_log_dir(dir, bak))
    backup_files = (@backend_native.list_dir(bak) catch { _ => [] }).length()
  })

  // 2. Restore into the scratch directory (empty by construction).
  restored_segs = @backend_native.restore_log_dir(bak, rst)

  // 3. Verify and reconcile against the live directory (shared lock).
  run_locked(dir, false, () => {
    let src_log = open_log(dir)
    src_records = src_log.count()
    let src_next = src_log.next_offset()
    let first_src = src_log.get((0 : UInt64))
    let last_src = if src_next > (0 : UInt64) {
      src_log.get(src_next - (1 : UInt64))
    } else {
      None
    }
    let rst_log = open_log(rst)
    let report = rst_log.verify_fast()
    verify_records = report.records
    let verify_ok = report.first_bad_offset is None &&
      report.first_bad_checksum is None
    let next_ok = rst_log.next_offset() == src_next
    let first_rst = rst_log.get((0 : UInt64))
    let last_rst = if src_next > (0 : UInt64) {
      rst_log.get(src_next - (1 : UInt64))
    } else {
      None
    }
    let spot = match (first_src, first_rst, last_src, last_rst) {
      (Some(a), Some(b), Some(c), Some(d)) =>
        a.key == b.key &&
        a.value == b.value &&
        c.key == d.key &&
        c.value == d.value
      (None, None, None, None) => true
      _ => false
    }
    spot_ok = spot
    config_status = drill_config_check(dir, rst)
    match_ok = verify_ok &&
      next_ok &&
      verify_records == src_records &&
      spot &&
      config_status != "mismatch"
    verify_status = if match_ok { "ok" } else { "fail" }
    close_log(src_log)
    close_log(rst_log)
  })

  let status = if match_ok { "ok" } else { "fail" }
  println("DRILL status=" + status)
  println("backup: files=" + backup_files.to_string() + " path=" + bak)
  println("restore: segments=" + restored_segs.to_string() + " path=" + rst)
  println(
    "verify: " +
    verify_status +
    " records=" +
    verify_records.to_string() +
    " source_records=" +
    src_records.to_string() +
    " spot_read=" +
    (if spot_ok { "ok" } else { "fail" }),
  )
  println("config: " + config_status)
  if !keep {
    remove_tree(bak)
    remove_tree(rst)
    println("cleanup: scratch removed (use --keep to inspect)")
  } else {
    println("cleanup: kept (" + bak + ", " + rst + ")")
  }
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

///|
/// Directory role marker used by the HA helpers (3.5): `<dir>/HA_STATE` with
/// `role=primary|standby`, `switched_at=<ms>`, `switched_from=<path>`.
const HA_STATE_FILE : String = "HA_STATE"

///|
fn ha_state_path(dir : String) -> String {
  dir + "/" + HA_STATE_FILE
}

///|
/// Read a directory's HA role marker. Returns (role, switched_at, from).
fn load_ha_state(dir : String) -> (String?, Int64, String?) {
  let path = ha_state_path(dir)
  let mut role : String? = None
  let mut at : Int64 = 0
  let mut from : String? = None
  if !@backend_native.file_exists(path) {
    return (role, at, from)
  }
  let data = @backend_native.read_file(path)
  let (lines, _) = split_complete_lines(data, true)
  for line in lines {
    for pair in @core.parse_kv_pairs(line) {
      if pair.0 == b"role" {
        role = Some(@utf8.decode_lossy(pair.1))
      } else if pair.0 == b"switched_at" {
        at = @string.parse_int64(@utf8.decode_lossy(pair.1)) catch {
          _ => (0 : Int64)
        }
      } else if pair.0 == b"switched_from" {
        from = Some(@utf8.decode_lossy(pair.1))
      }
    }
  }
  (role, at, from)
}

///|
fn save_ha_state(
  dir : String,
  role : String,
  from : String,
) -> Unit raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  @backend_native.write_file(
    ha_state_path(dir),
    @utf8.encode(
      "role=" +
      role +
      "\nswitched_at=" +
      now_ms().to_string() +
      "\nswitched_from=" +
      from +
      "\n",
    ),
  )
}

///|
fn replicate_pass(src : String, dst : String) -> Int32 raise @io.IoError {
  if !@backend_native.file_exists(src) {
    raise @io.IoError::Invalid("source unavailable: " + src)
  }
  // HA safety (3.5): a target promoted by ha-failover must never be trimmed by
  // a stale forward sync after the old primary returns — that would delete
  // writes made on the replica during the outage. Require an explicit
  // ha-rebalance / ha-failover role change instead.
  let (dst_role, _, _) = load_ha_state(dst)
  match dst_role {
    Some(r) =>
      if r == "primary" {
        raise @io.IoError::Invalid(
          "replicate target " +
          dst +
          " is promoted to primary; run ha-rebalance or ha-failover",
        )
      }
    None => ()
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

///|
/// Promote `replica` to primary after the primary becomes unreachable (3.5
/// automatic failover = this command driven by `ha-watch` or a supervisor).
/// The replica is marked `role=primary`; a reachable old primary is marked
/// `role=standby`, and a later stale `replicate old new` is refused by
/// replicate_pass so replica writes are never trimmed. `--active <link>`
/// atomically repoints the link at the replica, giving clients one stable
/// path across failover.
fn cmd_ha_failover(
  primary : String,
  replica : String,
  active : String?,
  json : Bool,
) -> Unit raise @io.IoError {
  if !@backend_native.file_exists(replica) {
    raise @io.IoError::Invalid("replica not found: " + replica)
  }
  save_ha_state(replica, "primary", primary)
  if @backend_native.file_exists(primary) {
    save_ha_state(primary, "standby", replica)
  }
  match active {
    Some(link) => @backend_native.replace_symlink(replica, link)
    None => ()
  }
  if json {
    println(
      "{\"failover\":true,\"primary\":\"" +
      json_escape_str(replica) +
      "\",\"from\":\"" +
      json_escape_str(primary) +
      "\",\"active\":" +
      (match active {
        Some(l) => "\"" + json_escape_str(l) + "\""
        None => "null"
      }) +
      "}",
    )
  } else {
    println("promoted " + replica + " to primary (from " + primary + ")")
    match active {
      Some(l) => println("active path now points at " + replica + " via " + l)
      None => ()
    }
  }
}

///|
fn cmd_ha_status(primary : String, replica : String, json : Bool) -> Unit {
  let p_exists = @backend_native.file_exists(primary)
  let r_exists = @backend_native.file_exists(replica)
  let (p_role, p_at, p_from) = load_ha_state(primary)
  let (r_role, r_at, r_from) = load_ha_state(replica)
  let pname = match p_role {
    Some(r) => r
    None => if p_exists { "primary" } else { "down" }
  }
  let rname = match r_role {
    Some(r) => r
    None => if r_exists { "replica" } else { "down" }
  }
  if json {
    println(
      "{\"primary\":{\"path\":\"" +
      json_escape_str(primary) +
      "\",\"exists\":" +
      (if p_exists { "true" } else { "false" }) +
      ",\"role\":\"" +
      json_escape_str(pname) +
      "\",\"switched_at\":" +
      p_at.to_string() +
      ",\"switched_from\":" +
      (match p_from {
        Some(f) => "\"" + json_escape_str(f) + "\""
        None => "null"
      }) +
      "},\"replica\":{\"path\":\"" +
      json_escape_str(replica) +
      "\",\"exists\":" +
      (if r_exists { "true" } else { "false" }) +
      ",\"role\":\"" +
      json_escape_str(rname) +
      "\",\"switched_at\":" +
      r_at.to_string() +
      ",\"switched_from\":" +
      (match r_from {
        Some(f) => "\"" + json_escape_str(f) + "\""
        None => "null"
      }) +
      "}}",
    )
  } else {
    println(
      "primary " +
      primary +
      " role=" +
      pname +
      " exists=" +
      (if p_exists { "yes" } else { "no" }),
    )
    println(
      "replica " +
      replica +
      " role=" +
      rname +
      " exists=" +
      (if r_exists { "yes" } else { "no" }),
    )
  }
}

///|
/// Rebalance after failover: mirror the promoted primary back onto the old
/// primary directory (single-writer: the new primary wins), then mark the old
/// directory as a standby so a later forward sync is still refused.
fn cmd_ha_rebalance(
  old_primary : String,
  new_primary : String,
  json : Bool,
) -> Unit raise @io.IoError {
  if !@backend_native.file_exists(new_primary) {
    raise @io.IoError::Invalid("new primary not found: " + new_primary)
  }
  // Mark the old directory as a standby first so replicate_pass accepts it as
  // a target even if it carried a stale primary marker.
  save_ha_state(old_primary, "standby", new_primary)
  let n = replicate_pass(new_primary, old_primary)
  if json {
    println(
      "{\"rebalanced\":true,\"target\":\"" +
      json_escape_str(old_primary) +
      "\",\"from\":\"" +
      json_escape_str(new_primary) +
      "\",\"segments\":" +
      n.to_string() +
      "}",
    )
  } else {
    println(
      "rebalanced " +
      old_primary +
      " from " +
      new_primary +
      " (" +
      n.to_string() +
      " segment(s))",
    )
    println("old primary is now a standby; new primary remains authoritative")
  }
}

///|
/// Watch the primary and promote the replica when the primary directory has
/// been unreachable for `fail_threshold` consecutive probes. Intended to run
/// under a supervisor; exits after a promotion so a restart cannot silently
/// re-promote.
fn cmd_ha_watch(
  primary : String,
  replica : String,
  active : String,
  interval : Int32,
  fail_threshold : Int32,
  json : Bool,
  once : Bool,
) -> Unit raise @io.IoError {
  let mut fails : Int32 = 0
  while true {
    if @backend_native.file_exists(primary) {
      fails = 0
    } else {
      fails = fails + 1
    }
    if fails >= fail_threshold {
      cmd_ha_failover(primary, replica, Some(active), json)
      println("ha-watch: primary unreachable, failover complete")
      return
    }
    if once {
      return
    }
    @backend_native.sleep_ms(interval)
  }
}

///|
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
/// ASCII-lowercase a level value so live filtering accepts the uppercase
/// spellings common in structured logs (`ERROR`, `Warn`) and stays
/// consistent with the case-insensitive schema comparisons.
fn follow_lower_ascii(s : Bytes) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  let mut i = 0
  while i < s.length() {
    let c = s.at(i).to_int()
    buf.write_byte((if c >= 65 && c <= 90 { c + 32 } else { c }).to_byte())
    i = i + 1
  }
  buf.to_bytes()
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
/// command returns (for scripts and tests). Live-debug filters (4.5) narrow
/// what is printed without changing the cursor: `--match <text>` keeps
/// records whose key or value contains the substring, `--level-min <level>`
/// keeps records with at least that severity rank (unknown levels are
/// excluded, same as query), `--service <svc>` keeps records whose key or
/// unified-schema service field matches (case-insensitive). Both field
/// filters understand JSON values (flattened like 2.1) as well as `k=v`
/// text, so SDK-appended structured logs tail correctly. The closing summary
/// reports fetched/filtered counts and the maximum observed live lag, and is
/// printed even when the tail is stopped by SIGTERM/SIGINT.
/// End-to-end latency is bounded by the poll interval (default 200ms,
/// `MOONLOG_FOLLOW_INTERVAL`); while records keep arriving the follower
/// re-polls immediately (1ms yield) instead of sleeping out the interval.
/// `--flush` makes every printed record hit stdout immediately (the C
/// runtime buffers pipes/files) so pipelines and redirect targets observe
/// records in real time.
fn cmd_follow(
  dir : String,
  start : String,
  once : Bool,
  commit : Bool,
  json : Bool,
  name : String?,
  match_text : String?,
  level_min : String?,
  service : String?,
  flush : Bool,
) -> Unit raise @io.IoError {
  let scope = active_scope(dir)
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
  // 4.5 live-debug filters: they narrow the printed stream only — skipped
  // records are consumed too, so `--commit` cursors keep advancing.
  let match_b : Bytes? = match match_text {
    Some(t) => Some(@utf8.encode(t))
    None => None
  }
  let service_b : Bytes? = match service {
    Some(sv) => Some(@utf8.encode(sv))
    None => None
  }
  let min_rank : Int32? = match level_min {
    Some(l) => {
      let r = @core.level_rank(@utf8.encode(l))
      if r < 0 {
        raise @io.IoError::Invalid("invalid level: " + l)
      }
      Some(r)
    }
    None => None
  }
  let interval = follow_interval_ms()
  // A long-running tail exits cooperatively on SIGTERM/SIGINT so the closing
  // summary survives the signal (production live tail).
  @backend_native.install_shutdown_handler()
  let mut fetched = 0
  let mut filtered = 0
  let mut max_lag : Int64 = -1
  let mut go = true
  while go && !@backend_native.shutdown_requested() {
    let lock = @backend_native.DirLock::acquire_timeout(
      dir,
      false,
      lock_timeout_ms(),
    )
    let log = open_log(dir)
    let next = log.next_offset()
    let had_new = next > from
    if had_new {
      let recs = log.scan_range(from, next)
      // One clock read per batch: live lag compares the event timestamp of
      // each record with the time the follower observed it.
      let observed_at = now_ms()
      for rec in recs {
        let mut keep = true
        match match_b {
          Some(nb) =>
            if !match_needle(rec.key, nb, false) &&
              !match_needle(rec.value, nb, false) {
              keep = false
            }
          None => ()
        }
        if keep {
          // Structured values (JSON lines / nested JSON from 2.1, flat or
          // dotted) are flattened so live filters read the same unified
          // schema fields as query (2.2): `--level-min` accepts level aliases
          // (severity/lvl/...) and `--service` matches the record key or the
          // service field, case-insensitively.
          let needs_fields = match service_b {
            Some(_) => true
            None =>
              match min_rank {
                Some(_) => true
                None => false
              }
          }
          if needs_fields {
            let sf = @core.schema_from_fields(
              ctx_value_fields(rec.value),
              (0 : Int64),
            )
            match service_b {
              Some(sb) => {
                let mut sm = ctx_bytes_eq_ci(rec.key, sb)
                if !sm {
                  sm = match sf.service {
                    Some(sv) => ctx_bytes_eq_ci(sv, sb)
                    None => false
                  }
                }
                if !sm {
                  keep = false
                }
              }
              None => ()
            }
            if keep {
              match min_rank {
                Some(r) => {
                  let lr = match sf.level {
                    Some(l) => @core.level_rank(follow_lower_ascii(l))
                    None => -1
                  }
                  // A level filter requires a known level (same as query).
                  if lr < 0 || lr < r {
                    keep = false
                  }
                }
                None => ()
              }
            }
          }
        }
        if keep && !scope_allows_key(scope, rec.key) {
          keep = false
        }
        if keep {
          if json {
            print_json_record(rec)
          } else {
            print_record(rec)
          }
          if flush {
            @backend_native.flush_stdout()
          }
          let lag = observed_at - rec.timestamp
          if lag >= 0 && lag > max_lag {
            max_lag = lag
          }
          fetched = fetched + 1
        } else {
          filtered = filtered + 1
        }
      }
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
    } else if had_new {
      // Records were available: poll again immediately (a 1ms yield keeps a
      // fast writer from starving the follower) instead of waiting out the
      // full interval. Idle rounds keep the configurable interval.
      @backend_native.sleep_ms(1)
    } else {
      @backend_native.sleep_ms(interval)
    }
  }
  let lag_text = if max_lag >= 0 { max_lag.to_string() + "ms" } else { "n/a" }
  println(
    "(" +
    fetched.to_string() +
    " records, cursor " +
    from.to_string() +
    "; " +
    filtered.to_string() +
    " filtered, max lag " +
    lag_text +
    ")",
  )
  if flush {
    @backend_native.flush_stdout()
  }
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
  let dedup = match opts.dedup_field_bytes {
    Some(_) => Some(load_dedup(dir))
    None => None
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
      let (written, sampled, dup) = ingest_lines(dir, lines, opts, dedup, false)
      duplicates = duplicates + dup
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
/// Per-record clock-skew offset from a parsed field (milliseconds), layered
/// on top of the global `--clock-skew`. A missing/unparsable value
/// contributes 0, so mixed sources without the field keep the global
/// behavior.
fn ingest_clock_skew(
  fields : Array[(Bytes, Bytes)],
  opts : IngestOptions,
) -> Int64 {
  match opts.clock_skew_field_bytes {
    Some(name) => {
      let mut out : Int64 = 0
      for pair in fields {
        if pair.0 == name {
          out = @string.parse_int64(@utf8.decode_lossy(pair.1)) catch {
            _ => (0 : Int64)
          }
        }
      }
      out
    }
    None => (0 : Int64)
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

///|
/// Sidecar cache of unique record IDs seen by the dedup path. The log remains
/// authoritative: every deduped record carries its ID in the value, so a tail
/// missed by a crash is rebuilt from the log on the next load.
const DEDUP_FILE : String = "DEDUP"

///|
/// Whether `uid` can be stored one-per-line in the sidecar.
fn dedup_uid_ok(uid : Bytes) -> Bool {
  if uid.length() == 0 {
    return false
  }
  let mut i = 0
  while i < uid.length() {
    let c = uid.at(i).to_int()
    if c == 9 || c == 10 || c == 13 {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Pick the explicit unique ID for a parsed line (`--dedup-field`).
fn dedup_uid_from_fields(
  fields : Array[(Bytes, Bytes)],
  opts : IngestOptions,
) -> Bytes? {
  match opts.dedup_field_bytes {
    None => None
    Some(name) => {
      let mut found : Bytes? = None
      for pair in fields {
        if pair.0 == name {
          found = Some(pair.1)
        }
      }
      found
    }
  }
}

///|
/// The ID embedded in a value by the dedup path, or None. The last marker wins
/// so a user value containing `__uid=` cannot shadow ours.
fn dedup_uid_of_value(value : Bytes) -> Bytes? {
  let needle = b"__uid="
  let mut start = -1
  let mut i = 0
  while i + needle.length() <= value.length() {
    let mut same = true
    let mut k = 0
    while k < needle.length() {
      if value.at(i + k) != needle.at(k) {
        same = false
        break
      }
      k = k + 1
    }
    if same {
      start = i + needle.length()
    }
    i = i + 1
  }
  if start < 0 {
    None
  } else {
    Some(@core.slice(value, start, value.length()))
  }
}

///|
/// Append `__uid=<id>` to the value so the dedup set can be rebuilt from the
/// log itself (the sidecar is only a cache).
fn dedup_attach_uid(value : Bytes, uid : Bytes) -> Bytes {
  let marker = b"__uid=" + uid
  if value.length() == 0 {
    marker
  } else {
    value + b" " + marker
  }
}

///|
/// Append `<offset>\t<uid>\n` rows to the sidecar in one fsynced write.
fn dedup_append_entries(
  dir : String,
  entries : Array[(UInt64, Bytes)],
) -> Unit raise @io.IoError {
  if entries.length() == 0 {
    return
  }
  let buf = @buffer.Buffer::Buffer()
  for entry in entries {
    buf.write_bytes(@utf8.encode(entry.0.to_string()))
    buf.write_byte((9 : Int32).to_byte())
    buf.write_bytes(entry.1)
    buf.write_byte((10 : Int32).to_byte())
  }
  @backend_native.append_file(dir + "/" + DEDUP_FILE, buf.to_bytes())
}

///|
/// Load the dedup set for `dir` while holding the directory lock: read the
/// sidecar, then rebuild any tail it missed (records are appended before the
/// sidecar, so a crash can leave it behind).
fn load_dedup_locked(
  dir : String,
  log : CliLog,
) -> @hashmap.HashMap[Bytes, Bool] raise @io.IoError {
  let seen : @hashmap.HashMap[Bytes, Bool] = @hashmap.HashMap::HashMap([])
  let path = dir + "/" + DEDUP_FILE
  let mut scan_from : UInt64 = (0 : UInt64)
  let mut have_sidecar = false
  if @backend_native.file_exists(path) {
    let data = @backend_native.read_file(path)
    let (rows, _) = split_complete_lines(data, true)
    for row in rows {
      let mut tab = -1
      let mut i = 0
      while i < row.length() {
        if row.at(i).to_int() == 9 {
          tab = i
          break
        }
        i = i + 1
      }
      if tab > 0 {
        let off_s = @utf8.decode(@core.slice(row, 0, tab)) catch { _ => "0" }
        let off = @string.parse_int64(off_s) catch { _ => (0 : Int64) }
        let uid = @core.slice(row, tab + 1, row.length())
        seen.set(uid, true)
        let o = off.reinterpret_as_uint64()
        if !have_sidecar || o >= scan_from {
          scan_from = o + (1 : UInt64)
          have_sidecar = true
        }
      }
    }
  }
  let pending : Array[(UInt64, Bytes)] = []
  log.for_each_while(scan_from, log.next_offset(), rec => {
    match dedup_uid_of_value(rec.value) {
      Some(uid) =>
        if !seen.contains(uid) {
          seen.set(uid, true)
          pending.push((rec.offset, uid))
        }
      None => ()
    }
    true
  })
  dedup_append_entries(dir, pending)
  seen
}

///|
/// Load the dedup set in its own write transaction (for command entry points).
fn load_dedup(dir : String) -> @hashmap.HashMap[Bytes, Bool] raise @io.IoError {
  run_locked(dir, true, () => {
    let log = open_log(dir)
    let seen = load_dedup_locked(dir, log)
    close_log(log)
    seen
  })
}

///|
fn ingest_lines(
  dir : String,
  lines : Array[Bytes],
  opts : IngestOptions,
  dedup : @hashmap.HashMap[Bytes, Bool]?,
  skip_sampling : Bool,
) -> (Int32, Int32, Int32) raise @io.IoError {
  let ts_base = now_ms()
  let mut written = 0
  let mut sampled_out = 0
  let mut duplicates = 0
  let scope = active_scope(dir)
  let mut i = 0
  // One lock hold and one metadata write per window of up to 16 batches:
  // each metadata flush is an atomic MANIFEST/sidecar update with several
  // fsyncs, so writing it per 256-line chunk made bulk ingest and HTTP
  // backlog drain fsync-bound (measured ~0.4s per chunk on overlay).
  // Long streams still release the directory lock between windows.
  let window = if opts.batch_n > 65536 {
    opts.batch_n
  } else {
    opts.batch_n * 16
  }
  while i < lines.length() {
    let remaining = lines.length() - i
    let window_end = if window < remaining {
      i + window
    } else {
      lines.length()
    }
    let mut window_written = 0
    let mut window_sampled = 0
    let mut window_duplicates = 0
    let mut window_bytes : Int64 = 0
    let window_dedup : Array[(UInt64, Bytes)] = []
    run_locked(dir, true, () => {
      // 6.2 write/storage quota: the pre-check runs inside the directory lock
      // (the persisted usage file must not race concurrent writers); the
      // budget is recorded with the actually written bytes after the batch
      // lands. HTTP drain passes skip_quota and was accounted on accept.
      let rule = if opts.skip_quota { None } else { active_quota_rule(dir) }
      let mut pre_bytes : Int64 = 0
      let mut j2 = i
      while j2 < window_end {
        pre_bytes = pre_bytes + lines[j2].length().to_int64()
        j2 = j2 + 1
      }
      match quota_write_error(dir, rule, pre_bytes) {
        Some(msg) => raise @io.IoError::Invalid(msg)
        None => ()
      }
      let log = open_log_sync(dir, opts.partition_ms, opts.sync)
      let mut j = i
      while j < window_end {
        // Keep the --batch durability boundary (fsync per batch) while the
        // log itself is opened once per window.
        let chunk_end = if j + opts.batch_n < window_end {
          j + opts.batch_n
        } else {
          window_end
        }
        while j < chunk_end {
          let (raw_k, raw_v, fields) = parse_ingest_line(lines[j], opts)
          let (k, v, schema_ts) = if opts.schema {
            schema_transform(raw_k, raw_v, fields, ts_base + j.to_int64())
          } else {
            (raw_k, raw_v, None)
          }
          if !scope_allows_key(scope, k) {
            record_scope_denied(dir, "ingest", k)
            raise @io.IoError::Invalid(
              "permission denied: key '" +
              bytes_to_string(k) +
              "' is outside the role's data scope",
            )
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
          let keep = if skip_sampling {
            true
          } else {
            match opts.sampling {
              Some(cfg) => @core.sampling_allows(lines[j], fields, cfg)
              None => true
            }
          }
          let uid = match dedup {
            Some(_) =>
              match dedup_uid_from_fields(fields, opts) {
                Some(u) =>
                  if dedup_uid_ok(u) {
                    Some(u)
                  } else {
                    raise @io.IoError::Invalid(
                      "dedup id contains a tab/newline: " +
                      (@utf8.decode(u) catch { _ => "" }),
                    )
                  }
                None => None
              }
            None => None
          }
          let duplicate = match (dedup, uid) {
            (Some(seen), Some(u)) => seen.contains(u)
            _ => false
          }
          if !keep {
            window_sampled = window_sampled + 1
          } else if duplicate {
            window_duplicates = window_duplicates + 1
          } else {
            let v = match uid {
              Some(u) => dedup_attach_uid(v, u)
              None => v
            }
            let raw_ts = match schema_ts {
              Some(t) => t
              None => ingest_timestamp(fields, opts, ts_base + j.to_int64())
            }
            // 2.3 clock-skew correction: a fixed offset (ms) applied to every
            // record timestamp, compensating a slow/fast source clock.
            let rec_ts = raw_ts +
              opts.clock_skew_ms +
              ingest_clock_skew(fields, opts)
            let mut wrote = false
            let mut off : UInt64 = (0 : UInt64)
            if opts.idempotent {
              let (added, existing) = log.append_idempotent(k, v, rec_ts)
              if added {
                wrote = true
                off = existing
              } else {
                window_duplicates = window_duplicates + 1
              }
            } else {
              off = log.append(k, v, rec_ts)
              wrote = true
            }
            if wrote {
              window_written = window_written + 1
              window_bytes = window_bytes + (k.length() + v.length()).to_int64()
              match (dedup, uid) {
                (Some(seen), Some(u)) => {
                  seen.set(u, true)
                  window_dedup.push((off, u))
                }
                _ => ()
              }
            }
          }
          j = j + 1
        }
        log.flush()
      }
      @backend_native.flush_meta(dir, log)
      close_log(log)
      dedup_append_entries(dir, window_dedup)
      quota_record_write(dir, rule, window_bytes)
    })
    written = written + window_written
    sampled_out = sampled_out + window_sampled
    duplicates = duplicates + window_duplicates
    i = window_end
  }
  (written, sampled_out, duplicates)
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
/// SIGTERM/SIGINT is handled cooperatively: the blocking open/read is
/// interrupted (EINTR), the loop notices the shutdown flag, flushes what has
/// already been written and exits cleanly instead of dying by signal.
fn cmd_ingest_fifo(
  dir : String,
  path : String,
  opts : IngestOptions,
) -> Unit raise @io.IoError {
  @backend_native.install_shutdown_handler()
  let dedup = match opts.dedup_field_bytes {
    Some(_) => Some(load_dedup(dir))
    None => None
  }
  let mut total = 0
  let mut sampled = 0
  let mut duplicates = 0
  while !@backend_native.shutdown_requested() {
    let fd = @backend_native.open_read_blocking(path)
    if fd < 0 {
      if @backend_native.shutdown_requested() {
        break
      }
      raise @io.IoError::Syscall(fd)
    }
    let mut leftover = b""
    let mut eof = false
    while !eof && !@backend_native.shutdown_requested() {
      let chunk = @backend_native.read_blocking(fd, 4096)
      if chunk.length() == 0 {
        // EOF (writer closed) or an interrupted read; a pending shutdown
        // leaves the loop and closes the descriptor below.
        eof = true
      } else {
        let data = leftover + chunk
        let (lines, consumed) = split_complete_lines(data, false)
        leftover = @core.slice(data, consumed.to_int(), data.length())
        if lines.length() > 0 {
          let (written, dropped, dup) = ingest_lines(
            dir, lines, opts, dedup, false,
          )
          total = total + written
          sampled = sampled + dropped
          duplicates = duplicates + dup
        }
      }
    }
    @backend_native.close_fd(fd)
    if @backend_native.shutdown_requested() {
      break
    }
    println("ingested " + total.to_string() + " records (fifo " + path + ")")
  }
  println(
    "moonlog fifo shut down (" +
    total.to_string() +
    " written / " +
    sampled.to_string() +
    " sampled out / " +
    duplicates.to_string() +
    " duplicates, " +
    path +
    ")",
  )
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
  // Backlog alert state machine: alert once when the backlog crosses the
  // threshold and resolve once when it drains, instead of printing on every
  // drain batch (a sustained backlog used to emit one WARN per 256 lines).
  mut backlog_active : Bool
  mut backlog_since : Int64
  mut peak_pending : Int32
  // Explicit backpressure counters: requests/lines rejected with 429 because
  // the queue or its byte budget was full (client retries, nothing dropped).
  mut rejected_requests : Int64
  mut rejected_lines : Int64
  // Optional byte budget in addition to the line capacity (0 = unlimited),
  // so many large lines cannot evict the memory the line count allows.
  capacity_bytes : Int64
  mut pending_bytes : Int64
  // End-to-end counters for the push path: lines accepted into the queue,
  // lines actually written by the drain, and lines dropped by the sampler.
  // accepted - written - sampled is the in-flight/duplicate remainder.
  mut accepted : Int64
  mut written : Int64
  mut sampled : Int64
  mut duplicates : Int64
  // Unique-ID dedup set (built once at startup when --dedup-field is set);
  // the drain skips records whose ID was already written.
  dedup : @hashmap.HashMap[Bytes, Bool]?
  opts : IngestOptions
  // 6.2 per-tenant write/storage quota policy, loaded once at startup.
  quota_rules : Array[@core.QuotaRule]
  // 6.4 self-monitoring: the enqueue time of the queue-head line (how long
  // the oldest buffered lines have waited) and the last snapshot report ts.
  mut head_ts : Int64
  mut last_report : Int64
}

///|
/// Offer `lines` to the queue; false when they would exceed the capacity.
fn http_queue_enqueue(
  q : HttpQueue,
  lines : Array[Bytes],
  bytes : Int64,
) -> Bool {
  if q.pending + lines.length() > q.capacity {
    return false
  }
  if q.capacity_bytes > (0 : Int64) &&
    q.pending_bytes + bytes > q.capacity_bytes {
    return false
  }
  if q.pending == 0 {
    // The queue just emptied (or starts): the head's enqueue time anchors
    // the oldest-line lag reported to self-monitoring (6.4).
    q.head_ts = now_ms()
  }
  for line in lines {
    q.lines.push(line)
  }
  q.pending = q.pending + lines.length()
  q.pending_bytes = q.pending_bytes + bytes
  if q.pending > q.peak_pending {
    q.peak_pending = q.pending
  }
  true
}

///|
/// 6.4 self-monitoring snapshot: atomically persist the writer's in-flight
/// state to `<dir>/SELFMON/http.json` so the independent `selfmon` command
/// can observe backlog and head lag without the writer process being
/// introspectable. Failures are swallowed — monitoring must not break the
/// writer.
fn selfmon_report_http(dir : String, q : HttpQueue) -> Unit {
  ignore(@backend_native.ensure_dir(dir + "/SELFMON"))
  let now = now_ms()
  let lag = if q.head_ts > 0 { now - q.head_ts } else { 0 }
  let line = "{\"ts\":" +
    now.to_string() +
    ",\"writer\":\"http\",\"pending\":" +
    q.pending.to_string() +
    ",\"head_lag_ms\":" +
    lag.to_string() +
    ",\"backlog_alerts\":" +
    q.alerts.to_string() +
    ",\"pending_peak\":" +
    q.peak_pending.to_string() +
    ",\"rejected_lines\":" +
    q.rejected_lines.to_string() +
    "}"
  ignore(
    @backend_native.write_file(dir + "/SELFMON/http.json", @utf8.encode(line)) catch {
      _ => ()
    },
  )
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
  let mut freed_bytes : Int64 = 0
  while i < take {
    let line = q.lines[q.head + i]
    chunk.push(line)
    freed_bytes = freed_bytes + line.length().to_int64()
    i = i + 1
  }
  q.head = q.head + take
  q.pending = q.pending - take
  q.pending_bytes = q.pending_bytes - freed_bytes
  let (batch_written, _, batch_dup) = ingest_lines(
    dir,
    chunk,
    q.opts,
    q.dedup,
    true,
  )
  q.written = q.written + batch_written.to_int64()
  q.duplicates = q.duplicates + batch_dup.to_int64()
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
  // Alert on crossing the threshold, resolve when the backlog drains: one
  // WARN/RESOLVED pair per backlog episode instead of one WARN per batch.
  if !q.backlog_active && q.pending > q.alert_threshold {
    q.backlog_active = true
    q.backlog_since = now_ms()
    q.alerts = q.alerts + 1
    println(
      "WARN backlog " +
      q.pending.to_string() +
      " lines (threshold " +
      q.alert_threshold.to_string() +
      "), peak " +
      q.peak_pending.to_string(),
    )
  } else if q.backlog_active && q.pending <= q.alert_threshold {
    q.backlog_active = false
    println(
      "RESOLVED backlog drained to " +
      q.pending.to_string() +
      " lines after " +
      (now_ms() - q.backlog_since).to_string() +
      " ms (peak " +
      q.peak_pending.to_string() +
      ")",
    )
  }
  // 6.4: report the writer snapshot at most once a second so the
  // independent selfmon command sees backlog without adding per-batch
  // fsync cost.
  if now_ms() - q.last_report >= 1000 {
    q.last_report = now_ms()
    selfmon_report_http(dir, q)
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
  // Bound a stalled client: without this a slowloris-style partial request
  // blocks the serial accept loop (and the queue drain with it). The per-read
  // timeout stops a silent peer; the wall-clock deadline also stops one that
  // keeps dribbling bytes forever.
  @backend_native.conn_set_timeouts(conn, 5000, 5000)
  let deadline = now_ms() + 10000
  let mut head = b""
  let mut header_end = -1
  let mut rounds = 0
  while header_end < 0 && rounds < 16 && now_ms() < deadline {
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
  while body.length() < request.content_length &&
        body.length() < 1_048_576 &&
        now_ms() < deadline {
    // Keep writing buffered lines while the body streams in, so a large
    // upload does not starve the disk writer.
    http_queue_drain(q, dir)
    let chunk = @backend_native.conn_read(conn, 4096)
    if chunk.length() == 0 {
      break
    }
    body = body + chunk
  }
  // A short body means the client stalled (recv timeout) or disconnected:
  // reject instead of persisting a truncated line.
  if body.length() < request.content_length {
    http_respond(conn, 400, "{\"error\":\"truncated or oversized body\"}")
    return
  }
  let is_get = request.verb == b"GET"
  let is_post = request.verb == b"POST"
  if is_get && request.path == b"/health" {
    http_respond(conn, 200, "{\"status\":\"ok\"}")
  } else if is_get && request.path == b"/stats" {
    // 6.2: with RBAC in force, stats are tenant-visible only with a valid
    // token (they expose store counters); open-local mode stays open.
    let has_rbac = @backend_native.file_exists(dir + "/RBAC")
    if has_rbac {
      let auth = @core.rbac_find(
        load_rbac_rules(dir),
        http_bearer_token(request.authorization),
      )
      if auth is None {
        http_respond(
          conn, 401, "{\"error\":\"missing or invalid bearer token\"}",
        )
        return
      }
      match auth {
        Some(r) =>
          match r.scope {
            Some(_) => {
              http_respond(
                conn, 403, "{\"error\":\"stats require an unscoped role\"}",
              )
              return
            }
            None => ()
          }
        None => ()
      }
    }
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
        ",\"accepted\":" +
        q.accepted.to_string() +
        ",\"written\":" +
        q.written.to_string() +
        ",\"sampled_out\":" +
        q.sampled.to_string() +
        ",\"duplicates\":" +
        q.duplicates.to_string() +
        ",\"backlog_alerts\":" +
        q.alerts.to_string() +
        ",\"pending_peak\":" +
        q.peak_pending.to_string() +
        ",\"pending_bytes\":" +
        q.pending_bytes.to_string() +
        ",\"rejected_requests\":" +
        q.rejected_requests.to_string() +
        ",\"rejected_lines\":" +
        q.rejected_lines.to_string() +
        "}"
      http_respond(conn, 200, payload)
      close_log(log)
    })
  } else if is_post && (request.path == b"/" || request.path == b"/push") {
    // 6.2: pushes are attributed to a tenant. With RBAC in force a valid
    // `Authorization: Bearer <token>` is mandatory and the role must carry
    // the `put` permission; open-local mode stays anonymous and is governed
    // by the `default` quota rule.
    let has_rbac = @backend_native.file_exists(dir + "/RBAC")
    let auth : @core.RbacRole? = if has_rbac {
      @core.rbac_find(
        load_rbac_rules(dir),
        http_bearer_token(request.authorization),
      )
    } else {
      None
    }
    let authed = match auth {
      Some(_) => true
      None => !has_rbac
    }
    if !authed {
      http_respond(conn, 401, "{\"error\":\"missing or invalid bearer token\"}")
      return
    }
    if has_rbac {
      match auth {
        Some(r) =>
          if !@core.rbac_allows(r, b"put") {
            http_respond(conn, 403, "{\"error\":\"role not allowed to write\"}")
            return
          }
        None => ()
      }
    }
    let role_name : Bytes = match auth {
      Some(r) => r.name
      None => b""
    }
    let (lines, _) = split_complete_lines(body, true)
    if lines.length() > 10000 {
      http_respond(conn, 400, "{\"error\":\"too many lines\"}")
      return
    }
    // 6.1 index isolation: reject the whole request when any line falls
    // outside the token role's data scope (the 202 contract stays intact).
    match auth {
      Some(r) =>
        match r.scope {
          Some(prefix) => {
            let mut denied : Bytes? = None
            for line in lines {
              let (k, _, _) = parse_ingest_line(line, q.opts)
              if !scope_allows_key(Some(prefix), k) {
                denied = Some(k)
                break
              }
            }
            match denied {
              Some(k) => {
                audit_log(
                  dir,
                  bytes_to_string(r.name),
                  "http",
                  "deny",
                  "scope:" + bytes_to_string(k),
                )
                http_respond(
                  conn, 403, "{\"error\":\"key outside role scope\"}",
                )
                return
              }
              None => ()
            }
          }
          None => ()
        }
      None => ()
    }
    // Source-side sampling runs before the queue, so the capacity below counts
    // only lines that will actually be written.
    let (kept, sampled_out) = sampling_filter_lines(lines, q.opts)
    // 6.2 write/storage quota: pre-checked per request against the tenant's
    // rule and recorded when accepted (202), so a spent budget survives
    // restarts and a 202 always promises space under the storage share. The
    // drain path skips accounting (skip_quota).
    if kept.length() > 0 {
      let mut incoming : Int64 = 0
      for line in kept {
        incoming = incoming + line.length().to_int64()
      }
      let rule = @core.quota_for_role(q.quota_rules, role_name)
      match quota_write_error(dir, rule, incoming) {
        Some(_) => {
          // Not admitted, nothing buffered or accounted; the client can
          // retry after the window resets or the quota is raised.
          http_respond(
            conn, 429, "{\"error\":\"tenant write quota exceeded\",\"retry_after_ms\":1000}",
          )
          return
        }
        None => ()
      }
      if http_queue_enqueue(q, kept, incoming) {
        quota_record_write(dir, rule, incoming)
        q.accepted = q.accepted + kept.length().to_int64()
        q.sampled = q.sampled + sampled_out.to_int64()
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
        // Explicit backpressure: the request was not buffered, so the client
        // can retry the same payload — nothing is dropped silently.
        q.rejected_requests = q.rejected_requests + (1 : Int64)
        q.rejected_lines = q.rejected_lines + kept.length().to_int64()
        http_respond(
          conn,
          429,
          "{\"error\":\"backlog full\",\"pending\":" +
          q.pending.to_string() +
          ",\"retry_after_ms\":1000}",
        )
      }
    } else {
      q.sampled = q.sampled + sampled_out.to_int64()
      http_respond(
        conn,
        202,
        "{\"accepted\":0,\"sampled_out\":" +
        sampled_out.to_string() +
        ",\"pending\":" +
        q.pending.to_string() +
        "}",
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
  queue_bytes : String?,
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
  let queue_bytes_n : Int64 = match queue_bytes {
    Some(s) =>
      @string.parse_int64(s) catch {
        _ => raise @io.IoError::Invalid("invalid queue bytes: " + s)
      }
    None => (0 : Int64)
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
  if queue_cap_n <= 0 ||
    batch_n <= 0 ||
    backlog_alert_n < 0 ||
    queue_bytes_n < (0 : Int64) {
    raise @io.IoError::Invalid(
      "queue and batch must be positive, backlog alert and queue bytes non-negative",
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
    (if queue_bytes_n > (0 : Int64) {
      ", byte budget " + queue_bytes_n.to_string()
    } else {
      ""
    }) +
    ", backlog alert " +
    backlog_alert_n.to_string() +
    ")",
  )
  let dedup = match opts.dedup_field_bytes {
    Some(_) => Some(load_dedup(dir))
    None => None
  }
  let q : HttpQueue = {
    lines: [],
    head: 0,
    pending: 0,
    capacity: queue_cap_n,
    batch: batch_n,
    alert_threshold: backlog_alert_n,
    alerts: 0,
    backlog_active: false,
    backlog_since: 0,
    peak_pending: 0,
    rejected_requests: 0,
    rejected_lines: 0,
    capacity_bytes: queue_bytes_n,
    pending_bytes: 0,
    accepted: 0,
    written: 0,
    sampled: 0,
    duplicates: 0,
    dedup,
    opts,
    quota_rules: load_quota_rules(dir),
    head_ts: 0,
    last_report: 0,
  }
  @backend_native.install_shutdown_handler()
  let mut stopping = false
  while !stopping {
    // Drain at full speed while a backlog exists. Draining a single batch and
    // then waiting up to 200ms on accept caps recovery at batch/200ms (~1.3k
    // lines/s), so a burst would linger for seconds. Bound each round to one
    // full queue worth of batches so accept (and /health) is not starved.
    let drain_limit = q.capacity / q.batch + 1
    let mut drained = 0
    while q.pending > 0 && drained < drain_limit {
      http_queue_drain(q, dir)
      drained = drained + 1
    }
    stopping = @backend_native.shutdown_requested()
    if !stopping {
      let conn = @backend_native.tcp_accept_timeout(listen_fd, 200)
      if conn >= 0 {
        handle_http_connection(dir, conn, q)
        @backend_native.conn_close_graceful(conn)
      }
    }
  }
  // Graceful shutdown: write every buffered line before exiting, so nothing
  // accepted with 202 is lost.
  while q.pending > 0 {
    http_queue_drain(q, dir)
  }
  // 6.4: final snapshot so selfmon sees the drained (pending=0) terminal
  // state instead of a stale pre-shutdown backlog.
  selfmon_report_http(dir, q)
  println(
    "moonlog http shut down (backlog drained, " +
    q.accepted.to_string() +
    " accepted / " +
    q.written.to_string() +
    " written / " +
    q.sampled.to_string() +
    " sampled out / " +
    q.duplicates.to_string() +
    " duplicates, peak " +
    q.peak_pending.to_string() +
    " lines, " +
    q.rejected_requests.to_string() +
    " rejected / " +
    q.rejected_lines.to_string() +
    " lines, " +
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
/// case; `--limit` stops early; `--from`/`--to` bound the offset range;
/// `--wildcard` switches the linear path to wildcard semantics: `*` matches
/// any byte sequence, `?` exactly one byte (byte-level — CJK patterns work
/// with one `?` per UTF-8 byte); mutually exclusive with `--inverted`.
/// Query protection (4.6): search takes the same concurrency slot, timeout
/// and scan budget as `query` (segment-level checks plus every-512-record
/// sampling; `--timeout <ms>` overrides the env default), and stops at
/// `MOONLOG_MAX_RESULTS` (default 1000) when `--limit` is absent — the
/// summary says when the cap stopped the scan, and `--limit -1` removes it.
fn cmd_search(
  dir : String,
  text : String,
  field : String,
  ignore_case : Bool,
  limit : String?,
  from : String?,
  to : String?,
  inverted : Bool,
  wildcard : Bool,
  since : String?,
  until : String?,
  require_time : Bool,
  timeout : String?,
) -> Unit raise @io.IoError {
  let scope = active_scope(dir)
  if inverted && wildcard {
    raise @io.IoError::Invalid(
      "--wildcard and --inverted are mutually exclusive",
    )
  }
  if field != "both" && field != "key" && field != "value" {
    raise @io.IoError::Invalid("invalid field: " + field + " (both|key|value)")
  }
  // Forced time range (4.3): searches without an explicit --since are scoped
  // to the default window unless --since 0 is given; --require-time rejects
  // unbounded scans outright. `--from/--to` remain offset bounds.
  let mut since_ts : Int64? = match since {
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
  match since_ts {
    Some(_) => ()
    None =>
      if require_time {
        raise @io.IoError::Invalid(
          "search requires --since (unbounded scans are disabled by --require-time); pass --since 0 to scan everything explicitly",
        )
      } else {
        let win = query_window_ms()
        println(
          "INFO search scoped to the last " +
          (win / (1000 : Int64)).to_string() +
          "s (default window; pass --since to override, --since 0 for everything)",
        )
        since_ts = Some(now_ms() - win)
      }
  }
  let needle = @utf8.encode(text)
  // Phrase (spaces) and non-ASCII (CJK) queries need substring refinement:
  // the term index ANDs tokens, which does not imply adjacency or order, and
  // CJK unigram tokens only narrow candidates. Refine candidates by the
  // original substring (same semantics as the linear path) and fall back to a
  // linear scan when the index yields no candidates (e.g. an old sidecar).
  let mut refine = false
  let mut ri = 0
  while ri < needle.length() {
    let c = needle.at(ri).to_int()
    if c == 32 || c >= 128 {
      refine = true
    }
    ri = ri + 1
  }
  let max_hits = match limit {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid limit: " + s)
      }
    None => default_max_results()
  }
  // 4.6 query protection: search is a retrieval entry point too, so it takes
  // the same concurrency slot, timeout and scan budget as `query`. Without
  // this, a large `search` (linear or inverted) bypasses every guard.
  acquire_query_slot(dir)
  acquire_tenant_query_quota(dir)
  let timeout_val : Int64 = match timeout {
    Some(t) =>
      @string.parse_int64(t) catch {
        _ => raise @io.IoError::Invalid("invalid timeout: " + t)
      }
    None => query_timeout_ms()
  }
  let qg : QueryGuard = {
    t0: now_ms(),
    timeout: timeout_val,
    budget: max_scan_bytes(),
    scanned: 0,
    segs: 0,
  }
  if inverted && !refine {
    let toks = @segment.tokenize(@utf8.encode(text), 16)
    run_read_snapshot(dir, log => {
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
      let mut truncated = false
      let mut abort_msg : String? = None
      for seg in log.segments {
        if stop {
          break
        }
        if abort_msg is Some(_) {
          break
        }
        qg.check(seg.size)
        seg.ensure_inv_index()
        if !@backend_native.has_segment_inv(dir, seg.base_offset) {
          match seg.inv_index {
            Some(ix) =>
              @backend_native.save_segment_inv(
                dir,
                seg.base_offset,
                ix.encode(),
              )
            None => ()
          }
        }
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
        let mut seen_cands = 0
        for off in cands {
          seen_cands = seen_cands + 1
          if seen_cands % 512 == 0 {
            match qg.check_soft(0) {
              Some(m) => abort_msg = Some(m)
              None => ()
            }
          }
          if abort_msg is Some(_) {
            break
          }
          if max_hits >= 0 && hits >= max_hits {
            truncated = true
            stop = true
            break
          }
          let rec = log.get(off) catch { _ => None }
          match rec {
            Some(r) => {
              let mut in_time = true
              match since_ts {
                Some(t) => if r.timestamp < t { in_time = false }
                None => ()
              }
              match until_ts {
                Some(t) => if r.timestamp > t { in_time = false }
                None => ()
              }
              if in_time && scope_allows_key(scope, r.key) {
                print_record(r)
                hits = hits + 1
              }
            }
            None => ()
          }
        }
      }
      match abort_msg {
        Some(m) => raise @io.IoError::Invalid(m)
        None => ()
      }
      println(matches_summary(hits, truncated, max_hits) + " (inverted)")
    })
    return
  }
  run_read_snapshot(dir, log => {
    let lo = match from {
      Some(s) => parse_offset(s)
      None => (0 : UInt64)
    }
    let hi = match to {
      Some(s) => parse_offset(s)
      None => log.next_offset()
    }
    let mut hits = 0
    let mut truncated = false
    let mut seen = 0
    let mut abort_msg : String? = None
    // Segment-level scan budget: account the [lo, hi) segments before the
    // stream starts, so an oversized query is rejected before doing work.
    for seg in log.segments {
      if seg.next_offset <= lo || seg.base_offset >= hi {
        continue
      }
      qg.check(seg.size)
    }
    log.for_each_while(lo, hi, rec => {
      seen = seen + 1
      // Record-granularity timeout sampling (4.6): segment-level checks alone
      // miss a runaway scan inside one huge segment.
      if seen % 512 == 0 {
        match qg.check_soft(0) {
          Some(m) => abort_msg = Some(m)
          None => ()
        }
      }
      if abort_msg is Some(_) {
        return false
      }
      if !scope_allows_key(scope, rec.key) {
        return true
      }
      let hit = if wildcard {
        if field == "key" {
          @core.wildcard_contains(rec.key, needle, ignore_case)
        } else if field == "value" {
          @core.wildcard_contains(rec.value, needle, ignore_case)
        } else {
          @core.wildcard_contains(rec.key, needle, ignore_case) ||
          @core.wildcard_contains(rec.value, needle, ignore_case)
        }
      } else if field == "key" {
        match_needle(rec.key, needle, ignore_case)
      } else if field == "value" {
        match_needle(rec.value, needle, ignore_case)
      } else {
        match_needle(rec.key, needle, ignore_case) ||
        match_needle(rec.value, needle, ignore_case)
      }
      let mut in_time = true
      match since_ts {
        Some(t) => if rec.timestamp < t { in_time = false }
        None => ()
      }
      match until_ts {
        Some(t) => if rec.timestamp > t { in_time = false }
        None => ()
      }
      if hit && in_time {
        print_record(rec)
        hits = hits + 1
        if max_hits >= 0 && hits >= max_hits {
          truncated = true
          return false
        }
      }
      true
    })
    match abort_msg {
      Some(m) => raise @io.IoError::Invalid(m)
      None => ()
    }
    println(matches_summary(hits, truncated, max_hits))
  })
}

///|
/// Query timeout (4.6): a query whose per-segment guard notices the elapsed
/// time over this bound aborts with a diagnostic. Default 30s, 0 disables;
/// override with `MOONLOG_QUERY_TIMEOUT_MS` or per-query `--timeout`.
fn query_timeout_ms() -> Int64 {
  match @env.get_env_var("MOONLOG_QUERY_TIMEOUT_MS") {
    Some(v) => @string.parse_int64(v) catch { _ => 30_000_000L / 1000L }
    None => 30000L
  }
}

///|
/// Max concurrent queries per directory (4.6): enforced with flock slots on
/// `<dir>/QLOCK.<i>`; a query that cannot get a slot within the lock timeout
/// is rejected. Default 4; override with `MOONLOG_MAX_CONCURRENT_QUERIES`.
fn max_concurrent_queries() -> Int32 {
  match @env.get_env_var("MOONLOG_MAX_CONCURRENT_QUERIES") {
    Some(v) => @string.parse_int(v) catch { _ => 4 }
    None => 4
  }
}

///|
/// Scan budget (4.6): a query whose pushed-down scan set exceeds this many
/// bytes aborts before doing the work. Default 512MB, 0 disables; override
/// with `MOONLOG_MAX_SCAN_BYTES`.
fn max_scan_bytes() -> Int64 {
  match @env.get_env_var("MOONLOG_MAX_SCAN_BYTES") {
    Some(v) => @string.parse_int64(v) catch { _ => 536870912 }
    None => 536870912
  }
}

///|
/// Default result-set cap (4.6): `query` and `search` stop after this many
/// matches when no `--limit` is given, so a forgotten limit cannot dump an
/// unbounded result set. `--limit -1` (or `MOONLOG_MAX_RESULTS=0`) removes
/// the cap. Default 1000.
fn default_max_results() -> Int32 {
  match @env.get_env_var("MOONLOG_MAX_RESULTS") {
    Some(v) => {
      let n = @string.parse_int(v) catch { _ => 1000 }
      if n <= 0 {
        -1
      } else {
        n
      }
    }
    None => 1000
  }
}

///|
/// Closing line for a query result set: counts matches and, when the cap
/// stopped the scan, makes the truncation explicit so callers can retry with
/// `--limit -1` (or a higher `MOONLOG_MAX_RESULTS`).
fn matches_summary(hits : Int32, truncated : Bool, max_hits : Int32) -> String {
  if truncated {
    "(" +
    hits.to_string() +
    " matches, stopped at limit " +
    max_hits.to_string() +
    " (pass --limit -1 for all))"
  } else {
    "(" + hits.to_string() + " matches)"
  }
}

///|
/// Acquire one query-concurrency slot (4.6), retrying on a small interval
/// for up to the lock timeout before rejecting the query. The slot is held
/// until the process exits (CLI queries are short-lived).
fn acquire_query_slot(dir : String) -> Unit raise @io.IoError {
  let max = max_concurrent_queries()
  let deadline = now_ms() + lock_timeout_ms().to_int64()
  let mut idx : Int32 = 0
  while true {
    let fd = @backend_native.try_query_slot(dir, idx)
    if fd >= 0 {
      // Held on purpose for the rest of this process; no explicit release.
      return
    }
    idx = idx + 1
    if idx >= max {
      if now_ms() >= deadline {
        raise @io.IoError::Invalid(
          "too many concurrent queries (limit " +
          max.to_string() +
          "); wait for one to finish or raise MOONLOG_MAX_CONCURRENT_QUERIES",
        )
      }
      idx = 0
      @backend_native.sleep_ms(20)
    }
  }
}

///|
/// Per-query guard (4.6): accumulates the pushed-down scan set and aborts
/// the query when the timeout or the scan budget is exceeded — one runaway
/// query cannot hold the store.
struct QueryGuard {
  t0 : Int64
  timeout : Int64
  budget : Int64
  mut scanned : Int64
  mut segs : Int32
}

///|
/// Account one segment (or 0 bytes for an in-segment sampling tick) and
/// return the violation message when the timeout or scan budget is exceeded
/// (0 disables either). Non-raising so record-level callbacks can call it.
fn QueryGuard::check_soft(self : QueryGuard, seg_size : Int64) -> String? {
  self.segs = self.segs + 1
  self.scanned = self.scanned + seg_size
  let elapsed = now_ms() - self.t0
  if self.timeout > 0 && elapsed > self.timeout {
    return Some(
      "query timeout after " +
      elapsed.to_string() +
      " ms (" +
      self.segs.to_string() +
      " segments, " +
      self.scanned.to_string() +
      " bytes scanned); narrow the time range or raise MOONLOG_QUERY_TIMEOUT_MS",
    )
  }
  if self.budget > 0 && self.scanned > self.budget {
    return Some(
      "scan budget exceeded: " +
      self.scanned.to_string() +
      " bytes > " +
      self.budget.to_string() +
      " (narrow the time range or raise MOONLOG_MAX_SCAN_BYTES)",
    )
  }
  None
}

///|
/// Account one segment and raise on violation (for non-callback contexts).
fn QueryGuard::check(
  self : QueryGuard,
  seg_size : Int64,
) -> Unit raise @io.IoError {
  match self.check_soft(seg_size) {
    Some(m) => raise @io.IoError::Invalid(m)
    None => ()
  }
}

///|
/// Default query time window (4.3): scans without an explicit `--since` are
/// scoped to the last this-many milliseconds (24h), so a forgotten time
/// bound cannot trigger an unbounded scan. Override with
/// `MOONLOG_QUERY_WINDOW_MS`.
fn query_window_ms() -> Int64 {
  match @env.get_env_var("MOONLOG_QUERY_WINDOW_MS") {
    Some(v) => @string.parse_int64(v) catch { _ => 86_400_000 }
    None => 86_400_000
  }
}

///|
/// Unified-schema query: stream records in offset order and keep those that
/// match every given condition (AND). `--service` matches the record key
/// (schema ingest stores the service name as the key) or a parsed service
/// field; `--level`, `--host` and `--trace-id` match parsed fields;
/// `--contains` matches the raw value as an ASCII case-insensitive substring;
/// `--level-min`/`--level-max` filter by severity rank (debug<info<warn<
/// error<fatal; a range filter requires a known level — unknown levels are
/// excluded); `--since`/`--until` bound
/// the record timestamp (epoch ms, inclusive). Pushdown (4.2): time bounds
/// skip whole segments via `min_ts`/`max_ts` without decoding, and with
/// `--indexed` the equality/range conditions expand to field-column postings
/// preselection before the full AND refinement.
/// Forced time range (4.3): a query without an explicit `--since` degrades to
/// the default window (last 24h, `MOONLOG_QUERY_WINDOW_MS`) instead of
/// scanning unbounded; with `--require-time` such a query is rejected
/// outright. `--since 0` is an explicit full scan and bypasses both.
/// `--limit` stops early; without it the result set is capped at
/// `MOONLOG_MAX_RESULTS` (default 1000, `--limit -1` removes the cap) and
/// the summary marks the truncation. With `--sort-by-time`, matches are
/// collected and
/// printed ordered by event time (ties keep offset order) instead of the
/// arrival (offset) order — the standard answer to out-of-order delivery.
/// With `--indexed`, **every** equality/range condition is pushed down: each
/// expands to per-segment field-column postings (`name=value`, service also
/// via the record key); an empty posting means the segment cannot match, and
/// the shortest posting becomes the candidate set before the full AND
/// refinement. `--explain` prints the pushed conditions, candidate count and
/// skipped-segment count so the storage-level execution can be audited. No
/// condition falls back to the linear scan. Output is the standard record
/// line, or JSON with `--json`. Non-schema records still match `--service`
/// via the key and `--contains` via the value, so mixed directories stay
/// queryable.
fn cmd_query(
  dir : String,
  level : String?,
  service : String?,
  host : String?,
  trace_id : String?,
  level_min : String?,
  level_max : String?,
  contains : String?,
  since : String?,
  until : String?,
  limit : String?,
  indexed : Bool,
  sort_by_time : Bool,
  json : Bool,
  require_time : Bool,
  timeout : String?,
  explain : Bool,
) -> Unit raise @io.IoError {
  let scope = active_scope(dir)
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
  // 4.3 forced time range: no unbounded scans. Without an explicit `--since`
  // the query degrades to the default window, or (with `--require-time`) is
  // rejected. `--since 0` is explicit and scans everything.
  let since_ts : Int64? = match since {
    Some(s) =>
      Some(
        @string.parse_int64(s) catch {
          _ => raise @io.IoError::Invalid("invalid since: " + s)
        },
      )
    None =>
      if require_time {
        raise @io.IoError::Invalid(
          "query requires --since (unbounded scans are disabled by --require-time); pass --since 0 to scan everything explicitly",
        )
      } else {
        let win = query_window_ms()
        if !json {
          println(
            "INFO query scoped to the last " +
            (win / (1000 : Int64)).to_string() +
            "s (default window; pass --since to override, --since 0 for everything)",
          )
        }
        Some(now_ms() - win)
      }
  }
  // 4.6 query guard: concurrency slot, per-segment timeout and scan budget.
  acquire_query_slot(dir)
  // 6.2 tenant concurrency quota, shared with every analysis entry point.
  acquire_tenant_query_quota(dir)
  let timeout_val : Int64 = match timeout {
    Some(t) =>
      @string.parse_int64(t) catch {
        _ => raise @io.IoError::Invalid("invalid timeout: " + t)
      }
    None => query_timeout_ms()
  }
  let qg : QueryGuard = {
    t0: now_ms(),
    timeout: timeout_val,
    budget: max_scan_bytes(),
    scanned: 0,
    segs: 0,
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
  let min_rank : Int32? = match level_min {
    Some(s) => {
      let r = @core.level_rank(@utf8.encode(s))
      if r < 0 {
        raise @io.IoError::Invalid("invalid level: " + s)
      }
      Some(r)
    }
    None => None
  }
  let max_rank : Int32? = match level_max {
    Some(s) => {
      let r = @core.level_rank(@utf8.encode(s))
      if r < 0 {
        raise @io.IoError::Invalid("invalid level: " + s)
      }
      Some(r)
    }
    None => None
  }
  let max_hits = match limit {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid limit: " + s)
      }
    None => default_max_results()
  }
  // --indexed: the most selective given condition (equality or a level rank
  // range expanded over the five known levels) preselects candidates through
  // the per-segment field-column index; the full AND refinement still runs.
  let has_level_cond = match level_b {
    Some(_) => true
    None =>
      match min_rank {
        Some(_) => true
        None =>
          match max_rank {
            Some(_) => true
            None => false
          }
      }
  }
  let level_values : Array[Bytes]? = if has_level_cond {
    let vals : Array[Bytes] = []
    let lo_r : Int32 = match min_rank {
      Some(r) => r
      None => 0
    }
    let hi_r : Int32 = match max_rank {
      Some(r) => r
      None => 4
    }
    let table : Array[(Int32, Bytes)] = [
      (0, b"debug"),
      (1, b"info"),
      (2, b"warn"),
      (3, b"error"),
      (4, b"fatal"),
    ]
    for pair in table {
      let (r, v) = pair
      if r >= lo_r && r <= hi_r {
        match level_b {
          Some(l) => if l == v { vals.push(v) }
          None => vals.push(v)
        }
      }
    }
    Some(vals)
  } else {
    None
  }
  let idx_filters : Array[(Bytes, Array[Bytes], Bool)] = []
  if indexed {
    match level_values {
      Some(vals) => idx_filters.push((b"level", vals, false))
      None => ()
    }
    match service_b {
      Some(s) => idx_filters.push((b"service", [s], true))
      None => ()
    }
    match host_b {
      Some(h) => idx_filters.push((b"host", [h], false))
      None => ()
    }
    match trace_b {
      Some(t) => idx_filters.push((b"trace_id", [t], false))
      None => ()
    }
  }
  let mut pushed : String = ""
  for f in idx_filters {
    if pushed.length() > 0 {
      pushed = pushed + ","
    }
    pushed = pushed + (@utf8.decode(f.0) catch { _ => "" })
  }
  if idx_filters.length() > 0 {
    run_read_snapshot(dir, log => {
      let mut hits = 0
      let mut stop = false
      let mut truncated = false
      let mut abort_msg : String? = None
      let mut total_cands : Int64 = 0
      let mut skipped : Int32 = 0
      for seg in log.segments {
        if stop {
          break
        }
        if abort_msg is Some(_) {
          break
        }
        // Pushdown (4.2): skip segments disjoint from the time bounds.
        let mut in_range = true
        if seg.record_count > 0 {
          match since_ts {
            Some(t) => if seg.max_ts < t { in_range = false }
            None => ()
          }
          match until_ts {
            Some(t) => if seg.min_ts > t { in_range = false }
            None => ()
          }
        }
        if !in_range {
          skipped = skipped + 1
          continue
        }
        qg.check(seg.size)
        seg.ensure_inv_index()
        // Persist the lazily built index so a later process loads the
        // sidecar instead of rebuilding (atomic replace, safe under the
        // shared reader lock).
        if !@backend_native.has_segment_inv(dir, seg.base_offset) {
          match seg.inv_index {
            Some(ix) =>
              @backend_native.save_segment_inv(
                dir,
                seg.base_offset,
                ix.encode(),
              )
            None => ()
          }
        }
        // All AND conditions are pushed down: each produces a per-segment
        // posting union; an empty union means the segment cannot match, and
        // the shortest union becomes the candidate set (the remaining
        // conditions are verified by schema_matches below).
        let mut best : Array[UInt64]? = None
        let mut best_len : Int32 = 0
        let mut seg_empty = false
        for f in idx_filters {
          let (fname, fvals, also_key) = f
          let set : @hashmap.HashMap[UInt64, Bool] = @hashmap.HashMap::HashMap([])
          for v in fvals {
            for i2 in seg.inv_field_postings(fname, v) {
              set.set(seg.base_offset + i2.to_uint64(), true)
            }
          }
          if also_key {
            for v in fvals {
              for i2 in seg.inv_field_postings(b"__key__", v) {
                set.set(seg.base_offset + i2.to_uint64(), true)
              }
            }
          }
          let arr : Array[UInt64] = []
          set.each(fn(k, _) { arr.push(k) })
          if arr.length() == 0 {
            seg_empty = true
            break
          }
          let have = match best {
            Some(_) => true
            None => false
          }
          if !have || arr.length() < best_len {
            best = Some(arr)
            best_len = arr.length()
          }
        }
        if seg_empty {
          skipped = skipped + 1
          continue
        }
        let mut cands : Array[UInt64] = []
        match best {
          Some(a) => cands = a
          None => ()
        }
        total_cands = total_cands + cands.length().to_int64()
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
        let mut seen_cands : Int32 = 0
        for off in cands {
          seen_cands = seen_cands + 1
          // Record-granularity timeout sampling (4.6).
          if seen_cands % 512 == 0 {
            match qg.check_soft(0) {
              Some(m) => abort_msg = Some(m)
              None => ()
            }
          }
          if abort_msg is Some(_) {
            break
          }
          if max_hits >= 0 && hits >= max_hits {
            truncated = true
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
                let mut lv : Bytes? = None
                for pair in fields {
                  if pair.0 == b"level" {
                    lv = Some(pair.1)
                  }
                }
                let lr = match lv {
                  Some(l) => @core.level_rank(l)
                  None => -1
                }
                let ranged = match min_rank {
                  Some(_) => true
                  None =>
                    match max_rank {
                      Some(_) => true
                      None => false
                    }
                }
                if ranged {
                  // Consistent with the linear path: a range filter
                  // requires a known level.
                  if lr < 0 {
                    hit = false
                  } else {
                    match min_rank {
                      Some(rk) => if lr < rk { hit = false }
                      None => ()
                    }
                    match max_rank {
                      Some(rk) => if lr > rk { hit = false }
                      None => ()
                    }
                  }
                }
                if hit {
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
              }
              if hit && scope_allows_key(scope, r.key) {
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
      match abort_msg {
        Some(m) => raise @io.IoError::Invalid(m)
        None => ()
      }
      if explain {
        println(
          "(pushed " +
          pushed +
          "; candidates " +
          total_cands.to_string() +
          "; segments_skipped " +
          skipped.to_string() +
          ")",
        )
      }
      println(matches_summary(hits, truncated, max_hits) + " (indexed)")
    })
    return
  }
  run_read_snapshot(dir, log => {
    let mut hits = 0
    let collected : Array[@core.Record] = []
    let mut stop = false
    let mut truncated = false
    let mut abort_msg : String? = None
    for seg in log.segments {
      if stop {
        break
      }
      if abort_msg is Some(_) {
        break
      }
      // Pushdown (4.2): skip segments whose time range is disjoint from the
      // [since, until] bounds (segment-granularity skipping via min_ts/max_ts).
      if seg.record_count > 0 {
        match since_ts {
          Some(t) => if seg.max_ts < t { continue }
          None => ()
        }
        match until_ts {
          Some(t) => if seg.min_ts > t { continue }
          None => ()
        }
      }
      qg.check(seg.size)
      let mut seen_in_seg : Int32 = 0
      seg.for_each(seg.base_offset, seg.next_offset, rec => {
        seen_in_seg = seen_in_seg + 1
        // Record-granularity timeout sampling (4.6): segment-level checks
        // alone miss a runaway scan inside one huge segment.
        if seen_in_seg % 512 == 0 {
          match qg.check_soft(0) {
            Some(m) => abort_msg = Some(m)
            None => ()
          }
        }
        if stop || abort_msg is Some(_) {
          return
        }
        if !scope_allows_key(scope, rec.key) {
          return
        }
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
          let mut lv : Bytes? = None
          for pair in fields {
            if pair.0 == b"level" {
              lv = Some(pair.1)
            }
          }
          let lr = match lv {
            Some(l) => @core.level_rank(l)
            None => -1
          }
          let ranged = match min_rank {
            Some(_) => true
            None =>
              match max_rank {
                Some(_) => true
                None => false
              }
          }
          if ranged {
            // A range filter requires a known level: unknown levels are
            // excluded (consistent with the field-column pushdown).
            if lr < 0 {
              hit = false
            } else {
              match min_rank {
                Some(rk) => if lr < rk { hit = false }
                None => ()
              }
              match max_rank {
                Some(rk) => if lr > rk { hit = false }
                None => ()
              }
            }
          }
          if hit {
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
          if max_hits >= 0 && hits >= max_hits {
            truncated = true
            stop = true
          }
        }
      })
    }
    match abort_msg {
      Some(m) => raise @io.IoError::Invalid(m)
      None => ()
    }
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
    println(matches_summary(hits, truncated, max_hits))
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
  trace_id : String?,
  service : String?,
  thread_id : String?,
  sort_by_time : Bool,
) -> Unit raise @io.IoError {
  let scope = active_scope(dir)
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
    if target >= log.next_offset() {
      raise @io.IoError::Invalid("offset out of range: " + offset)
    }
    // 6.1: the anchor itself must be inside the role's data scope; otherwise
    // context would leak a cross-project record (and its neighbours).
    match log.get(target) {
      Some(anchor) => require_scope(dir, "context", anchor.key)
      None => ()
    }
    // Correlation predicates (4.4): explicit values, or `auto` extracted from
    // the anchor record (KV or JSON, with field-name normalization).
    let trace_auto = match trace_id {
      Some(t) => t == "auto"
      None => false
    }
    let thread_auto = match thread_id {
      Some(t) => t == "auto"
      None => false
    }
    let mut anchor_value : Bytes? = None
    if trace_auto || thread_auto {
      let anchor = log.get(target) catch { _ => None }
      match anchor {
        Some(rec) => anchor_value = Some(rec.value)
        None => ()
      }
    }
    let trace_filter : Bytes? = match trace_id {
      Some(t) =>
        if t == "auto" {
          match anchor_value {
            Some(v) => ctx_field_value(v, [b"trace_id", b"trace"])
            None => None
          }
        } else {
          Some(@utf8.encode(t))
        }
      None => None
    }
    let thread_filter : Bytes? = match thread_id {
      Some(t) =>
        if t == "auto" {
          match anchor_value {
            Some(v) => ctx_field_value(v, [b"thread_id", b"thread"])
            None => None
          }
        } else {
          Some(@utf8.encode(t))
        }
      None => None
    }
    let service_filter : Bytes? = match service {
      Some(sv) => Some(@utf8.encode(sv))
      None => None
    }
    let correlating = match trace_filter {
      Some(_) => true
      None =>
        match thread_filter {
          Some(_) => true
          None =>
            match service_filter {
              Some(_) => true
              None => false
            }
        }
    }
    let before_n = b
    let after_n = a
    let ring : Array[@core.Record] = []
    let mut out_after = 0
    let window : Array[@core.Record] = []
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      if !scope_allows_key(scope, rec.key) {
        return true
      }
      if rec.offset == target {
        for r in ring {
          window.push(r)
        }
        window.push(rec)
        return true
      }
      let mut m = true
      if correlating {
        let fields = ctx_value_fields(rec.value)
        let rtv = ctx_field_from_pairs(fields, [b"trace_id", b"trace"])
        let rsv = ctx_field_from_pairs(fields, [b"service"])
        let rth = ctx_field_from_pairs(fields, [b"thread_id", b"thread"])
        match trace_filter {
          Some(tv) =>
            match rtv {
              Some(v) => if !ctx_bytes_eq_ci(v, tv) { m = false }
              None => m = false
            }
          None => ()
        }
        if m {
          match service_filter {
            Some(sv) =>
              if !ctx_bytes_eq_ci(rec.key, sv) &&
                (match rsv {
                  Some(v) => !ctx_bytes_eq_ci(v, sv)
                  None => true
                }) {
                m = false
              }
            None => ()
          }
        }
        if m {
          match thread_filter {
            Some(tv) =>
              match rth {
                Some(v) => if !ctx_bytes_eq_ci(v, tv) { m = false }
                None => m = false
              }
            None => ()
          }
        }
      }
      if rec.offset < target {
        // Before the anchor: keep the last `before_n` matching records.
        if m {
          ring.push(rec)
          if ring.length() > before_n {
            ignore(ring.remove(0))
          }
        }
      } else {
        // After the anchor: collect the first `after_n` matching records.
        if m && out_after < after_n {
          window.push(rec)
          out_after = out_after + 1
        }
        if out_after >= after_n {
          return false
        }
      }
      true
    })
    // Event-time order (4.4) for out-of-order delivery; ties keep offset order.
    if sort_by_time {
      window
      .mut_view()
      .sort_by(fn(x, y) {
        if x.timestamp < y.timestamp {
          -1
        } else if x.timestamp > y.timestamp {
          1
        } else if x.offset < y.offset {
          -1
        } else if x.offset > y.offset {
          1
        } else {
          0
        }
      })
    }
    for r in window {
      print_record(r)
    }
    println("(" + window.length().to_string() + " records)")
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

///|
/// Nearest-rank percentile of a sorted array: `vals[ceil(q*n)-1]`, clamped
/// into range (zero dependency — no ceil/math import).
fn pct_of(sorted : Array[Double], q : Double) -> Double {
  let n = sorted.length()
  let prod = q * n.to_double()
  let mut idx = prod.to_int()
  if prod > idx.to_double() {
    idx = idx + 1
  }
  idx = idx - 1
  if idx < 0 {
    idx = 0
  }
  if idx >= n {
    idx = n - 1
  }
  sorted[idx]
}

///|
/// Multi-dimensional count/quantile aggregation (5.1). Group dimensions are
/// record key/value/kind/UTC hour/key prefix or a value field (`--kv-field`,
/// KV or JSON-flattened). `--quantile` adds per-bucket count/min/avg/
/// p50/p95/p99/max. Bounded by `--since`/`--until` (default last 24h,
/// `--since 0` for everything) with segment min_ts/max_ts pushdown; shares
/// the 4.6 query slot/timeout/scan budget and scans outside the writer lock.
fn cmd_aggregate(
  dir : String,
  by : String,
  kv_field : String?,
  match_text : String?,
  top : String?,
  json : Bool,
  quantile : String?,
  since : String?,
  until : String?,
) -> Unit raise @io.IoError {
  let scope = active_scope(dir)
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
  let qfield : Bytes? = match quantile {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
  // Time scoping (5.1): aggregations are bounded like query/search (4.3) and
  // pushed down to segment min_ts/max_ts. `--since 0` is an explicit
  // full-history aggregation; otherwise the default window applies.
  let since_ts : Int64? = match since {
    Some(s) =>
      Some(
        @string.parse_int64(s) catch {
          _ => raise @io.IoError::Invalid("invalid since: " + s)
        },
      )
    None => {
      let win = query_window_ms()
      if !json {
        println(
          "INFO aggregate scoped to the last " +
          (win / (1000 : Int64)).to_string() +
          "s (default window; pass --since to override, --since 0 for everything)",
        )
      }
      Some(now_ms() - win)
    }
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
  // 5.1 production guards: share the 4.6 query slot/guard and scan outside
  // the writer lock, so a slow aggregation does not stall ingestion.
  acquire_query_slot(dir)
  acquire_tenant_query_quota(dir)
  let qg : QueryGuard = {
    t0: now_ms(),
    timeout: query_timeout_ms(),
    budget: max_scan_bytes(),
    scanned: 0,
    segs: 0,
  }
  run_read_snapshot(dir, log => {
    let counts : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([])
    let qvals : @hashmap.HashMap[Bytes, Array[Double]] = @hashmap.HashMap::HashMap([],
    )
    let mut skipped : Int32 = 0
    let mut abort_msg : String? = None
    for seg in log.segments {
      if abort_msg is Some(_) {
        break
      }
      if seg.record_count > 0 {
        match since_ts {
          Some(t) => if seg.max_ts < t { continue }
          None => ()
        }
        match until_ts {
          Some(t) => if seg.min_ts > t { continue }
          None => ()
        }
      }
      qg.check(seg.size)
      let mut seen = 0
      seg.for_each(seg.base_offset, seg.next_offset, rec => {
        seen = seen + 1
        if seen % 512 == 0 {
          match qg.check_soft(0) {
            Some(m) => abort_msg = Some(m)
            None => ()
          }
        }
        if abort_msg is Some(_) {
          return
        }
        if !scope_allows_key(scope, rec.key) {
          return
        }
        let mut in_time = true
        match since_ts {
          Some(t) => if rec.timestamp < t { in_time = false }
          None => ()
        }
        match until_ts {
          Some(t) => if rec.timestamp > t { in_time = false }
          None => ()
        }
        if !in_time {
          return
        }
        let pass = match needle {
          Some(n) =>
            match_needle(rec.key, n, true) || match_needle(rec.value, n, true)
          None => true
        }
        if pass {
          let bucket : Bytes = match field {
            Some(f) => {
              let pairs = ctx_value_fields(rec.value)
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
          match qfield {
            Some(qf) => {
              let qpairs = ctx_value_fields(rec.value)
              let mut qv : Bytes? = None
              for qp in qpairs {
                if qp.0 == qf {
                  qv = Some(qp.1)
                }
              }
              match qv {
                Some(raw) => {
                  let d_opt = Some(
                    @string.parse_double(@utf8.decode_lossy(raw)),
                  ) catch {
                    _ => None
                  }
                  match d_opt {
                    Some(d) =>
                      match qvals.get(bucket) {
                        Some(arr) => arr.push(d)
                        None => qvals.set(bucket, [d])
                      }
                    None => skipped = skipped + 1
                  }
                }
                None => skipped = skipped + 1
              }
            }
            None => ()
          }
          bump_bytes(counts, bucket)
        }
      })
    }
    match abort_msg {
      Some(m) => raise @io.IoError::Invalid(m)
      None => ()
    }
    let items : Array[(Bytes, Int32)] = []
    for k in counts.keys() {
      match counts.get(k) {
        Some(c) => items.push((k, c))
        None => ()
      }
    }
    let shown = top_counts(items, top_n)
    match qfield {
      Some(qf) => {
        // Quantile table (5.1): count/min/avg/p50/p95/p99/max per bucket,
        // buckets ordered by record count (same --top clipping).
        let qf_str = bytes_to_string(qf)
        if json {
          let by_label = match kv_field {
            Some(f) => "kv:" + f
            None => by
          }
          let mut s = "{\"by\":\"" +
            by_label +
            "\",\"quantile\":\"" +
            qf_str +
            "\",\"buckets\":["
          let mut first = true
          for item in shown {
            match qvals.get(item.0) {
              Some(vals) => {
                vals
                .mut_view()
                .sort_by(fn(a, b) {
                  if a < b {
                    -1
                  } else if a > b {
                    1
                  } else {
                    0
                  }
                })
                let n = vals.length()
                let mut sum : Double = 0.0
                for v in vals {
                  sum = sum + v
                }
                if !first {
                  s = s + ","
                }
                first = false
                s = s +
                  "{\"bucket\":\"" +
                  json_escape_str(bytes_to_string(item.0)) +
                  "\",\"count\":" +
                  n.to_string() +
                  ",\"min\":" +
                  vals[0].to_string() +
                  ",\"avg\":" +
                  (sum / n.to_double()).to_string() +
                  ",\"p50\":" +
                  pct_of(vals, 0.5).to_string() +
                  ",\"p95\":" +
                  pct_of(vals, 0.95).to_string() +
                  ",\"p99\":" +
                  pct_of(vals, 0.99).to_string() +
                  ",\"max\":" +
                  vals[n - 1].to_string() +
                  "}"
              }
              None => ()
            }
          }
          s = s +
            "],\"skipped\":" +
            skipped.to_string() +
            ",\"total_buckets\":" +
            counts.length().to_string() +
            "}"
          println(s)
        } else {
          println("count  min  avg  p50  p95  p99  max  bucket")
          for item in shown {
            match qvals.get(item.0) {
              Some(vals) => {
                vals
                .mut_view()
                .sort_by(fn(a, b) {
                  if a < b {
                    -1
                  } else if a > b {
                    1
                  } else {
                    0
                  }
                })
                let n = vals.length()
                let mut sum : Double = 0.0
                for v in vals {
                  sum = sum + v
                }
                println(
                  n.to_string() +
                  "  " +
                  vals[0].to_string() +
                  "  " +
                  (sum / n.to_double()).to_string() +
                  "  " +
                  pct_of(vals, 0.5).to_string() +
                  "  " +
                  pct_of(vals, 0.95).to_string() +
                  "  " +
                  pct_of(vals, 0.99).to_string() +
                  "  " +
                  vals[n - 1].to_string() +
                  "  " +
                  bytes_to_string(item.0),
                )
              }
              None => ()
            }
          }
          println(
            "(" +
            counts.length().to_string() +
            " buckets, " +
            skipped.to_string() +
            " skipped)",
          )
        }
      }
      None =>
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
    }
  })
}

///|
/// Sorted-in-place latency samples for an optional bucket array (empty when
/// the bucket has no numeric samples), shared by the trend/JSON rendering.
fn sorted_latency(vals : Array[Double]?) -> Array[Double] {
  match vals {
    Some(a) => {
      a
      .mut_view()
      .sort_by(fn(x, y) { if x < y { -1 } else if x > y { 1 } else { 0 } })
      a
    }
    None => []
  }
}

///|
/// Ops dashboard (5.5, optimized): one scan, one panel for daily inspection —
/// volume histogram with per-bucket error rate, **per-bucket latency trend**
/// (p50/p95/p99/max when `--quantile-field` is set), window totals, window
/// latency quantiles, and a **switchable dimension breakdown** (`--by
/// service|level|host|key`, default service). Time-scoped by `--last <sec>`
/// (default 3600) or an absolute `--since/--until` window for historical
/// drill-down (`--since 0` is the full history). Uses segment min_ts/max_ts
/// pushdown, the 4.6 query slot/timeout/scan budget and a snapshot read, so a
/// slow panel never stalls ingestion. Values are parsed from KV text or JSON
/// objects (2.1 flattening), so SDK-appended structured logs work; error =
/// severity rank >= 3 from a recognized level field (case-insensitive), or —
/// only when no level field exists — a literal "error" substring (avoids the
/// old false positive on `{"level":"INFO","msg":"no error"}`).
fn cmd_dashboard(
  dir : String,
  last_sec : String,
  bucket : String,
  quantile_field : String?,
  service : String?,
  since : String?,
  until : String?,
  by : String,
  top : String,
  json : Bool,
) -> Unit raise @io.IoError {
  let scope = active_scope(dir)
  if bucket != "minute" && bucket != "hour" && bucket != "day" {
    raise @io.IoError::Invalid(
      "invalid bucket: " + bucket + " (minute|hour|day)",
    )
  }
  if by != "service" && by != "level" && by != "host" && by != "key" {
    raise @io.IoError::Invalid(
      "invalid dimension: " + by + " (service|level|host|key)",
    )
  }
  let top_n = @string.parse_int(top) catch {
    _ => raise @io.IoError::Invalid("invalid top: " + top)
  }
  if top_n <= 0 {
    raise @io.IoError::Invalid("top must be positive")
  }
  let last_ms = (@string.parse_int64(last_sec) catch {
      _ => raise @io.IoError::Invalid("invalid last: " + last_sec)
    }) *
    (1000 : Int64)
  if last_ms <= 0 {
    raise @io.IoError::Invalid("last must be positive")
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
  match (since_ts, until_ts) {
    (Some(f), Some(u)) =>
      if u < f {
        raise @io.IoError::Invalid("until must not be before since")
      }
    _ => ()
  }
  let now = now_ms()
  let from_ts = match since_ts {
    Some(f) => f
    None => now - last_ms
  }
  let to_ts = match until_ts {
    Some(u) => u
    None => now
  }
  if to_ts < from_ts {
    raise @io.IoError::Invalid("time window is empty (until < since)")
  }
  let window_sec = (to_ts - from_ts) / (1000 : Int64)
  let qfield : Bytes? = match quantile_field {
    Some(f) => Some(@utf8.encode(f))
    None => None
  }
  let service_b : Bytes? = match service {
    Some(sv) => Some(@utf8.encode(sv))
    None => None
  }
  let level_names : Array[Bytes] = [
    b"level", b"severity", b"severity_text", b"lvl", b"loglevel", b"log.level",
  ]
  let service_names : Array[Bytes] = [
    b"service", b"service.name", b"svc", b"app",
  ]
  let host_names : Array[Bytes] = [b"host", b"hostname", b"host.name", b"node"]
  // 4.6 production guards: share the query slot/guard and scan outside the
  // writer lock (snapshot read), so a slow panel cannot stall ingestion.
  // Create the directory first: slot lookup on a missing path would loop and
  // masquerade as "too many concurrent queries" on a fresh inspection target.
  ignore(@backend_native.ensure_dir(dir))
  acquire_query_slot(dir)
  acquire_tenant_query_quota(dir)
  let qg : QueryGuard = {
    t0: now_ms(),
    timeout: query_timeout_ms(),
    budget: max_scan_bytes(),
    scanned: 0,
    segs: 0,
  }
  run_read_snapshot(dir, log => {
    let bucket_total : @hashmap.HashMap[String, Int32] = @hashmap.HashMap::HashMap([],
    )
    let bucket_err : @hashmap.HashMap[String, Int32] = @hashmap.HashMap::HashMap([],
    )
    let bucket_lat : @hashmap.HashMap[String, Array[Double]] = @hashmap.HashMap::HashMap([],
    )
    let dim_total : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([])
    let dim_err : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([])
    let dim_lat : @hashmap.HashMap[Bytes, Array[Double]] = @hashmap.HashMap::HashMap([],
    )
    let svc_counts : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([],
    )
    let qvals : Array[Double] = []
    let mut total = 0
    let mut errors = 0
    let mut aborted : String? = None
    for seg in log.segments {
      if aborted is Some(_) {
        break
      }
      if seg.record_count > 0 {
        // Pushdown: skip segments disjoint from the inspection window.
        if seg.max_ts < from_ts {
          continue
        }
        if seg.min_ts > to_ts {
          continue
        }
      }
      qg.check(seg.size)
      let mut seen = 0
      seg.for_each(seg.base_offset, seg.next_offset, rec => {
        seen = seen + 1
        if seen % 512 == 0 {
          match qg.check_soft(0) {
            Some(m) => aborted = Some(m)
            None => ()
          }
        }
        if aborted is Some(_) {
          return
        }
        if rec.timestamp < from_ts || rec.timestamp > to_ts {
          return
        }
        if !scope_allows_key(scope, rec.key) {
          return
        }
        let fields = ctx_value_fields(rec.value)
        let svc = match ctx_field_from_pairs(fields, service_names) {
          Some(s) => s
          None => rec.key
        }
        match service_b {
          Some(sb) =>
            if !ctx_name_eq(svc, sb) && !ctx_name_eq(rec.key, sb) {
              return
            }
          None => ()
        }
        total = total + 1
        let label = @core.format_utc(rec.timestamp, bucket)
        bump_string(bucket_total, label)
        let level_v = ctx_field_from_pairs(fields, level_names)
        let is_err = match level_v {
          Some(l) => @core.level_rank(follow_lower_ascii(l)) >= 3
          None => match_needle(rec.value, b"error", true)
        }
        if is_err {
          errors = errors + 1
          bump_string(bucket_err, label)
        }
        bump_bytes(svc_counts, svc)
        let dim : Bytes = if by == "level" {
          match level_v {
            Some(l) => follow_lower_ascii(l)
            None => b"<none>"
          }
        } else if by == "host" {
          match ctx_field_from_pairs(fields, host_names) {
            Some(h) => h
            None => b"<missing>"
          }
        } else if by == "key" {
          rec.key
        } else {
          svc
        }
        bump_bytes(dim_total, dim)
        if is_err {
          bump_bytes(dim_err, dim)
        }
        match qfield {
          Some(qf) =>
            match ctx_field_from_pairs(fields, [qf]) {
              Some(raw) => {
                let d_opt = Some(@string.parse_double(@utf8.decode_lossy(raw))) catch {
                  _ => None
                }
                match d_opt {
                  Some(d) => {
                    qvals.push(d)
                    match bucket_lat.get(label) {
                      Some(arr) => arr.push(d)
                      None => bucket_lat.set(label, [d])
                    }
                    match dim_lat.get(dim) {
                      Some(arr) => arr.push(d)
                      None => dim_lat.set(dim, [d])
                    }
                  }
                  None => ()
                }
              }
              None => ()
            }
          None => ()
        }
      })
    }
    match aborted {
      Some(m) => raise @io.IoError::Invalid(m)
      None => ()
    }
    // Sorted bucket labels (oldest first).
    let labels : Array[String] = []
    for k in bucket_total.keys() {
      labels.push(k)
    }
    labels.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
    let mut max_total : Int32 = 0
    let mut max_p95 : Double = 0.0
    for label in labels {
      match bucket_total.get(label) {
        Some(c) => if c > max_total { max_total = c }
        None => ()
      }
      let lat = sorted_latency(bucket_lat.get(label))
      if lat.length() > 0 {
        let p = pct_of(lat, 0.95)
        if p > max_p95 {
          max_p95 = p
        }
      }
    }
    let err_rate : Double = if total > 0 {
      errors.to_double() * 100.0 / total.to_double()
    } else {
      0.0
    }
    // Dimension breakdown (default service, same shape as the old top list).
    let dim_items : Array[(Bytes, Int32)] = []
    for k in dim_total.keys() {
      match dim_total.get(k) {
        Some(c) => dim_items.push((k, c))
        None => ()
      }
    }
    let dim_top = top_counts(dim_items, top_n)
    let mut max_dim : Int32 = 0
    for item in dim_top {
      if item.1 > max_dim {
        max_dim = item.1
      }
    }
    if json {
      let mut s = "{\"dir\":\"" +
        json_escape_str(dir) +
        "\",\"since\":" +
        from_ts.to_string() +
        ",\"until\":" +
        to_ts.to_string() +
        ",\"last_sec\":" +
        window_sec.to_string() +
        ",\"bucket\":\"" +
        bucket +
        "\",\"by\":\"" +
        by +
        "\",\"windows\":["
      let mut first = true
      for label in labels {
        let t = match bucket_total.get(label) {
          Some(c) => c
          None => 0
        }
        let e = match bucket_err.get(label) {
          Some(c) => c
          None => 0
        }
        let rate = if t > 0 {
          e.to_double() * 100.0 / t.to_double()
        } else {
          0.0
        }
        let lat = sorted_latency(bucket_lat.get(label))
        let ln = lat.length()
        if !first {
          s = s + ","
        }
        first = false
        s = s +
          "{\"window\":\"" +
          label +
          "\",\"total\":" +
          t.to_string() +
          ",\"errors\":" +
          e.to_string() +
          ",\"err_pct\":" +
          rate.to_string() +
          ",\"latency\":{\"n\":" +
          ln.to_string() +
          ",\"p50\":" +
          (if ln > 0 { pct_of(lat, 0.5).to_string() } else { "0" }) +
          ",\"p95\":" +
          (if ln > 0 { pct_of(lat, 0.95).to_string() } else { "0" }) +
          ",\"p99\":" +
          (if ln > 0 { pct_of(lat, 0.99).to_string() } else { "0" }) +
          ",\"max\":" +
          (if ln > 0 { lat[ln - 1].to_string() } else { "0" }) +
          "}}"
      }
      s = s +
        "],\"summary\":{\"total\":" +
        total.to_string() +
        ",\"errors\":" +
        errors.to_string() +
        ",\"err_pct\":" +
        err_rate.to_string() +
        ",\"services\":" +
        svc_counts.length().to_string() +
        "}"
      match qfield {
        Some(qf) => {
          qvals
          .mut_view()
          .sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
          let n = qvals.length()
          let mut sum : Double = 0.0
          for v in qvals {
            sum = sum + v
          }
          let avg = if n > 0 { sum / n.to_double() } else { 0.0 }
          s = s +
            ",\"quantile\":{\"field\":\"" +
            bytes_to_string(qf) +
            "\",\"n\":" +
            n.to_string() +
            ",\"min\":" +
            (if n > 0 { qvals[0].to_string() } else { "0" }) +
            ",\"avg\":" +
            avg.to_string() +
            ",\"p50\":" +
            (if n > 0 { pct_of(qvals, 0.5).to_string() } else { "0" }) +
            ",\"p95\":" +
            (if n > 0 { pct_of(qvals, 0.95).to_string() } else { "0" }) +
            ",\"p99\":" +
            (if n > 0 { pct_of(qvals, 0.99).to_string() } else { "0" }) +
            ",\"max\":" +
            (if n > 0 { qvals[n - 1].to_string() } else { "0" }) +
            "}"
        }
        None => ()
      }
      s = s + ",\"dimensions\":["
      let mut first_dim = true
      for item in dim_top {
        let dt = item.1
        let de = match dim_err.get(item.0) {
          Some(c) => c
          None => 0
        }
        let drate = if dt > 0 {
          de.to_double() * 100.0 / dt.to_double()
        } else {
          0.0
        }
        let dlat = sorted_latency(dim_lat.get(item.0))
        let dn = dlat.length()
        if !first_dim {
          s = s + ","
        }
        first_dim = false
        s = s +
          "{\"name\":\"" +
          json_escape_str(bytes_to_string(item.0)) +
          "\",\"total\":" +
          dt.to_string() +
          ",\"errors\":" +
          de.to_string() +
          ",\"err_pct\":" +
          drate.to_string() +
          ",\"latency\":{\"n\":" +
          dn.to_string() +
          ",\"p50\":" +
          (if dn > 0 { pct_of(dlat, 0.5).to_string() } else { "0" }) +
          ",\"p95\":" +
          (if dn > 0 { pct_of(dlat, 0.95).to_string() } else { "0" }) +
          ",\"p99\":" +
          (if dn > 0 { pct_of(dlat, 0.99).to_string() } else { "0" }) +
          ",\"max\":" +
          (if dn > 0 { dlat[dn - 1].to_string() } else { "0" }) +
          "}}"
      }
      s = s + "]}"
      println(s)
    } else {
      println(
        "=== dashboard: " +
        dir +
        " (since " +
        from_ts.to_string() +
        " until " +
        to_ts.to_string() +
        " / " +
        window_sec.to_string() +
        "s, bucket " +
        bucket +
        ", by " +
        by +
        ") ===",
      )
      println("volume & errors:")
      for label in labels {
        let t = match bucket_total.get(label) {
          Some(c) => c
          None => 0
        }
        let e = match bucket_err.get(label) {
          Some(c) => c
          None => 0
        }
        let rate = if t > 0 {
          e.to_double() * 100.0 / t.to_double()
        } else {
          0.0
        }
        let bars = if max_total > 0 {
          (t.to_double() * 40.0 / max_total.to_double()).to_int()
        } else {
          0
        }
        let bar = {
          let sb = StringBuilder()
          let mut k = 0
          while k < bars {
            sb.write_char('#')
            k = k + 1
          }
          sb.to_string()
        }
        println(
          label +
          "  " +
          t.to_string() +
          "  err=" +
          e.to_string() +
          " (" +
          rate.to_string() +
          "%)  |" +
          bar,
        )
      }
      println(
        "summary: total=" +
        total.to_string() +
        " errors=" +
        errors.to_string() +
        " err_rate=" +
        err_rate.to_string() +
        "% services=" +
        svc_counts.length().to_string(),
      )
      match qfield {
        Some(qf) => {
          println("latency trend (" + bytes_to_string(qf) + ", p95 bars):")
          for label in labels {
            let lat = sorted_latency(bucket_lat.get(label))
            let n = lat.length()
            if n > 0 {
              let p95 = pct_of(lat, 0.95)
              let bars = if max_p95 > 0.0 {
                (p95 * 40.0 / max_p95).to_int()
              } else {
                0
              }
              let bar = {
                let sb = StringBuilder()
                let mut k = 0
                while k < bars {
                  sb.write_char('#')
                  k = k + 1
                }
                sb.to_string()
              }
              println(
                label +
                "  n=" +
                n.to_string() +
                " p50=" +
                pct_of(lat, 0.5).to_string() +
                " p95=" +
                p95.to_string() +
                " p99=" +
                pct_of(lat, 0.99).to_string() +
                " max=" +
                lat[n - 1].to_string() +
                "  |" +
                bar,
              )
            }
          }
          qvals
          .mut_view()
          .sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
          let n = qvals.length()
          if n > 0 {
            let mut sum : Double = 0.0
            for v in qvals {
              sum = sum + v
            }
            println(
              "latency (" +
              bytes_to_string(qf) +
              ", n=" +
              n.to_string() +
              "): min=" +
              qvals[0].to_string() +
              " avg=" +
              (sum / n.to_double()).to_string() +
              " p50=" +
              pct_of(qvals, 0.5).to_string() +
              " p95=" +
              pct_of(qvals, 0.95).to_string() +
              " p99=" +
              pct_of(qvals, 0.99).to_string() +
              " max=" +
              qvals[n - 1].to_string(),
            )
          } else {
            println("latency: no numeric samples")
          }
        }
        None => ()
      }
      println(
        "dimension " +
        by +
        " (top " +
        dim_top.length().to_string() +
        " of " +
        dim_total.length().to_string() +
        "):",
      )
      for item in dim_top {
        let dt = item.1
        let de = match dim_err.get(item.0) {
          Some(c) => c
          None => 0
        }
        let drate = if dt > 0 {
          de.to_double() * 100.0 / dt.to_double()
        } else {
          0.0
        }
        let dlat = sorted_latency(dim_lat.get(item.0))
        let dn = dlat.length()
        let p95 = if dn > 0 { pct_of(dlat, 0.95) } else { 0.0 }
        let bars = if max_dim > 0 {
          (dt.to_double() * 40.0 / max_dim.to_double()).to_int()
        } else {
          0
        }
        let bar = {
          let sb = StringBuilder()
          let mut k = 0
          while k < bars {
            sb.write_char('#')
            k = k + 1
          }
          sb.to_string()
        }
        let lat_part = match qfield {
          Some(_) =>
            " p95=" + p95.to_string() + (if dn > 0 { "" } else { " (n=0)" })
          None => ""
        }
        println(
          "  " +
          bytes_to_string(item.0) +
          "  total=" +
          dt.to_string() +
          " err=" +
          de.to_string() +
          " (" +
          drate.to_string() +
          "%)" +
          lat_part +
          "  |" +
          bar,
        )
      }
      println(
        "(drill-down: --since/--until <ms> --bucket minute, then trend/query/context)",
      )
    }
  })
}

///|
/// Message-shaped text for NEW_PATTERN templates: prefer a message-ish field
/// (JSON flattened or KV), so volatile siblings (trace_id, latency, level)
/// do not split one error shape into many templates; fall back to the raw
/// value when no such field exists (plain-line logs keep their old shape).
fn anomaly_error_text(
  rec : @core.Record,
  fields : Array[(Bytes, Bytes)],
) -> Bytes {
  // JSON values carry whole message fields (a KV `msg=...` would stop at the
  // first space, collapsing distinct errors to one word), so only JSON is
  // reduced to its message; KV/plain lines keep the previous whole-value
  // template semantics.
  if rec.value.length() > 0 && rec.value.at(0).to_int() == 123 {
    let names : Array[Bytes] = [
      b"message", b"msg", b"body", b"error", b"exception", b"reason", b"detail",
    ]
    match ctx_field_from_pairs(fields, names) {
      Some(m) => m
      None => rec.value
    }
  } else {
    rec.value
  }
}

///|
/// Ops anomaly detection (5.6, optimized): zero-rule detection over a
/// baseline period and a recent period —
/// 1. VOLUME_SPIKE: recent minute buckets whose count exceeds the baseline
///    minute-bucket distribution (mean/std, z > --sigma);
/// 2. NEW_PATTERN: error templates present in the recent period but absent
///    from the baseline (count >= --min-count), with a sample;
/// 3. SEASONAL_DEVIATION: an hour-of-day whose recent count deviates from the
///    baseline hour-of-day daily mean (Poisson approximation, z > --sigma).
/// Values accept KV text and JSON objects (2.1 flattening); errors are
/// severity rank >= 3 from a recognized level field (case-insensitive), or —
/// only when no level field exists — a literal "error" substring, so JSON
/// INFO messages mentioning "error" no longer become false patterns.
/// `--since/--until` select the recent window in absolute event time (the
/// baseline is the same-length period immediately before it) for
/// retrospective triage; without them the window is [now-recent, now].
/// `--service` scopes all three detectors (key or schema service field,
/// case-insensitive). Uses the 4.6 query slot/timeout/scan budget, a snapshot
/// read and segment min_ts/max_ts pushdown, so a long pass cannot stall
/// ingestion.
fn cmd_anomalies(
  dir : String,
  baseline_sec : String,
  recent_sec : String,
  sigma : String,
  min_count : String,
  top : String,
  service : String?,
  since : String?,
  until : String?,
  json : Bool,
) -> Unit raise @io.IoError {
  let scope = active_scope(dir)
  let base_ms = (@string.parse_int64(baseline_sec) catch {
      _ => raise @io.IoError::Invalid("invalid baseline: " + baseline_sec)
    }) *
    (1000 : Int64)
  let rec_ms = (@string.parse_int64(recent_sec) catch {
      _ => raise @io.IoError::Invalid("invalid recent: " + recent_sec)
    }) *
    (1000 : Int64)
  if base_ms <= 0 || rec_ms <= 0 {
    raise @io.IoError::Invalid("baseline/recent must be positive")
  }
  let sigma_v = @string.parse_double(sigma) catch {
    _ => raise @io.IoError::Invalid("invalid sigma: " + sigma)
  }
  let min_cnt = @string.parse_int(min_count) catch {
    _ => raise @io.IoError::Invalid("invalid min-count: " + min_count)
  }
  let top_n = @string.parse_int(top) catch {
    _ => raise @io.IoError::Invalid("invalid top: " + top)
  }
  if min_cnt <= 0 {
    raise @io.IoError::Invalid("min-count must be positive")
  }
  if top_n <= 0 {
    raise @io.IoError::Invalid("top must be positive")
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
  let now = now_ms()
  let recent_end = match until_ts {
    Some(u) => u
    None => now
  }
  let recent_start = match since_ts {
    Some(s) => s
    None => recent_end - rec_ms
  }
  if recent_start < (0 : Int64) || recent_end <= recent_start {
    raise @io.IoError::Invalid("recent window is empty (check --since/--until)")
  }
  let base_end = recent_start
  let base_start = recent_start - base_ms
  let service_b : Bytes? = match service {
    Some(sv) => Some(@utf8.encode(sv))
    None => None
  }
  let level_names : Array[Bytes] = [
    b"level", b"severity", b"severity_text", b"lvl", b"loglevel", b"log.level",
  ]
  let service_names : Array[Bytes] = [
    b"service", b"service.name", b"svc", b"app",
  ]
  // 4.6 production guards: slot/guard + snapshot read, outside the writer lock.
  // Ensure the directory first: slot lookup on a missing path masquerades as
  // "too many concurrent queries" on a fresh inspection target.
  ignore(@backend_native.ensure_dir(dir))
  acquire_query_slot(dir)
  acquire_tenant_query_quota(dir)
  let qg : QueryGuard = {
    t0: now_ms(),
    timeout: query_timeout_ms(),
    budget: max_scan_bytes(),
    scanned: 0,
    segs: 0,
  }
  run_read_snapshot(dir, log => {
    // Accumulators per period.
    let base_min : @hashmap.HashMap[String, Int32] = @hashmap.HashMap::HashMap([])
    let rec_min : @hashmap.HashMap[String, Int32] = @hashmap.HashMap::HashMap([])
    let base_tpl : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([])
    let rec_tpl : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([])
    let base_hod : FixedArray[Int64] = FixedArray::make(24, 0)
    let rec_hod : FixedArray[Int64] = FixedArray::make(24, 0)
    let samples : @hashmap.HashMap[Bytes, Bytes] = @hashmap.HashMap::HashMap([])
    let mut base_total = 0
    let mut rec_total = 0
    let mut base_errors = 0
    let mut rec_errors = 0
    let mut aborted : String? = None
    for seg in log.segments {
      if aborted is Some(_) {
        break
      }
      if seg.record_count > 0 {
        // Pushdown: skip segments disjoint from [base_start, recent_end].
        if seg.max_ts < base_start {
          continue
        }
        if seg.min_ts > recent_end {
          continue
        }
      }
      qg.check(seg.size)
      let mut seen = 0
      seg.for_each(seg.base_offset, seg.next_offset, rec => {
        seen = seen + 1
        if seen % 512 == 0 {
          match qg.check_soft(0) {
            Some(m) => aborted = Some(m)
            None => ()
          }
        }
        if aborted is Some(_) {
          return
        }
        if !scope_allows_key(scope, rec.key) {
          return
        }
        let in_recent = rec.timestamp >= recent_start &&
          rec.timestamp <= recent_end
        let in_base = rec.timestamp >= base_start &&
          rec.timestamp < recent_start
        if !in_recent && !in_base {
          return
        }
        let fields = ctx_value_fields(rec.value)
        match service_b {
          Some(sb) => {
            let svc = match ctx_field_from_pairs(fields, service_names) {
              Some(s) => s
              None => rec.key
            }
            if !ctx_name_eq(svc, sb) && !ctx_name_eq(rec.key, sb) {
              return
            }
          }
          None => ()
        }
        let level_v = ctx_field_from_pairs(fields, level_names)
        let is_err = match level_v {
          Some(l) => @core.level_rank(follow_lower_ascii(l)) >= 3
          None => match_needle(rec.value, b"error", true)
        }
        let hod = if rec.timestamp >= 0 {
          (rec.timestamp / (3600000 : Int64) % 24).to_int()
        } else {
          0
        }
        if in_recent {
          rec_total = rec_total + 1
          bump_string(rec_min, @core.format_utc(rec.timestamp, "minute"))
          if hod >= 0 && hod < 24 {
            rec_hod[hod] = rec_hod[hod] + 1
          }
          if is_err {
            rec_errors = rec_errors + 1
            let tpl = @core.normalize_log_template(
              anomaly_error_text(rec, fields),
            )
            bump_bytes(rec_tpl, tpl)
            match samples.get(tpl) {
              None => samples.set(tpl, rec.value)
              Some(_) => ()
            }
          }
        } else {
          base_total = base_total + 1
          bump_string(base_min, @core.format_utc(rec.timestamp, "minute"))
          if hod >= 0 && hod < 24 {
            base_hod[hod] = base_hod[hod] + 1
          }
          if is_err {
            base_errors = base_errors + 1
            bump_bytes(
              base_tpl,
              @core.normalize_log_template(anomaly_error_text(rec, fields)),
            )
          }
        }
      })
    }
    match aborted {
      Some(m) => raise @io.IoError::Invalid(m)
      None => ()
    }
    // Detection 1: volume spikes in recent minute buckets.
    let mut base_sum : Double = 0.0
    let mut base_n : Double = 0.0
    for k in base_min.keys() {
      match base_min.get(k) {
        Some(c) => {
          base_sum = base_sum + c.to_double()
          base_n = base_n + 1.0
        }
        None => ()
      }
    }
    let base_mean = if base_n > 0.0 { base_sum / base_n } else { 0.0 }
    let mut base_var : Double = 0.0
    for k in base_min.keys() {
      match base_min.get(k) {
        Some(c) => {
          let d = c.to_double() - base_mean
          base_var = base_var + d * d
        }
        None => ()
      }
    }
    let base_std = if base_n > 1.0 {
      sqrt_double(base_var / (base_n - 1.0))
    } else {
      0.0
    }
    let spikes : Array[(String, Int32, Double)] = []
    for k in rec_min.keys() {
      match rec_min.get(k) {
        Some(c) => {
          let z = if base_std > 0.0 {
            (c.to_double() - base_mean) / base_std
          } else {
            0.0
          }
          if z > sigma_v {
            spikes.push((k, c, z))
          }
        }
        None => ()
      }
    }
    // Stable chronological order (a burst should read top-to-bottom).
    spikes
    .mut_view()
    .sort_by(fn(a, b) { if a.0 < b.0 { -1 } else if a.0 > b.0 { 1 } else { 0 } })
    // Detection 2: new error patterns (in recent, absent from baseline).
    let news : Array[(Bytes, Int32)] = []
    for k in rec_tpl.keys() {
      match rec_tpl.get(k) {
        Some(c) =>
          if c >= min_cnt {
            match base_tpl.get(k) {
              Some(_) => ()
              None => news.push((k, c))
            }
          }
        None => ()
      }
    }
    news
    .mut_view()
    .sort_by(fn(a, b) {
      let d = b.1.compare(a.1)
      if d != 0 {
        d
      } else if a.0 < b.0 {
        -1
      } else if a.0 > b.0 {
        1
      } else {
        0
      }
    })
    // Detection 3: seasonal (hour-of-day) deviations.
    let base_days = if base_ms / (86400000 : Int64) > 0 {
      base_ms / (86400000 : Int64)
    } else {
      1
    }
    let seasonal : Array[(Int32, Int64, Double)] = []
    let mut h = 0
    while h < 24 {
      let bh = base_hod[h].to_double() / base_days.to_double()
      let rc = rec_hod[h].to_double()
      let z = if bh > 0.0 { (rc - bh) / sqrt_double(bh) } else { 0.0 }
      if z > sigma_v {
        seasonal.push((h, rec_hod[h], z))
      }
      h = h + 1
    }
    seasonal.mut_view().sort_by(fn(a, b) { a.0.compare(b.0) })
    let clip = fn(n : Int32) -> Int32 { if n > top_n { top_n } else { n } }
    if json {
      let mut s = "{\"dir\":\"" +
        json_escape_str(dir) +
        "\",\"generated_at\":" +
        now.to_string() +
        ",\"baseline_sec\":" +
        baseline_sec.to_string() +
        ",\"recent_sec\":" +
        recent_sec.to_string() +
        ",\"sigma\":" +
        sigma +
        ",\"window\":{\"baseline_start\":" +
        base_start.to_string() +
        ",\"baseline_end\":" +
        base_end.to_string() +
        ",\"recent_start\":" +
        recent_start.to_string() +
        ",\"recent_end\":" +
        recent_end.to_string() +
        "},\"counts\":{\"baseline_records\":" +
        base_total.to_string() +
        ",\"recent_records\":" +
        rec_total.to_string() +
        ",\"baseline_errors\":" +
        base_errors.to_string() +
        ",\"recent_errors\":" +
        rec_errors.to_string() +
        ",\"baseline_minute_buckets\":" +
        base_min.length().to_string() +
        ",\"baseline_days\":" +
        base_days.to_string() +
        "},\"volume_spikes\":["
      let mut first = true
      let sn = clip(spikes.length())
      for i2 in 0..<sn {
        if !first {
          s = s + ","
        }
        first = false
        s = s +
          "{\"window\":\"" +
          spikes[i2].0 +
          "\",\"count\":" +
          spikes[i2].1.to_string() +
          ",\"z\":" +
          spikes[i2].2.to_string() +
          "}"
      }
      s = s + "],\"new_patterns\":["
      first = true
      let nn = clip(news.length())
      for i2 in 0..<nn {
        if !first {
          s = s + ","
        }
        first = false
        s = s +
          "{\"template\":\"" +
          json_escape_str(bytes_to_string(news[i2].0)) +
          "\",\"count\":" +
          news[i2].1.to_string() +
          ",\"sample\":\"" +
          json_escape_str(
            bytes_to_string(
              match samples.get(news[i2].0) {
                Some(sv) => sv
                None => b""
              },
            ),
          ) +
          "\"}"
      }
      s = s + "],\"seasonal_deviations\":["
      first = true
      let sn2 = clip(seasonal.length())
      for i2 in 0..<sn2 {
        if !first {
          s = s + ","
        }
        first = false
        s = s +
          "{\"hour_utc\":" +
          seasonal[i2].0.to_string() +
          ",\"recent_count\":" +
          seasonal[i2].1.to_string() +
          ",\"z\":" +
          seasonal[i2].2.to_string() +
          "}"
      }
      s = s + "]}"
      println(s)
    } else {
      println(
        "=== anomalies: " +
        dir +
        " (baseline " +
        baseline_sec.to_string() +
        "s, recent " +
        recent_sec.to_string() +
        "s, sigma " +
        sigma +
        ") ===",
      )
      println(
        "window: baseline [" +
        @core.format_utc(base_start, "minute") +
        ", " +
        @core.format_utc(base_end, "minute") +
        ") recent [" +
        @core.format_utc(recent_start, "minute") +
        ", " +
        @core.format_utc(recent_end, "minute") +
        "]",
      )
      println(
        "counts: baseline " +
        base_total.to_string() +
        " records / " +
        base_errors.to_string() +
        " errors / " +
        base_min.length().to_string() +
        " minute buckets; recent " +
        rec_total.to_string() +
        " records / " +
        rec_errors.to_string() +
        " errors",
      )
      println("volume spikes: " + spikes.length().to_string())
      let sn = clip(spikes.length())
      for i2 in 0..<sn {
        println(
          "  " +
          spikes[i2].0 +
          "  count=" +
          spikes[i2].1.to_string() +
          "  z=" +
          spikes[i2].2.to_string(),
        )
      }
      println("new error patterns: " + news.length().to_string())
      let nn = clip(news.length())
      for i2 in 0..<nn {
        let sample = match samples.get(news[i2].0) {
          Some(sv) => bytes_to_string(sv)
          None => ""
        }
        println(
          "  " +
          news[i2].1.to_string() +
          "x  " +
          bytes_to_string(news[i2].0) +
          "  | " +
          sample,
        )
      }
      println("seasonal deviations: " + seasonal.length().to_string())
      let sn2 = clip(seasonal.length())
      for i2 in 0..<sn2 {
        let bh = base_hod[seasonal[i2].0].to_double() / base_days.to_double()
        println(
          "  hour_utc=" +
          seasonal[i2].0.to_string() +
          "  recent=" +
          seasonal[i2].1.to_string() +
          "  baseline_mean=" +
          bh.to_string() +
          "  z=" +
          seasonal[i2].2.to_string(),
        )
      }
      if spikes.length() == 0 && news.length() == 0 && seasonal.length() == 0 {
        println("no anomalies detected")
      }
      println(
        "(drill-down: --since/--until <ms> on anomalies/dashboard/query to re-run or inspect this window)",
      )
    }
  })
}

///|
/// Error clustering: normalize each matching line into a template (digit
/// runs, hex and quoted spans replaced) and count templates, so variable
/// content collapses into message shapes. `--match` (default "error") selects
/// lines (ASCII case-insensitive, key or value; an empty string matches
/// everything). `--top N` prints the N most frequent templates (default 20).
/// With `--stacks`, stack-frame lines are merged into the nearest preceding
/// matching header **regardless of `--match`** (frames rarely contain the
/// needle, so the default filter used to drop them); a non-matching header
/// closes the chain. JSON records with a `stack`/`stacktrace`/`exception`
/// field are clustered by their normalized stack (so the same stack with
/// different messages/ids collapses) and count their frame lines. Bounded by
/// `--since`/`--until` (default last 24h, `--since 0` for everything) with
/// segment pushdown; shares the 4.6 slot/guard and scans outside the writer
/// lock. `--json` emits the clusters as machine-readable JSON.
fn cluster_json_stack(value : Bytes) -> (Bytes, Int32, Bytes)? {
  if value.length() == 0 || value.at(0).to_int() != 123 {
    return None
  }
  let fields = @core.json_object_fields(value) catch { _ => return None }
  let stack_names : Array[Bytes] = [
    b"stack", b"stacktrace", b"exception", b"exceptionstacktrace", b"errorstack",
    b"errstack",
  ]
  let mut msg : Bytes? = None
  let mut stack : Bytes? = None
  for pair in fields {
    if msg is None && @core.canonical_field(pair.0) == 5 {
      msg = Some(pair.1)
    }
    if stack is None {
      for name in stack_names {
        if ctx_name_eq(pair.0, name) {
          stack = Some(pair.1)
        }
      }
    }
  }
  match stack {
    Some(s) => {
      if s.length() == 0 {
        return None
      }
      // Count frame lines; the exception-class header does not count.
      let mut frames : Int32 = 0
      let mut start = 0
      let mut i = 0
      while i <= s.length() {
        if i == s.length() || s.at(i).to_int() == 10 {
          if i > start && @core.is_stack_frame(@core.slice(s, start, i)) {
            frames = frames + 1
          }
          start = i + 1
        }
        i = i + 1
      }
      let sample = match msg {
        Some(m) => m
        None => value
      }
      Some((@core.normalize_log_template(s), frames, sample))
    }
    None => None
  }
}

///|
fn cmd_cluster(
  dir : String,
  match_text : String?,
  top : String?,
  stacks : Bool,
  json : Bool,
  since : String?,
  until : String?,
) -> Unit raise @io.IoError {
  let scope = active_scope(dir)
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
  // Time scoping + guards (5.2): same window/pushdown/slot/guard template
  // as query/search/aggregate; clustering scans outside the writer lock.
  let since_ts : Int64? = match since {
    Some(s) =>
      Some(
        @string.parse_int64(s) catch {
          _ => raise @io.IoError::Invalid("invalid since: " + s)
        },
      )
    None => {
      let win = query_window_ms()
      if !json {
        println(
          "INFO cluster scoped to the last " +
          (win / (1000 : Int64)).to_string() +
          "s (default window; pass --since to override, --since 0 for everything)",
        )
      }
      Some(now_ms() - win)
    }
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
  acquire_query_slot(dir)
  acquire_tenant_query_quota(dir)
  let qg : QueryGuard = {
    t0: now_ms(),
    timeout: query_timeout_ms(),
    budget: max_scan_bytes(),
    scanned: 0,
    segs: 0,
  }
  let counts : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([])
  let frames : @hashmap.HashMap[Bytes, Int32] = @hashmap.HashMap::HashMap([])
  let samples : @hashmap.HashMap[Bytes, Bytes] = @hashmap.HashMap::HashMap([])
  run_read_snapshot(dir, log => {
    let mut current : Bytes? = None
    let mut abort_msg : String? = None
    for seg in log.segments {
      if abort_msg is Some(_) {
        break
      }
      if seg.record_count > 0 {
        match since_ts {
          Some(t) => if seg.max_ts < t { continue }
          None => ()
        }
        match until_ts {
          Some(t) => if seg.min_ts > t { continue }
          None => ()
        }
      }
      qg.check(seg.size)
      let mut seen = 0
      seg.for_each(seg.base_offset, seg.next_offset, rec => {
        seen = seen + 1
        if seen % 512 == 0 {
          match qg.check_soft(0) {
            Some(m) => abort_msg = Some(m)
            None => ()
          }
        }
        if abort_msg is Some(_) {
          return
        }
        if !scope_allows_key(scope, rec.key) {
          return
        }
        let mut in_time = true
        match since_ts {
          Some(t) => if rec.timestamp < t { in_time = false }
          None => ()
        }
        match until_ts {
          Some(t) => if rec.timestamp > t { in_time = false }
          None => ()
        }
        if !in_time {
          return
        }
        let pass = match_needle(rec.key, needle, true) ||
          match_needle(rec.value, needle, true)
        if stacks {
          // JSON records carry their stack inline: cluster by the normalized
          // stack (same stack + different messages/ids collapses) and count
          // the frame lines inside that record.
          match cluster_json_stack(rec.value) {
            Some((tpl, fr, sample)) =>
              if pass {
                bump_bytes(counts, tpl)
                let prev = match frames.get(tpl) {
                  Some(v) => v
                  None => 0
                }
                if fr > 0 {
                  frames.set(tpl, prev + fr)
                }
                match samples.get(tpl) {
                  None => samples.set(tpl, sample)
                  Some(_) => ()
                }
              } else {
                current = None
              }
            None =>
              // Frames merge into the nearest matched header even when the
              // frame line itself does not contain the needle (the default
              // "error" filter used to drop every frame); a non-matching
              // header closes the chain.
              if @core.is_stack_frame(rec.value) {
                match current {
                  Some(k) => bump_bytes(frames, k)
                  None =>
                    bump_bytes(counts, @core.normalize_log_template(rec.value))
                }
              } else if pass {
                let tpl = @core.normalize_log_template(rec.value)
                bump_bytes(counts, tpl)
                current = Some(tpl)
                match samples.get(tpl) {
                  None => samples.set(tpl, rec.value)
                  Some(_) => ()
                }
              } else {
                current = None
              }
          }
        } else if pass {
          bump_bytes(counts, @core.normalize_log_template(rec.value))
        }
      })
    }
    match abort_msg {
      Some(m) => raise @io.IoError::Invalid(m)
      None => ()
    }
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
    let mut s = if stacks {
      "{\"mode\":\"stacks\",\"clusters\":["
    } else {
      "{\"mode\":\"templates\",\"clusters\":["
    }
    let mut first = true
    for item in shown {
      if !first {
        s = s + ","
      }
      first = false
      s = s +
        "{\"count\":" +
        item.1.to_string() +
        ",\"template\":\"" +
        json_escape_str(bytes_to_string(item.0)) +
        "\""
      if stacks {
        let fr = match frames.get(item.0) {
          Some(f) => f
          None => 0
        }
        let sample = match samples.get(item.0) {
          Some(sv) => sv
          None => b""
        }
        s = s +
          ",\"frames\":" +
          fr.to_string() +
          ",\"sample\":\"" +
          json_escape_str(bytes_to_string(sample)) +
          "\""
      }
      s = s + "}"
    }
    s = s + "],\"total\":" + counts.length().to_string() + "}"
    println(s)
  } else if stacks {
    println("count  frames  template  | sample")
    for item in shown {
      let fr = match frames.get(item.0) {
        Some(f) => f
        None => 0
      }
      let sample = match samples.get(item.0) {
        Some(sv) => bytes_to_string(sv)
        None => ""
      }
      println(
        item.1.to_string() +
        "  " +
        fr.to_string() +
        "  " +
        bytes_to_string(item.0) +
        "  | " +
        sample,
      )
    }
    println("(" + counts.length().to_string() + " clusters)")
  } else {
    println("count  template")
    for item in shown {
      println(item.1.to_string() + "  " + bytes_to_string(item.0))
    }
    println("(" + counts.length().to_string() + " templates)")
  }
}

///|
/// Trend histogram: count records per time bucket and print a text bar chart
/// in chronological order. `--bucket minute|hour|day` (default hour) selects
/// UTC granularity; `--match <text>` filters records (ASCII case-insensitive,
/// key or value); `--width N` sets the longest bar width (default 40).
/// Bounded by `--since`/`--until` (default last 24h, `--since 0` for
/// everything) with segment min_ts/max_ts pushdown; shares the 4.6 guards and
/// scans outside the writer lock.
fn cmd_trend(
  dir : String,
  bucket : String,
  match_text : String?,
  width : String?,
  since : String?,
  until : String?,
) -> Unit raise @io.IoError {
  let scope = active_scope(dir)
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
  // Time scoping and guards (5.1): the histogram is bounded by the same
  // default window as query/search and pushed down to segment min_ts/max_ts;
  // it also shares the 4.6 slot/guard and scans outside the writer lock.
  let since_ts : Int64? = match since {
    Some(s) =>
      Some(
        @string.parse_int64(s) catch {
          _ => raise @io.IoError::Invalid("invalid since: " + s)
        },
      )
    None => {
      let win = query_window_ms()
      println(
        "INFO trend scoped to the last " +
        (win / (1000 : Int64)).to_string() +
        "s (default window; pass --since to override, --since 0 for everything)",
      )
      Some(now_ms() - win)
    }
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
  acquire_query_slot(dir)
  acquire_tenant_query_quota(dir)
  let qg : QueryGuard = {
    t0: now_ms(),
    timeout: query_timeout_ms(),
    budget: max_scan_bytes(),
    scanned: 0,
    segs: 0,
  }
  run_read_snapshot(dir, log => {
    let counts : @hashmap.HashMap[String, Int32] = @hashmap.HashMap::HashMap([])
    let mut abort_msg : String? = None
    for seg in log.segments {
      if abort_msg is Some(_) {
        break
      }
      if seg.record_count > 0 {
        match since_ts {
          Some(t) => if seg.max_ts < t { continue }
          None => ()
        }
        match until_ts {
          Some(t) => if seg.min_ts > t { continue }
          None => ()
        }
      }
      qg.check(seg.size)
      let mut seen = 0
      seg.for_each(seg.base_offset, seg.next_offset, rec => {
        seen = seen + 1
        if seen % 512 == 0 {
          match qg.check_soft(0) {
            Some(m) => abort_msg = Some(m)
            None => ()
          }
        }
        if abort_msg is Some(_) {
          return
        }
        if !scope_allows_key(scope, rec.key) {
          return
        }
        let mut in_time = true
        match since_ts {
          Some(t) => if rec.timestamp < t { in_time = false }
          None => ()
        }
        match until_ts {
          Some(t) => if rec.timestamp > t { in_time = false }
          None => ()
        }
        if !in_time {
          return
        }
        let pass = match needle {
          Some(n) =>
            match_needle(rec.key, n, true) || match_needle(rec.value, n, true)
          None => true
        }
        if pass {
          bump_string(counts, @core.format_utc(rec.timestamp, bucket))
        }
      })
    }
    match abort_msg {
      Some(m) => raise @io.IoError::Invalid(m)
      None => ()
    }
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
) -> Int32 raise @io.IoError {
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
  let mut failures : Int32 = 0
  match webhook {
    Some(url) => {
      let cmd = "curl -s -m 5 -X POST -H 'Content-Type: application/json' --data " +
        @core.shell_quote(event_json) +
        " " +
        @core.shell_quote(url)
      let rc = @backend_native.run_command(cmd)
      if rc != 0 {
        failures = failures + 1
      }
    }
    None => ()
  }
  failures
}

///|
/// Fan a firing/resolved/escalated notification out to the extra channels
/// of 5.4: DingTalk and WeCom robot webhooks (their msgtype envelopes) and
/// e-mail via curl SMTP (an .eml temp file + --mail-from/--mail-rcpt/-T).
/// With `notify_dry` the delivery commands are printed instead of executed,
/// so the assembly can be verified without reaching the network; under
/// `--json` dry-run output is a JSON event (stdout stays parseable).
/// Returns the number of delivery failures (0 = every channel accepted it),
/// so the caller can expose notification reachability in its summary.
fn notify_extra(
  summary : String,
  dingtalk : String?,
  wecom : String?,
  email_to : String?,
  smtp_url : String?,
  notify_dry : Bool,
  json : Bool,
) -> Int32 raise @io.IoError {
  let mut failures : Int32 = 0
  match dingtalk {
    Some(url) => {
      let payload = "{\"msgtype\":\"text\",\"text\":{\"content\":\"" +
        json_escape_str(summary) +
        "\"}}"
      if notify_dry {
        if json {
          println(
            "{\"kind\":\"dry-run\",\"channel\":\"dingtalk\",\"url\":\"" +
            json_escape_str(url) +
            "\",\"payload\":" +
            payload +
            "}",
          )
        } else {
          println("[dry-run] dingtalk --data " + payload + " -> " + url)
        }
      } else {
        let cmd = "curl -s -m 5 -X POST -H 'Content-Type: application/json' --data " +
          @core.shell_quote(payload) +
          " " +
          @core.shell_quote(url)
        let rc = @backend_native.run_command(cmd)
        if rc != 0 {
          failures = failures + 1
        }
      }
    }
    None => ()
  }
  match wecom {
    Some(url) => {
      let payload = "{\"msgtype\":\"text\",\"content\":{\"content\":\"" +
        json_escape_str(summary) +
        "\"}}"
      if notify_dry {
        if json {
          println(
            "{\"kind\":\"dry-run\",\"channel\":\"wecom\",\"url\":\"" +
            json_escape_str(url) +
            "\",\"payload\":" +
            payload +
            "}",
          )
        } else {
          println("[dry-run] wecom --data " + payload + " -> " + url)
        }
      } else {
        let cmd = "curl -s -m 5 -X POST -H 'Content-Type: application/json' --data " +
          @core.shell_quote(payload) +
          " " +
          @core.shell_quote(url)
        let rc = @backend_native.run_command(cmd)
        if rc != 0 {
          failures = failures + 1
        }
      }
    }
    None => ()
  }
  match email_to {
    Some(to) =>
      match smtp_url {
        Some(smtp) => {
          let eml = "/tmp/moonlog_mail." + now_ms().to_string() + ".eml"
          let mail = "Subject: moonlog alert\nFrom: moonlog@localhost\nTo: " +
            to +
            "\n\n" +
            summary +
            "\n"
          @backend_native.write_file(eml, @utf8.encode(mail))
          let cmd = "curl -s -m 10 " +
            @core.shell_quote(smtp) +
            " --mail-from moonlog@localhost --mail-rcpt " +
            @core.shell_quote(to) +
            " -T " +
            @core.shell_quote(eml)
          if notify_dry {
            if json {
              println(
                "{\"kind\":\"dry-run\",\"channel\":\"email\",\"command\":\"" +
                json_escape_str(cmd) +
                "\"}",
              )
            } else {
              println("[dry-run] email " + cmd)
            }
          } else {
            let rc = @backend_native.run_command(cmd)
            if rc != 0 {
              failures = failures + 1
            }
          }
        }
        None => raise @io.IoError::Invalid("--email requires --smtp-url")
      }
    None => ()
  }
  failures
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
        ignore(dispatch_notification(event, notify_file, webhook))
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
/// Sliding-window threshold watch (5.3): continuously pull new records and
/// evaluate the trailing `--window-sec S` window every `--every <ms>` (default
/// 1000); fresh records trigger an immediate re-evaluation, so an alert fires
/// within a processing round. Two metric shapes: count mode (`--match <text>
/// --threshold N` — matching records in the window) and metric mode
/// (`--metric <field> --metric-threshold <v>` — average of the numeric field
/// over the window). Field filters and metrics read JSON values as well as
/// `k=v` (2.1 flattening); `--level-min` accepts either case and `--service`
/// matches the record key or the unified-schema service field. A
/// firing/resolved state machine keeps the alarm quiet: entering the
/// violation emits one ALERT, staying violated emits nothing, falling back
/// emits one RESOLVED — `--resolve-after N` (default 1) further requires N
/// consecutive calm evaluations and `--min-samples N` (default 1) ignores
/// windows with too few metric samples, so spikes/flapping cannot storm.
/// Events are flushed immediately (pipes/redirects see alerts in real time),
/// SIGTERM/SIGINT exits cooperatively with a summary, and `--json` keeps
/// stdout pure JSON (events and the closing summary).
/// `--once` performs a single pull+evaluate pass (for scripts and tests).
/// `--snooze-until <epoch_ms>` suppresses external delivery until that time
/// (maintenance window): transitions are still emitted/audited with
/// `"suppressed":true`, but no webhook/robot/e-mail/notify-file is contacted.
/// The closing summary reports `notified`, `notify_failures` and
/// `suppressed`, so delivery reachability is observable instead of being
/// buried in stdout warnings.
fn cmd_watch(
  dir : String,
  match_text : String,
  threshold : String,
  window_sec : String,
  metric : String?,
  metric_threshold : String?,
  level_min : String?,
  service : String?,
  every_ms : String?,
  notify_file : String?,
  webhook : String?,
  dingtalk : String?,
  wecom : String?,
  email_to : String?,
  smtp_url : String?,
  escalate_sec : String?,
  notify_dry : Bool,
  json : Bool,
  once : Bool,
  min_samples_s : String?,
  resolve_after_s : String?,
  snooze_until_s : String?,
) -> Unit raise @io.IoError {
  let threshold_n = @string.parse_int(threshold) catch {
    _ => raise @io.IoError::Invalid("invalid threshold: " + threshold)
  }
  let min_samples : Int32 = match min_samples_s {
    Some(v) =>
      @string.parse_int(v) catch {
        _ => raise @io.IoError::Invalid("invalid min-samples: " + v)
      }
    None => 1
  }
  if min_samples < 0 {
    raise @io.IoError::Invalid("min-samples must be >= 0")
  }
  let resolve_after : Int32 = match resolve_after_s {
    Some(v) =>
      @string.parse_int(v) catch {
        _ => raise @io.IoError::Invalid("invalid resolve-after: " + v)
      }
    None => 1
  }
  if resolve_after < 1 {
    raise @io.IoError::Invalid("resolve-after must be >= 1")
  }
  // Suppression window (5.4): until this epoch-ms, transitions are still
  // emitted for audit but no external channel is contacted (maintenance).
  let snooze_until : Int64 = match snooze_until_s {
    Some(v) =>
      @string.parse_int64(v) catch {
        _ => raise @io.IoError::Invalid("invalid snooze-until: " + v)
      }
    None => 0
  }
  let win_ms = (@string.parse_int64(window_sec) catch {
      _ => raise @io.IoError::Invalid("invalid window-sec: " + window_sec)
    }) *
    (1000 : Int64)
  if win_ms <= 0 {
    raise @io.IoError::Invalid("window-sec must be positive")
  }
  let match_b : Bytes? = Some(@utf8.encode(match_text))
  let metric_b : Bytes? = match metric {
    Some(m) => Some(@utf8.encode(m))
    None => None
  }
  let metric_thr : Double? = match metric_threshold {
    Some(v) =>
      Some(
        @string.parse_double(v) catch {
          _ => raise @io.IoError::Invalid("invalid metric-threshold: " + v)
        },
      )
    None => None
  }
  match (metric_b, metric_thr) {
    (Some(_), None) =>
      raise @io.IoError::Invalid("--metric requires --metric-threshold")
    (None, Some(_)) =>
      raise @io.IoError::Invalid("--metric-threshold requires --metric")
    _ => ()
  }
  let min_rank : Int32? = match level_min {
    Some(l) => {
      let r = @core.level_rank(@utf8.encode(l))
      if r < 0 {
        raise @io.IoError::Invalid("invalid level: " + l)
      }
      Some(r)
    }
    None => None
  }
  let service_b : Bytes? = match service {
    Some(sv) => Some(@utf8.encode(sv))
    None => None
  }
  let every = match every_ms {
    Some(v) =>
      @string.parse_int(v) catch {
        _ => raise @io.IoError::Invalid("invalid every: " + v)
      }
    None => 1000
  }
  let metric_mode = metric_b is Some(_)
  let win_s = (win_ms / (1000 : Int64)).to_string()
  let mut from : UInt64 = (0 : UInt64)
  let mut buf : Array[@core.Record] = []
  let mut firing = false
  let mut escalated = false
  let mut fired_at : Int64 = 0
  let esc_ms = match escalate_sec {
    Some(sv) =>
      (@string.parse_int64(sv) catch {
        _ => raise @io.IoError::Invalid("invalid escalate-sec: " + sv)
      }) *
      (1000 : Int64)
    None => 0
  }
  run_locked(dir, false, () => {
    let log = open_log(dir)
    // `--once` evaluates the data already present (from 0); the resident
    // watch starts from the current tail (performance).
    from = if once { (0 : UInt64) } else { log.next_offset() }
    close_log(log)
  })
  @backend_native.install_shutdown_handler()
  let mut evals : Int32 = 0
  let mut firings : Int32 = 0
  let mut resolutions : Int32 = 0
  let mut escalations : Int32 = 0
  let mut calm_rounds : Int32 = 0
  let mut notified : Int32 = 0
  let mut notify_failures : Int32 = 0
  let mut suppressed_events : Int32 = 0
  let mut go = true
  while go && !@backend_native.shutdown_requested() {
    // Pull new records into the window buffer.
    let mut got_new = false
    run_locked(dir, false, () => {
      let log = open_log(dir)
      let next = log.next_offset()
      if next > from {
        got_new = true
        let recs = log.scan_range(from, next)
        for rec in recs {
          buf.push(rec)
        }
        from = next
      }
      close_log(log)
    })
    // Slide the window: drop records older than the trailing bound.
    let now = now_ms()
    let suppressed = snooze_until > now
    let keep_from = now - win_ms
    let fresh : Array[@core.Record] = []
    for rec in buf {
      if rec.timestamp >= keep_from {
        fresh.push(rec)
      }
    }
    buf = fresh
    // Evaluate the predicate over the window.
    let mut count = 0
    let mut sum : Double = 0.0
    let mut samples = 0
    for rec in buf {
      let mut pass = true
      let needs_fields = match service_b {
        Some(_) => true
        None =>
          match min_rank {
            Some(_) => true
            None =>
              match metric_b {
                Some(_) => true
                None => false
              }
          }
      }
      let mut fields : Array[(Bytes, Bytes)] = []
      let mut sf_service : Bytes? = None
      let mut sf_level : Bytes? = None
      if needs_fields {
        // 5.3: live field filters/metrics read JSON values too (2.1
        // flattening), not just `k=v` pairs.
        fields = ctx_value_fields(rec.value)
        let sf = @core.schema_from_fields(fields, (0 : Int64))
        sf_service = sf.service
        sf_level = sf.level
      }
      match service_b {
        Some(sb) => {
          let mut sm = ctx_bytes_eq_ci(rec.key, sb)
          if !sm {
            sm = match sf_service {
              Some(sv) => ctx_bytes_eq_ci(sv, sb)
              None => false
            }
          }
          if !sm {
            pass = false
          }
        }
        None => ()
      }
      if pass {
        match min_rank {
          Some(r) => {
            let lr = match sf_level {
              Some(l) => @core.level_rank(follow_lower_ascii(l))
              None => -1
            }
            // Range filter requires a known level (same as query).
            if lr < 0 || lr < r {
              pass = false
            }
          }
          None => ()
        }
      }
      if pass {
        match match_b {
          Some(nb) =>
            if !match_needle(rec.key, nb, true) &&
              !match_needle(rec.value, nb, true) {
              pass = false
            }
          None => ()
        }
      }
      if pass {
        count = count + 1
        match metric_b {
          Some(mf) =>
            for pair in fields {
              if ctx_name_eq(pair.0, mf) {
                let d_opt = Some(
                  @string.parse_double(@utf8.decode_lossy(pair.1)),
                ) catch {
                  _ => None
                }
                match d_opt {
                  Some(d) => {
                    sum = sum + d
                    samples = samples + 1
                  }
                  None => ()
                }
              }
            }
          None => ()
        }
      }
    }
    // Violation check: count mode or metric-average mode.
    let metric_thr_v : Double = match metric_thr {
      Some(v) => v
      None => 0.0
    }
    let violated : Bool = match metric_b {
      Some(_) =>
        samples > 0 &&
        samples >= min_samples &&
        sum / samples.to_double() > metric_thr_v
      None => count > threshold_n
    }
    evals = evals + 1
    let cur_value : String = match metric_b {
      Some(_) => {
        let avg = if samples > 0 { sum / samples.to_double() } else { 0.0 }
        avg.to_string()
      }
      None => count.to_string()
    }
    let kind_str = if metric_mode { "metric" } else { "threshold" }
    let thr_str = match metric_thr {
      Some(v) => v.to_string()
      None => threshold_n.to_string()
    }
    let sup_json = if suppressed { ",\"suppressed\":true" } else { "" }
    // firing/resolved state machine — one notification per transition.
    // `--resolve-after N` requires N consecutive calm evaluations before
    // RESOLVED, so a flapping window cannot produce an alert storm.
    if violated {
      calm_rounds = 0
      if !firing {
        firing = true
        firings = firings + 1
        fired_at = now
        let event = "{\"kind\":\"" +
          kind_str +
          "\",\"state\":\"firing\",\"value\":" +
          cur_value +
          ",\"threshold\":" +
          thr_str +
          ",\"window_sec\":" +
          win_s +
          ",\"ts\":" +
          now.to_string() +
          sup_json +
          "}"
        if json {
          println(event)
        } else if metric_mode {
          println(
            "ALERT firing avg(" +
            bytes_to_string(
              match metric_b {
                Some(m) => m
                None => b""
              },
            ) +
            ")=" +
            cur_value +
            " over window " +
            win_s +
            "s",
          )
        } else {
          println(
            "ALERT firing count=" + cur_value + " over window " + win_s + "s",
          )
        }
        let summary = "ALERT firing " +
          kind_str +
          " value=" +
          cur_value +
          " over window " +
          win_s +
          "s"
        if suppressed {
          suppressed_events = suppressed_events + 1
          if !json {
            println("  (notification suppressed)")
          }
        } else {
          notified = notified + 1
          let fails = notify_extra(
              summary, dingtalk, wecom, email_to, smtp_url, notify_dry, json,
            ) +
            dispatch_notification(event, notify_file, webhook)
          if fails > 0 {
            notify_failures = notify_failures + fails
            if !json {
              println(
                "warning: " +
                fails.to_string() +
                " notification channel(s) failed",
              )
            }
          }
        }
        @backend_native.flush_stdout()
      }
    } else if firing {
      calm_rounds = calm_rounds + 1
      if calm_rounds >= resolve_after {
        firing = false
        resolutions = resolutions + 1
        calm_rounds = 0
        let event = "{\"kind\":\"" +
          kind_str +
          "\",\"state\":\"resolved\",\"value\":" +
          cur_value +
          ",\"threshold\":" +
          thr_str +
          ",\"window_sec\":" +
          win_s +
          ",\"ts\":" +
          now.to_string() +
          sup_json +
          "}"
        if json {
          println(event)
        } else {
          println("RESOLVED value=" + cur_value)
        }
        let summary = "RESOLVED " +
          kind_str +
          " value=" +
          cur_value +
          " (window " +
          win_s +
          "s)"
        if suppressed {
          suppressed_events = suppressed_events + 1
          if !json {
            println("  (notification suppressed)")
          }
        } else {
          notified = notified + 1
          let fails = notify_extra(
              summary, dingtalk, wecom, email_to, smtp_url, notify_dry, json,
            ) +
            dispatch_notification(event, notify_file, webhook)
          if fails > 0 {
            notify_failures = notify_failures + fails
            if !json {
              println(
                "warning: " +
                fails.to_string() +
                " notification channel(s) failed",
              )
            }
          }
        }
        @backend_native.flush_stdout()
      }
    }
    // Escalation (5.4): still firing after --escalate-sec -> one ESCALATED
    // notification per episode (bounded, no storm).
    if esc_ms > 0 && firing && !escalated && now - fired_at >= esc_ms {
      escalated = true
      escalations = escalations + 1
      let event = "{\"kind\":\"escalation\",\"state\":\"escalated\",\"value\":" +
        cur_value +
        ",\"elapsed_ms\":" +
        (now - fired_at).to_string() +
        ",\"ts\":" +
        now.to_string() +
        sup_json +
        "}"
      let summary = "ESCALATED " +
        kind_str +
        " value=" +
        cur_value +
        " still firing after " +
        (now - fired_at).to_string() +
        "ms"
      if json {
        println(event)
      } else {
        println(summary)
      }
      if suppressed {
        suppressed_events = suppressed_events + 1
        if !json {
          println("  (notification suppressed)")
        }
      } else {
        notified = notified + 1
        let fails = dispatch_notification(event, notify_file, webhook) +
          notify_extra(
            summary, dingtalk, wecom, email_to, smtp_url, notify_dry, json,
          )
        if fails > 0 {
          notify_failures = notify_failures + fails
          if !json {
            println(
              "warning: " +
              fails.to_string() +
              " notification channel(s) failed",
            )
          }
        }
      }
      @backend_native.flush_stdout()
    }
    if once {
      go = false
    } else if got_new {
      // Fresh records are present: re-pull/re-evaluate immediately so the
      // alert fires within a processing round instead of waiting out --every.
      @backend_native.sleep_ms(1)
    } else {
      @backend_native.sleep_ms(every)
    }
  }
  if json {
    println(
      "{\"kind\":\"summary\",\"evals\":" +
      evals.to_string() +
      ",\"firings\":" +
      firings.to_string() +
      ",\"resolved\":" +
      resolutions.to_string() +
      ",\"escalated\":" +
      escalations.to_string() +
      ",\"notified\":" +
      notified.to_string() +
      ",\"notify_failures\":" +
      notify_failures.to_string() +
      ",\"suppressed\":" +
      suppressed_events.to_string() +
      ",\"buffered\":" +
      buf.length().to_string() +
      ",\"window_sec\":" +
      win_s +
      "}",
    )
  } else {
    println(
      "(watch ended, window " +
      win_s +
      "s, buffered " +
      buf.length().to_string() +
      " records, evals " +
      evals.to_string() +
      ", firings " +
      firings.to_string() +
      ", resolved " +
      resolutions.to_string() +
      ", notified " +
      notified.to_string() +
      ", notify_failures " +
      notify_failures.to_string() +
      ", suppressed " +
      suppressed_events.to_string() +
      ")",
    )
  }
  @backend_native.flush_stdout()
}

///   watch <dir> <match-text> --threshold N [--window-sec S] [--every ms]
///            [--metric <field> --metric-threshold <v>] [--level-min <lv>]
///            [--service <svc>] [--min-samples N] [--resolve-after N]
///            [--snooze-until <ms>] [--escalate-sec S]
///            [--notify-file <f>] [--webhook <url>]
///            [--dingtalk <url>] [--wecom <url>]
///            [--email <to> --smtp-url <url>] [--notify-dry-run]
///            [--json] [--once]
///                                    sliding-window threshold watch (5.3):
///                                    re-evaluates the trailing window every
///                                    cycle; count or metric-average modes
///                                    (JSON and KV values both parsed);
///                                    firing/resolved state machine emits one
///                                    notification per transition, with
///                                    --min-samples/--resolve-after guarding
///                                    spikes and flapping (no alert storms);
///                                    --snooze-until suppresses delivery
///                                    during maintenance (events still marked
///                                    suppressed=true); the summary reports
///                                    notified/notify_failures/suppressed so
///                                    reachability is observable; fresh
///                                    records re-evaluate immediately; events
///                                    are flushed for real-time pipes;
///                                    SIGTERM/SIGINT exits with a summary

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
          ignore(dispatch_notification(event, notify_file, webhook))
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

///|
/// The data scope of the current RBAC role (6.1): None when the directory is
/// in open local mode, the role is unscoped, or the role cannot be resolved.
/// Dispatch has already rejected unmatched tokens, so a non-empty prefix here
/// is authoritative.
fn active_scope(dir : String) -> Bytes? {
  if !@backend_native.file_exists(dir + "/RBAC") {
    return None
  }
  let rules = load_rbac_rules(dir)
  let token = match @env.get_env_var("MOONLOG_TOKEN") {
    Some(t) => @utf8.encode(t)
    None => b""
  }
  match @core.rbac_find(rules, token) {
    Some(role) => role.scope
    None => None
  }
}

///|
/// Whether `key` falls inside the data scope (None = whole index).
fn scope_allows_key(scope : Bytes?, key : Bytes) -> Bool {
  match scope {
    None => true
    Some(prefix) => {
      if key.length() < prefix.length() {
        return false
      }
      let mut i = 0
      while i < prefix.length() {
        if key.at(i) != prefix.at(i) {
          return false
        }
        i = i + 1
      }
      true
    }
  }
}

///|
/// Audit a data-scope violation as a deny (6.1), so cross-project attempts are
/// attributable like command-level denials.
fn record_scope_denied(dir : String, cmd : String, key : Bytes) -> Unit {
  audit_log(dir, audit_actor(dir), cmd, "deny", "scope:" + bytes_to_string(key))
}

///|
/// Reject a key outside the current role's data scope with an explicit error
/// (6.1); the denial is audited. Used by write and single-key read paths.
fn require_scope(
  dir : String,
  cmd : String,
  key : Bytes,
) -> Unit raise @io.IoError {
  if !scope_allows_key(active_scope(dir), key) {
    record_scope_denied(dir, cmd, key)
    raise @io.IoError::Invalid(
      "permission denied: key '" +
      bytes_to_string(key) +
      "' is outside the role's data scope",
    )
  }
}

///|
/// Whole-index operations that a scoped role must not run even with `allow=*`
/// (6.1 index isolation): they copy, delete, renumber or reconfigure the whole
/// directory and would bypass the key-prefix scope.
fn global_only_cmd(cmd : String) -> Bool {
  let list : Array[String] = [
    "backup", "restore", "archive", "export", "replicate", "ha-failover", "ha-rebalance",
    "ha-watch", "drill", "recover", "compact", "compact-expired", "merge", "prune",
    "prune-bytes", "prune-before", "prune-expired", "prune-superseded", "compress",
    "tier", "import", "maintain", "ttl-expire", "purge", "fsck", "selfmon", "serve",
    "rbac", "quota",
  ]
  for c in list {
    if c == cmd {
      return true
    }
  }
  false
}

///|
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
/// Commands that leave an operation-audit trail (6.3): queries, exports,
/// destructive maintenance/deletes and configuration changes. Writes and
/// ingest are not audited — the log itself is the record — and consumer
/// cursor management is not a key operation.
let audit_cmds : Array[String] = [
  "get", "getkey", "get-many", "getkey-live", "has-key", "scan", "scan-prefix", "scan-range",
  "scan-time", "tail", "follow", "search", "query", "context", "aggregate", "cluster",
  "trend", "alert", "baseline", "dashboard", "anomalies", "watch", "cursor", "cursor-lag",
  "cursor-list", "stats", "partitions", "export", "export-jsonl", "archive", "backup",
  "drill", "purge", "delete", "prune", "prune-bytes", "prune-before", "prune-expired",
  "prune-superseded", "merge", "compact", "compact-expired", "compress", "tier",
  "ttl-expire", "restore", "recover", "maintain", "rbac", "partition-policy", "ha-failover",
  "ha-rebalance", "ha-status", "quota", "audit", "ttl-expire", "restore", "recover",
  "maintain", "rbac",
]

///|
/// Whether `cmd` belongs to the audited set (6.3).
fn audit_cmd_listed(cmd : String) -> Bool {
  for c in audit_cmds {
    if c == cmd {
      return true
    }
  }
  false
}

///|
/// Whether operation auditing (6.3) is in force for `dir`: explicitly opted
/// in by the presence of `AUDIT.log` (e.g. `touch AUDIT.log`), or implicit
/// because RBAC is in force (denials were always recorded there).
fn audit_enabled(dir : String) -> Bool {
  @backend_native.file_exists(dir + "/AUDIT") ||
  @backend_native.file_exists(dir + "/AUDIT.log") ||
  @backend_native.file_exists(dir + "/RBAC")
}

///|
/// Who is behind this invocation for audit purposes: the MOONLOG_TOKEN's
/// RBAC role when RBAC is in force (tokens themselves never land in the
/// log), `unknown` for an unmatched token, `local` in open local mode.
fn audit_actor(dir : String) -> String {
  if !@backend_native.file_exists(dir + "/RBAC") {
    return "local"
  }
  let rules = load_rbac_rules(dir)
  let token = match @env.get_env_var("MOONLOG_TOKEN") {
    Some(t) => @utf8.encode(t)
    None => b""
  }
  match @core.rbac_find(rules, token) {
    Some(r) => bytes_to_string(r.name)
    None => "unknown"
  }
}

///|
/// Compact summary of a command's arguments for the audit trail: the
/// space-joined arguments after `<dir>` (start=3), truncated to 200
/// characters. RBAC credentials never land in the log — the token of
/// `add`/`init` is masked.
fn audit_target(cmd : String, args : Array[String], start : Int32) -> String {
  let sb = StringBuilder()
  let mut i = start
  let mut first = true
  while i < args.length() {
    let masked = cmd == "rbac" &&
      args.length() > 3 &&
      ((args[3] == "add" && i == 5) || (args[3] == "init" && i == 4))
    if !first {
      sb.write_string(" ")
    }
    sb.write_string(if masked { mask_token(args[i]) } else { args[i] })
    first = false
    i = i + 1
  }
  let s = sb.to_string()
  if s.length() > 200 {
    s[0:200].to_owned() + "..."
  } else {
    s
  }
}

///|
/// The audit trail path (6.3): `<dir>/AUDIT` — deliberately without a
/// `.log` suffix, which the recovery pass would treat as a segment file and
/// truncate to zero (the 6.3 smoke caught exactly that). A legacy
/// `AUDIT.log` (M109-era denial trail) is renamed forward on first use so
/// history survives.
fn audit_path(dir : String) -> String {
  let legacy = dir + "/AUDIT.log"
  if @backend_native.file_exists(legacy) {
    ignore(@backend_native.rename_file(legacy, dir + "/AUDIT"))
  }
  dir + "/AUDIT"
}

///|
/// Append one operation-audit event to `<dir>/AUDIT` (6.3): JSONL with
/// ts/actor/action/decision/target, atomically appended (O_APPEND) so
/// concurrent CLI processes never lose events. Failures are swallowed —
/// auditing must not break the operation it observes.
fn audit_log(
  dir : String,
  actor : String,
  action : String,
  decision : String,
  target : String,
) -> Unit {
  // `rbac init` audits before cmd_rbac creates the directory; ensure_dir is
  // idempotent, so every audit path survives a not-yet-created store dir.
  ignore(@backend_native.ensure_dir(dir))
  let line = "{\"ts\":" +
    now_ms().to_string() +
    ",\"actor\":\"" +
    json_escape_str(actor) +
    "\",\"action\":\"" +
    json_escape_str(action) +
    "\",\"decision\":\"" +
    decision +
    "\",\"target\":\"" +
    json_escape_str(target) +
    "\"}\n"
  ignore(
    @backend_native.append_file(audit_path(dir), @utf8.encode(line)) catch {
      _ => ()
    },
  )
}

///|
/// Append a denial to the directory's audit log (`<dir>/AUDIT`, 6.3): the
/// actor (matched role or `unknown`) and the argument summary make denied
/// attempts attributable to a person and a time.
fn record_denied(dir : String, cmd : String, args : Array[String]) -> Unit {
  if !@backend_native.file_exists(dir + "/RBAC") {
    return
  }
  audit_log(dir, audit_actor(dir), cmd, "deny", audit_target(cmd, args, 3))
}

///|
/// Load the directory's QUOTA policy file (6.2); an empty array when the
/// file is absent (per-tenant quotas disabled). Malformed lines are skipped
/// like RBAC lines.
fn load_quota_rules(dir : String) -> Array[@core.QuotaRule] {
  if !@backend_native.file_exists(dir + "/QUOTA") {
    return []
  }
  let data = @backend_native.read_file(dir + "/QUOTA")
  let rules : Array[@core.QuotaRule] = []
  let mut start = 0
  let mut i = 0
  while i <= data.length() {
    if i == data.length() || data.at(i).to_int() == 10 {
      let line = @core.slice(data, start, i)
      if line.length() > 0 {
        match @core.parse_quota_line(line) {
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
/// The role name behind MOONLOG_TOKEN, or None when the directory has no
/// RBAC file (open local mode) or the token matches no role.
fn current_role(dir : String) -> Bytes? {
  if !@backend_native.file_exists(dir + "/RBAC") {
    return None
  }
  let rules = load_rbac_rules(dir)
  let token = match @env.get_env_var("MOONLOG_TOKEN") {
    Some(t) => @utf8.encode(t)
    None => b""
  }
  match @core.rbac_find(rules, token) {
    Some(role) => Some(role.name)
    None => None
  }
}

///|
/// The quota rule governing this invocation: the MOONLOG_TOKEN role's rule,
/// else the reserved `default` rule, else None (no QUOTA file or no
/// applicable rule).
fn active_quota_rule(dir : String) -> @core.QuotaRule? {
  let rules = load_quota_rules(dir)
  if rules.length() == 0 {
    return None
  }
  let role = match current_role(dir) {
    Some(r) => r
    None => b""
  }
  @core.quota_for_role(rules, role)
}

///|
/// Filesystem-safe rendering of a role name for QUOTA_STATE and lock file
/// names: ASCII letters/digits and `-_.` pass through, everything else
/// (including `/`, which could escape the directory) becomes `_`; an empty
/// name becomes `_`.
fn sanitize_role_name(role : Bytes) -> String {
  let raw = bytes_to_string(role)
  let sb = StringBuilder()
  for ch in raw {
    let c = ch.to_int()
    if (c >= 48 && c <= 57) ||
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      c == 45 ||
      c == 95 ||
      c == 46 {
      sb.write_char(ch)
    } else {
      sb.write_char('_')
    }
  }
  let out = sb.to_string()
  if out.length() == 0 {
    "_"
  } else {
    out
  }
}

///|
/// Total bytes of segment data files (`*.log`) in `dir` — the measure the
/// storage quota caps (6.2), matching what `retain_max_bytes` accounts.
/// Sidecars (index/keys/inv) and control files are excluded.
fn dir_log_bytes(dir : String) -> Int64 {
  let names = @backend_native.list_dir(dir) catch { _ => [] }
  let mut total : Int64 = 0
  for name in names {
    if name.has_suffix(".log") {
      let s = @backend_native.file_size(dir + "/" + name)
      if s > 0 {
        total = total + s
      }
    }
  }
  total
}

///|
/// Quota gate (6.2): returns the violation message when appending `incoming`
/// bytes would exceed the rule's storage share or the persisted write
/// window; None means admitted (nothing is persisted yet — pair with
/// `quota_record_write` once the data is actually accepted).

///|
/// The data scope attached to `role` in the directory's RBAC file (None when
/// RBAC is absent, the role is unscoped, or the name has no rule). Quota
/// storage is measured over this prefix, so one tenant's data never consumes
/// another tenant's storage budget.
fn role_scope(dir : String, role : Bytes) -> Bytes? {
  for r in load_rbac_rules(dir) {
    if r.name == role {
      return r.scope
    }
  }
  None
}

///|
/// Ledger path for a role's tenant storage: payload bytes (key+value) of
/// records whose keys fall inside the role's data scope.
fn quota_storage_path(dir : String, r : @core.QuotaRule) -> String {
  dir + "/QUOTA_STATE/" + sanitize_role_name(r.role) + ".storage"
}

///|
/// Payload bytes of records inside `scope` (None = whole directory): the
/// tenant storage measure. Append-only versions count, so compaction and
/// `quota --recalc` reduce it; segment headers/CRC/sidecars are excluded.
fn tenant_storage_bytes(dir : String, scope : Bytes?) -> Int64 {
  let log = open_log(dir) catch { _ => return 0 }
  let mut total : Int64 = 0
  ignore(
    log.for_each_while((0 : UInt64), log.next_offset(), rec => {
      if scope_allows_key(scope, rec.key) {
        total = total + (rec.key.length() + rec.value.length()).to_int64()
      }
      true
    }) catch {
      _ => ()
    },
  )
  close_log(log)
  total
}

///|
/// Current tenant storage usage from the persisted ledger; when the ledger is
/// missing (first write after enabling storage-bytes) the scope is scanned
/// once and the result is written back, so later writes stay O(1).
fn quota_storage_used(dir : String, r : @core.QuotaRule) -> Int64 {
  let path = quota_storage_path(dir, r)
  let data = @backend_native.read_file(path)
  let mut ledger : Int64 = -1
  if data.length() > 0 {
    for pair in @core.parse_kv_pairs(data) {
      if pair.0 == b"bytes" {
        let v = @string.parse_int64(@utf8.decode_lossy(pair.1)) catch {
          _ => -1
        }
        if v >= (0 : Int64) {
          ledger = v
        }
      }
    }
  }
  if ledger >= 0 {
    return ledger
  }
  let used = tenant_storage_bytes(dir, role_scope(dir, r.role))
  ignore(@backend_native.ensure_dir(dir + "/QUOTA_STATE"))
  ignore(
    @backend_native.write_file(path, @utf8.encode("bytes=" + used.to_string())) catch {
      _ => ()
    },
  )
  used
}

///|

///|
/// Recompute storage ledgers without printing (after compaction/expiry, so a
/// spent ledger does not keep rejecting writes until the next manual recalc).
fn quota_recalc_storage_quiet(dir : String) -> Unit {
  let rules = load_quota_rules(dir)
  for r in rules {
    if r.storage_bytes >= 0 {
      let used = tenant_storage_bytes(dir, role_scope(dir, r.role))
      ignore(@backend_native.ensure_dir(dir + "/QUOTA_STATE"))
      ignore(
        @backend_native.write_file(
          quota_storage_path(dir, r),
          @utf8.encode("bytes=" + used.to_string()),
        ) catch {
          _ => ()
        },
      )
    }
  }
}

///|
fn quota_recalc_storage(dir : String) -> Unit {
  let rules = load_quota_rules(dir)
  for r in rules {
    if r.storage_bytes >= 0 {
      let used = tenant_storage_bytes(dir, role_scope(dir, r.role))
      ignore(@backend_native.ensure_dir(dir + "/QUOTA_STATE"))
      ignore(
        @backend_native.write_file(
          quota_storage_path(dir, r),
          @utf8.encode("bytes=" + used.to_string()),
        ) catch {
          _ => ()
        },
      )
      println(
        "storage recalculated for role '" +
        bytes_to_string(r.role) +
        "': " +
        used.to_string() +
        " payload bytes",
      )
    }
  }
}

///|
fn quota_write_error(
  dir : String,
  rule : @core.QuotaRule?,
  incoming : Int64,
) -> String? {
  let r = match rule {
    Some(r) => r
    None => return None
  }
  if r.storage_bytes >= 0 {
    let used = quota_storage_used(dir, r)
    if used + incoming > r.storage_bytes {
      audit_log(dir, bytes_to_string(r.role), "quota", "deny", "storage-bytes")
      return Some(
        "storage quota exceeded for role '" +
        bytes_to_string(r.role) +
        "': " +
        (used + incoming).to_string() +
        " > " +
        r.storage_bytes.to_string() +
        " payload bytes in scope (compact or raise storage-bytes; `quota --recalc` refreshes the ledger)",
      )
    }
  }
  if r.write_bytes >= 0 {
    let usage = quota_window_usage(dir, r)
    if !@core.quota_write_allows(usage, r.write_bytes, incoming) {
      audit_log(dir, bytes_to_string(r.role), "quota", "deny", "write-bytes")
      return Some(
        "write quota exceeded for role '" +
        bytes_to_string(r.role) +
        "': " +
        (usage.used + incoming).to_string() +
        " > " +
        r.write_bytes.to_string() +
        " bytes this window (slow down or raise write-bytes)",
      )
    }
  }
  None
}

///|
/// Current (window-reset applied) write usage for a rule's role.
fn quota_window_usage(dir : String, r : @core.QuotaRule) -> @core.QuotaUsage {
  let path = dir + "/QUOTA_STATE/" + sanitize_role_name(r.role) + ".write"
  match @core.parse_quota_usage(@backend_native.read_file(path)) {
    Some(u) => @core.quota_window_current(u, now_ms())
    None => { window_start: now_ms(), used: 0, }
  }
}

///|
/// Persist an admitted write's bytes into the role's window usage. Called
/// only after the data is accepted, so rejected requests never consume
/// budget; a spent budget survives restarts (usage lives on disk).
fn quota_record_write(
  dir : String,
  rule : @core.QuotaRule?,
  incoming : Int64,
) -> Unit raise @io.IoError {
  let r = match rule {
    Some(r) => r
    None => return
  }
  // Tenant storage ledger: append-only payload bytes inside the role's scope.
  if r.storage_bytes >= 0 {
    let used = quota_storage_used(dir, r)
    ignore(@backend_native.ensure_dir(dir + "/QUOTA_STATE"))
    @backend_native.write_file(
      quota_storage_path(dir, r),
      @utf8.encode("bytes=" + (used + incoming).to_string()),
    )
  }
  if r.write_bytes < 0 {
    return
  }
  ignore(@backend_native.ensure_dir(dir + "/QUOTA_STATE"))
  let path = dir + "/QUOTA_STATE/" + sanitize_role_name(r.role) + ".write"
  let usage = quota_window_usage(dir, r)
  let updated : @core.QuotaUsage = {
    window_start: usage.window_start,
    used: usage.used + incoming,
  }
  @backend_native.write_file(path, @core.encode_quota_usage(updated))
}

///|
fn effective_ttl_policy(
  dir : String,
  policy : @core.TtlPolicy,
) -> @core.TtlPolicy {
  let rules = load_quota_rules(dir)
  if rules.length() == 0 {
    return policy
  }
  let scopes : Array[(Bytes, Bytes)] = []
  for r in load_rbac_rules(dir) {
    match r.scope {
      Some(s) => scopes.push((r.name, s))
      None => ()
    }
  }
  let extra = @core.quota_retain_prefix_rules(rules, scopes)
  if extra.length() == 0 {
    return policy
  }
  let all : Array[(Bytes, Bytes, Int64)] = []
  for r0 in policy.rules {
    all.push(r0)
  }
  for e in extra {
    all.push(e)
  }
  { default_days: policy.default_days, rules: all, }
}

///|
/// Acquire one tenant-level query slot (6.2): a non-blocking flock on
/// `QLOCK.<role>.<i>` with `i` below the tenant's `query-concurrent` quota,
/// retried until the lock timeout, so one busy tenant fails its own queries
/// instead of occupying the whole global pool.
fn acquire_tenant_query_slot(
  dir : String,
  role : Bytes,
  limit : Int32,
) -> Unit raise @io.IoError {
  let prefix = "QLOCK." + sanitize_role_name(role) + "."
  let deadline = now_ms() + lock_timeout_ms().to_int64()
  let mut idx = 0
  while true {
    let fd = @backend_native.try_named_lock(dir, prefix + idx.to_string())
    if fd >= 0 {
      return
    }
    idx = idx + 1
    if idx >= limit {
      if now_ms() >= deadline {
        raise @io.IoError::Invalid(
          "too many concurrent queries for tenant '" +
          bytes_to_string(role) +
          "' (limit " +
          limit.to_string() +
          "); wait for one to finish or raise its query-concurrent quota",
        )
      }
      idx = 0
      @backend_native.sleep_ms(20)
    }
  }
}

///|
/// Strip an ASCII-case-insensitive `Bearer ` prefix from an Authorization
/// header value; values without the prefix pass through unchanged.

///|
/// Apply the tenant query-concurrency quota (6.2) after the global slot: a
/// role's `query-concurrent` caps its own concurrent analysis commands, so one
/// tenant cannot monopolize the shared pool. Commands without a resolved role
/// fall back to the `default` rule.
fn acquire_tenant_query_quota(dir : String) -> Unit raise @io.IoError {
  let rules = load_quota_rules(dir)
  if rules.length() == 0 {
    return
  }
  let role = match current_role(dir) {
    Some(r) => r
    None => b""
  }
  match @core.quota_for_role(rules, role) {
    Some(rule) =>
      if rule.query_concurrent > 0 {
        acquire_tenant_query_slot(dir, role, rule.query_concurrent)
      }
    None => ()
  }
}

///|
fn http_bearer_token(authorization : Bytes) -> Bytes {
  let prefix = b"Bearer "
  if authorization.length() < prefix.length() {
    return authorization
  }
  let mut i = 0
  while i < prefix.length() {
    let c = authorization.at(i).to_int()
    let p = prefix.at(i).to_int()
    let hit = c == p ||
      (c >= 65 && c <= 90 && c + 32 == p) ||
      (c >= 97 && c <= 122 && c - 32 == p)
    if !hit {
      return authorization
    }
    i = i + 1
  }
  @core.slice(authorization, prefix.length(), authorization.length())
}

///|
/// Show the directory's per-tenant quota policy (6.2) and each limited
/// role's current write-window usage. Rules are edited directly in
/// `<dir>/QUOTA`.

///|
/// Parse one AUDIT JSONL line into `(ts, actor, action, decision, target)`.
/// Malformed or incomplete lines return None (the verifier counts them).
fn audit_parse(line : String) -> (Int64, String, String, String, String)? {
  let fields = @core.json_object_fields(@utf8.encode(line)) catch {
    _ => return None
  }
  let mut ts : Int64? = None
  let mut actor : String? = None
  let mut action : String? = None
  let mut decision : String? = None
  let mut target : String? = None
  for pair in fields {
    if pair.0 == b"ts" {
      let v = @string.parse_int64(@utf8.decode_lossy(pair.1)) catch { _ => -1 }
      if v >= (0 : Int64) {
        ts = Some(v)
      }
    } else if pair.0 == b"actor" {
      actor = Some(@utf8.decode_lossy(pair.1))
    } else if pair.0 == b"action" {
      action = Some(@utf8.decode_lossy(pair.1))
    } else if pair.0 == b"decision" {
      decision = Some(@utf8.decode_lossy(pair.1))
    } else if pair.0 == b"target" {
      target = Some(@utf8.decode_lossy(pair.1))
    }
  }
  match (ts, actor, action, decision, target) {
    (Some(t), Some(a), Some(c), Some(d), Some(g)) => Some((t, a, c, d, g))
    _ => None
  }
}

///|
/// Split a file into non-empty lines (no newline retained).
fn audit_file_lines(path : String) -> Array[String] {
  let data = @backend_native.read_file(path)
  let out : Array[String] = []
  let n = data.length()
  let mut start = 0
  let mut i = 0
  while i <= n {
    if i == n || data.at(i).to_int() == 10 {
      if i > start {
        out.push(@utf8.decode_lossy(@core.slice(data, start, i)))
      }
      start = i + 1
    }
    i = i + 1
  }
  out
}

///|
/// Read AUDIT plus (with `all`) its rotated `AUDIT.N` siblings in oldest-first
/// order: the highest suffix is the oldest file, the live `AUDIT` is newest.
/// Returns the lines and the number of files read.
fn audit_read_lines(dir : String, all : Bool) -> (Array[String], Int32) {
  ignore(audit_path(dir))
  let out : Array[String] = []
  let mut files = 0
  if all {
    let names = @backend_native.list_dir(dir) catch { _ => [] }
    let rotated : Array[(Int32, String)] = []
    for n in names {
      if n.has_prefix("AUDIT.") {
        let s = @string.parse_int(n[6:n.length()].to_owned()) catch { _ => -1 }
        if s > 0 {
          rotated.push((s, n))
        }
      }
    }
    rotated.sort_by(fn(a, b) { b.0.compare(a.0) })
    for item in rotated {
      for line in audit_file_lines(dir + "/" + item.1) {
        out.push(line)
      }
      files = files + 1
    }
  }
  for line in audit_file_lines(dir + "/AUDIT") {
    out.push(line)
  }
  if @backend_native.file_exists(dir + "/AUDIT") {
    files = files + 1
  }
  (out, files)
}

///|
/// Audit trail query (6.3): filter AUDIT events by actor/action/decision and
/// event-time window, newest first. `--json` prints the original JSONL lines
/// (machine-readable), text mode renders ts/actor/action/decision/target.
/// `--all` includes rotated `AUDIT.N`; `--verify` reports valid/invalid lines
/// and the covered time range; `--rotate --keep N` moves the live file to
/// AUDIT.1 and prunes older rotations (the rotation itself is audited).
fn cmd_audit(
  dir : String,
  actor_f : String?,
  action_f : String?,
  decision_f : String?,
  since : String?,
  until : String?,
  limit : String?,
  json : Bool,
  all : Bool,
  verify : Bool,
  rotate : Bool,
  keep : String?,
) -> Unit raise @io.IoError {
  ignore(audit_path(dir))
  if rotate {
    let keep_n = match keep {
      Some(s) =>
        @string.parse_int(s) catch {
          _ => raise @io.IoError::Invalid("invalid keep: " + s)
        }
      None => 5
    }
    if keep_n < 1 {
      raise @io.IoError::Invalid("keep must be >= 1")
    }
    run_locked(dir, true, () => {
      let base = dir + "/AUDIT"
      let names = @backend_native.list_dir(dir) catch { _ => [] }
      for n in names {
        if n.has_prefix("AUDIT.") {
          let s = @string.parse_int(n[6:n.length()].to_owned()) catch {
            _ => -1
          }
          if s >= keep_n {
            ignore(@backend_native.remove_file(dir + "/" + n))
          }
        }
      }
      let mut i = keep_n - 1
      while i >= 1 {
        let from = base + "." + i.to_string()
        let to = base + "." + (i + 1).to_string()
        if @backend_native.file_exists(from) {
          ignore(@backend_native.rename_file(from, to))
        }
        i = i - 1
      }
      if @backend_native.file_exists(base) {
        ignore(@backend_native.rename_file(base, base + ".1"))
      }
      @backend_native.write_file(base, b"")
      println("rotated: AUDIT -> AUDIT.1 (keep " + keep_n.to_string() + ")")
      // The dispatch-level allow event for `audit --rotate` landed in the
      // archived file; record completion in the fresh live trail so the new
      // AUDIT is never empty after a rotation.
      audit_log(
        dir,
        audit_actor(dir),
        "audit",
        "allow",
        "rotate-complete keep=" + keep_n.to_string(),
      )
    })
    return
  }
  let limit_n = match limit {
    Some(s) =>
      @string.parse_int(s) catch {
        _ => raise @io.IoError::Invalid("invalid limit: " + s)
      }
    None => 200
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
  let (raw_lines, files) = audit_read_lines(dir, all)
  let matched : Array[(String, Int64, String, String, String, String)] = []
  let mut total = 0
  let mut valid = 0
  let mut invalid = 0
  let mut earliest : Int64 = -1
  let mut latest : Int64 = -1
  for line in raw_lines {
    total = total + 1
    match audit_parse(line) {
      Some((ts, actor, action, decision, target)) => {
        valid = valid + 1
        if earliest < 0 || ts < earliest {
          earliest = ts
        }
        if ts > latest {
          latest = ts
        }
        if !verify {
          let ok_actor = match actor_f {
            Some(a) => actor == a
            None => true
          }
          let ok_action = match action_f {
            Some(a) => action == a
            None => true
          }
          let ok_decision = match decision_f {
            Some(d) => decision == d
            None => true
          }
          let mut ok_time = true
          match since_ts {
            Some(t) => if ts < t { ok_time = false }
            None => ()
          }
          match until_ts {
            Some(t) => if ts > t { ok_time = false }
            None => ()
          }
          if ok_actor && ok_action && ok_decision && ok_time {
            matched.push((line, ts, actor, action, decision, target))
          }
        }
      }
      None => invalid = invalid + 1
    }
  }
  if verify {
    if json {
      println(
        "{\"files\":" +
        files.to_string() +
        ",\"events\":" +
        total.to_string() +
        ",\"valid\":" +
        valid.to_string() +
        ",\"invalid\":" +
        invalid.to_string() +
        ",\"earliest_ms\":" +
        earliest.to_string() +
        ",\"latest_ms\":" +
        latest.to_string() +
        "}",
      )
    } else {
      println(
        "audit verify: files=" +
        files.to_string() +
        " events=" +
        total.to_string() +
        " valid=" +
        valid.to_string() +
        " invalid=" +
        invalid.to_string() +
        " range=" +
        (if earliest >= 0 {
          @core.format_utc(earliest, "minute") +
          ".." +
          @core.format_utc(latest, "minute")
        } else {
          "empty"
        }),
      )
    }
    return
  }
  let start = if limit_n >= 0 && matched.length() > limit_n {
    matched.length() - limit_n
  } else {
    0
  }
  let mut i = matched.length() - 1
  while i >= start {
    let item = matched[i]
    if json {
      println(item.0)
    } else {
      println(
        @core.format_utc(item.1, "minute") +
        " " +
        item.1.to_string() +
        " actor=" +
        item.2 +
        " action=" +
        item.3 +
        " decision=" +
        item.4 +
        " target=" +
        item.5,
      )
    }
    i = i - 1
  }
  println(
    "(" +
    total.to_string() +
    " events, " +
    (matched.length() - start).to_string() +
    " shown" +
    (if invalid > 0 { ", invalid=" + invalid.to_string() } else { "" }) +
    (if all { ", all rotations" } else { "" }) +
    ")",
  )
}

///|
fn cmd_quota(dir : String, recalc : Bool) -> Unit {
  if recalc {
    quota_recalc_storage(dir)
  }
  let rules = load_quota_rules(dir)
  if rules.length() == 0 {
    println(
      "no quota policy: " +
      dir +
      "/QUOTA absent — per-tenant limits (write/storage/query-concurrent/retain-days) are disabled",
    )
    return
  }
  for r in rules {
    let write_s = if r.write_bytes < 0 {
      "unlimited"
    } else {
      r.write_bytes.to_string()
    }
    let storage_s = if r.storage_bytes < 0 {
      "unlimited"
    } else {
      r.storage_bytes.to_string()
    }
    let conc_s = if r.query_concurrent > 0 {
      r.query_concurrent.to_string()
    } else {
      "global-only"
    }
    let retain_s = if r.retain_days < 0 {
      "no-override"
    } else {
      r.retain_days.to_string()
    }
    let line = "role=" +
      bytes_to_string(r.role) +
      " write-bytes=" +
      write_s +
      " storage-bytes=" +
      storage_s +
      " query-concurrent=" +
      conc_s +
      " retain-days=" +
      retain_s +
      (if r.write_bytes >= 0 {
        " used=" + quota_window_usage(dir, r).used.to_string()
      } else {
        ""
      }) +
      (if r.storage_bytes >= 0 {
        " storage-used=" + quota_storage_used(dir, r).to_string()
      } else {
        ""
      })
    println(line)
  }
  println(
    "directory payload bytes (all scopes): " +
    tenant_storage_bytes(dir, (None : Bytes?)).to_string(),
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
      raise @io.IoError::Invalid(
        "usage: rbac <dir> add <name> <token> <allow> [scope=<prefix>]",
      )
    }
    let name = args[start]
    let token = args[start + 1]
    let allow = args[start + 2]
    // Optional data scope (6.1): restricts the role to keys with that prefix;
    // 6.2 also uses it to bind per-tenant retain-days overrides.
    let scope_line = if args.length() > start + 3 &&
      args[start + 3].has_prefix("scope=") {
      " " + args[start + 3]
    } else {
      ""
    }
    let path = dir + "/RBAC"
    let existing = @backend_native.read_file(path)
    @backend_native.write_file(
      path,
      existing +
      @utf8.encode(
        "role=" +
        name +
        " token=" +
        token +
        " allow=" +
        allow +
        scope_line +
        "\n",
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
        " scope=" +
        (match r.scope {
          Some(s) => bytes_to_string(s)
          None => "*"
        }) +
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
            (match r.scope {
              Some(s) => " scope=" + bytes_to_string(s)
              None => ""
            }) +
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
      if args.length() > start + 1 {
        let key = @utf8.encode(args[start + 1])
        if scope_allows_key(active_scope(dir), key) {
          println("allowed: " + command + " " + args[start + 1])
        } else {
          println("denied: " + command + " " + args[start + 1] + " (scope)")
        }
      } else {
        println("allowed: " + command)
      }
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
/// Encode `prefix` + decimal `idx` straight into a byte buffer for the write
/// benchmark: one allocation and in-place digit writes, instead of a
/// `String` concatenation plus UTF-8 re-encoding per record.
fn bench_key(prefix : Bytes, idx : Int64) -> Bytes {
  let mut digits = 1
  let mut v = idx
  while v >= (10 : Int64) {
    v = v / 10
    digits = digits + 1
  }
  let total = prefix.length() + digits
  let arr = FixedArray::make(total, b'\x00')
  arr.blit_from_bytes(0, prefix, 0, prefix.length())
  let mut n = idx
  let mut pos = total - 1
  if n == (0 : Int64) {
    arr[pos] = b'0'
  }
  while n > (0 : Int64) {
    arr[pos] = (48 + (n % 10).to_int()).to_byte()
    n = n / 10
    pos = pos - 1
  }
  arr.unsafe_reinterpret_as_bytes()
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
  warmup_str : String?,
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
  let prefix_bytes = @utf8.encode(prefix)
  // Optional warm-up: write N records before starting the clock to report
  // steady-state throughput. Default 0 times the whole load. The clock always
  // stops before the final durability flush, which is reported separately.
  let warmup_n : Int64 = match warmup_str {
    Some(s) =>
      @string.parse_int64(s) catch {
        _ => raise @io.IoError::Invalid("invalid warmup: " + s)
      }
    None => (0 : Int64)
  }
  let warmup = if warmup_n < (0 : Int64) {
    (0 : Int64)
  } else if warmup_n >= total {
    if total > (1 : Int64) {
      total - (1 : Int64)
    } else {
      (0 : Int64)
    }
  } else {
    warmup_n
  }
  let mut run_start = now_ms()
  let mut run_end = run_start
  run_locked(dir, true, () => {
    let log = @backend_native.open_log_dir(dir, ROLL_SIZE, sync~)
    let ts = now_ms()
    let mut written : Int64 = 0
    while written < warmup {
      let remaining = warmup - written
      let n = if remaining < batch_n { remaining } else { batch_n }
      let records : Array[(Bytes, Bytes, Int64)] = []
      let mut i : Int64 = 0
      while i < n {
        let idx = written + i
        records.push((bench_key(prefix_bytes, idx), value, ts + idx))
        i = i + 1
      }
      ignore(log.append_batch(records))
      written = written + n
    }
    // Persist the warm-up load before starting the clock: otherwise the final
    // flush would fold every warm-up segment's fsync into the timed window.
    log.flush()
    run_start = now_ms()
    while written < total {
      let n = if total - written < batch_n { total - written } else { batch_n }
      let records : Array[(Bytes, Bytes, Int64)] = []
      let mut i : Int64 = 0
      while i < n {
        let idx = written + i
        records.push((bench_key(prefix_bytes, idx), value, ts + idx))
        i = i + 1
      }
      ignore(log.append_batch(records))
      written = written + n
    }
    // Stop the clock before the final durability flush: that flush covers the
    // whole run (including warm-up segments), so folding it into the timed
    // window under-reports throughput, especially for a small timed window.
    run_end = now_ms()
    log.flush()
    @backend_native.flush_meta(dir, log)
    close_log(log)
  })
  let elapsed = run_end - run_start
  let flush_ms = now_ms() - run_end
  let timed_n = total - warmup
  let qps = if elapsed > (0 : Int64) {
    timed_n * 1000 / elapsed
  } else {
    timed_n * 1000
  }
  println(
    "wrote " +
    timed_n.to_string() +
    " timed records (+" +
    warmup.to_string() +
    " warm-up) in " +
    elapsed.to_string() +
    " ms (" +
    qps.to_string() +
    " records/s), final flush " +
    flush_ms.to_string() +
    " ms, batch " +
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
  // The HTTP gateway authenticates every request with a Bearer token
  // (6.1/6.2), so launching it must not require the operator to hold a
  // tenant token; otherwise a scoped store could not expose its push endpoint.
  let request_authed_gateway = cmd == "http"
  if !bootstrapping && !request_authed_gateway && !rbac_check(args[2], cmd) {
    record_denied(args[2], cmd, args)
    println(
      "permission denied: '" +
      cmd +
      "' requires MOONLOG_TOKEN with a permitted role",
    )
    return
  }
  // 6.1 index isolation: whole-index operations require an unscoped role.
  if !bootstrapping && global_only_cmd(cmd) && active_scope(args[2]) is Some(_) {
    record_scope_denied(args[2], cmd, b"<whole-index>")
    println(
      "permission denied: '" +
      cmd +
      "' is a whole-index operation and requires an unscoped role",
    )
    return
  }
  // 6.3 operation audit: queries, exports, destructive maintenance and
  // configuration changes leave an attributable allow event (actor + ts +
  // argument summary) before execution, so a failed run still shows who
  // attempted it. Enabled when AUDIT.log or RBAC exists (opt in locally by
  // touching AUDIT.log); `rbac init` always leaves a trail since it
  // bootstraps RBAC itself, `rbac check` stays a pure diagnostic.
  if cmd == "rbac" && args.length() > 3 && args[3] == "init" {
    audit_log(
      args[2],
      audit_actor(args[2]),
      cmd,
      "allow",
      audit_target(cmd, args, 3),
    )
  } else if audit_enabled(args[2]) &&
    audit_cmd_listed(cmd) &&
    !(cmd == "rbac" && args.length() > 3 && args[3] == "check") {
    audit_log(
      args[2],
      audit_actor(args[2]),
      cmd,
      "allow",
      audit_target(cmd, args, 3),
    )
  }
  if cmd == "put" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      let mut ts : String? = (None : String?)
      let mut idempotent = false
      let mut dedup_id : String? = (None : String?)
      let mut partition_str : String? = (None : String?)
      let mut i = 5
      while i < args.length() {
        if args[i] == "--ts" && i + 1 < args.length() {
          ts = Some(args[i + 1])
          i = i + 1
        } else if args[i] == "--idempotent" {
          idempotent = true
        } else if args[i] == "--dedup-id" && i + 1 < args.length() {
          dedup_id = Some(args[i + 1])
          i = i + 1
        } else if args[i] == "--partition" && i + 1 < args.length() {
          partition_str = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      let partition = match partition_str {
        Some(s) => parse_partition(s)
        None => load_partition_policy(args[2])
      }
      cmd_put(args[2], args[3], args[4], ts, idempotent, dedup_id, partition)
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
  } else if cmd == "partition-policy" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut unit : String? = (None : String?)
      let mut json = false
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--json" {
          json = true
        } else if a == "day" || a == "hour" || a == "off" {
          unit = Some(a)
        }
        i = i + 1
      }
      cmd_partition_policy(args[2], unit, json)
    }
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
    let mut match_text : String? = (None : String?)
    let mut level_min : String? = (None : String?)
    let mut service : String? = (None : String?)
    let mut flush = false
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
      } else if a == "--match" && i + 1 < args.length() {
        match_text = Some(args[i + 1])
        i = i + 1
      } else if a == "--level-min" && i + 1 < args.length() {
        level_min = Some(args[i + 1])
        i = i + 1
      } else if a == "--service" && i + 1 < args.length() {
        service = Some(args[i + 1])
        i = i + 1
      } else if a == "--flush" {
        flush = true
      } else {
        start = a
      }
      i = i + 1
    }
    cmd_follow(
      args[2],
      start,
      once,
      commit,
      json,
      name,
      match_text,
      level_min,
      service,
      flush,
    )
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
      let mut dedup_field : String? = (None : String?)
      let mut schema = false
      let mut clock_skew : String? = (None : String?)
      let mut clock_skew_field : String? = (None : String?)
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
        } else if a == "--dedup-field" && i + 1 < args.length() {
          dedup_field = Some(args[i + 1])
          i = i + 1
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
        } else if a == "--clock-skew-field" && i + 1 < args.length() {
          clock_skew_field = Some(args[i + 1])
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
        dedup_field_bytes: match dedup_field {
          Some(s) => Some(@utf8.encode(s))
          None => None
        },
        sampling,
        from_bytes,
        schema,
        clock_skew_ms: skew_ms,
        clock_skew_field_bytes: match clock_skew_field {
          Some(s) => Some(@utf8.encode(s))
          None => None
        },
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
          None => load_partition_policy(args[2])
        },
        skip_quota: false,
        sync: desired_sync(),
      }
      cmd_ingest(args[2], args[3], follow, fifo, opts, interval)
    }
  } else if cmd == "http" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut port : String? = (None : String?)
      let mut queue_cap : String? = (None : String?)
      let mut queue_bytes : String? = (None : String?)
      let mut batch : String? = (None : String?)
      let mut backlog_alert : String? = (None : String?)
      let mut format = "lines"
      let mut key = "log"
      let mut key_field = "key"
      let mut value_field = ""
      let mut ts_field : String? = (None : String?)
      let mut template : String? = (None : String?)
      let mut idempotent = false
      let mut dedup_field : String? = (None : String?)
      let mut schema = false
      let mut clock_skew : String? = (None : String?)
      let mut clock_skew_field : String? = (None : String?)
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
        } else if a == "--queue-bytes" && i + 1 < args.length() {
          queue_bytes = Some(args[i + 1])
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
        } else if a == "--dedup-field" && i + 1 < args.length() {
          dedup_field = Some(args[i + 1])
          i = i + 1
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
        } else if a == "--clock-skew-field" && i + 1 < args.length() {
          clock_skew_field = Some(args[i + 1])
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
        dedup_field_bytes: match dedup_field {
          Some(s) => Some(@utf8.encode(s))
          None => None
        },
        sampling,
        from_bytes: None,
        schema,
        clock_skew_ms: skew_ms,
        clock_skew_field_bytes: match clock_skew_field {
          Some(s) => Some(@utf8.encode(s))
          None => None
        },
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
          None => load_partition_policy(args[2])
        },
        // 6.2: the HTTP server accounts per-tenant write quota on accept.
        skip_quota: true,
        sync: @log.SyncPolicy::Batch,
      }
      cmd_http(
        args[2],
        port,
        queue_cap,
        queue_bytes,
        batch,
        backlog_alert,
        opts,
      )
    }
  } else if cmd == "parse-check" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut format = "json"
      let mut template : String? = (None : String?)
      let mut sample_n = 5
      let mut as_json = false
      let mut schema = false
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--format" && i + 1 < args.length() {
          format = args[i + 1]
          i = i + 1
        } else if a == "--template" && i + 1 < args.length() {
          template = Some(args[i + 1])
          i = i + 1
        } else if a == "--sample" && i + 1 < args.length() {
          sample_n = @string.parse_int(args[i + 1]) catch {
            _ => raise @io.IoError::Invalid("invalid sample: " + args[i + 1])
          }
          i = i + 1
        } else if a == "--json" {
          as_json = true
        } else if a == "--schema" {
          schema = true
        }
        i = i + 1
      }
      cmd_parse_check(args[2], format, template, sample_n, as_json, schema)
    }
  } else if cmd == "bench-write" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut batch : String? = (None : String?)
      let mut sync : String? = (None : String?)
      let mut warmup : String? = (None : String?)
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
        } else if a == "--warmup" && i + 1 < args.length() {
          warmup = Some(args[i + 1])
          i = i + 1
        } else if a == "--prefix" && i + 1 < args.length() {
          prefix = args[i + 1]
          i = i + 1
        }
        i = i + 1
      }
      cmd_bench_write(args[2], args[3], batch, sync, warmup, prefix)
    }
  } else if cmd == "search" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut field = "both"
      let mut ignore_case = false
      let mut inverted = false
      let mut wildcard = false
      let mut limit : String? = (None : String?)
      let mut from : String? = (None : String?)
      let mut to : String? = (None : String?)
      let mut since : String? = (None : String?)
      let mut until : String? = (None : String?)
      let mut require_time = false
      let mut timeout : String? = (None : String?)
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--ignore-case" {
          ignore_case = true
        } else if a == "--inverted" {
          inverted = true
        } else if a == "--wildcard" {
          wildcard = true
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
        } else if a == "--since" && i + 1 < args.length() {
          since = Some(args[i + 1])
          i = i + 1
        } else if a == "--until" && i + 1 < args.length() {
          until = Some(args[i + 1])
          i = i + 1
        } else if a == "--require-time" {
          require_time = true
        } else if a == "--timeout" && i + 1 < args.length() {
          timeout = Some(args[i + 1])
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
        wildcard,
        since,
        until,
        require_time,
        timeout,
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
      let mut level_min : String? = (None : String?)
      let mut level_max : String? = (None : String?)
      let mut contains : String? = (None : String?)
      let mut since : String? = (None : String?)
      let mut until : String? = (None : String?)
      let mut limit : String? = (None : String?)
      let mut indexed = false
      let mut sort_by_time = false
      let mut json = false
      let mut require_time = false
      let mut timeout : String? = (None : String?)
      let mut explain = false
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
        } else if a == "--level-min" && i + 1 < args.length() {
          level_min = Some(args[i + 1])
          i = i + 1
        } else if a == "--level-max" && i + 1 < args.length() {
          level_max = Some(args[i + 1])
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
        } else if a == "--require-time" {
          require_time = true
        } else if a == "--timeout" && i + 1 < args.length() {
          timeout = Some(args[i + 1])
          i = i + 1
        } else if a == "--json" {
          json = true
        } else if a == "--explain" {
          explain = true
        }
        i = i + 1
      }
      cmd_query(
        args[2],
        level,
        service,
        host,
        trace_id,
        level_min,
        level_max,
        contains,
        since,
        until,
        limit,
        indexed,
        sort_by_time,
        json,
        require_time,
        timeout,
        explain,
      )
    }
  } else if cmd == "context" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut before : String? = (None : String?)
      let mut after : String? = (None : String?)
      let mut trace_id : String? = (None : String?)
      let mut service : String? = (None : String?)
      let mut thread_id : String? = (None : String?)
      let mut sort_by_time = false
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--before" && i + 1 < args.length() {
          before = Some(args[i + 1])
          i = i + 1
        } else if a == "--after" && i + 1 < args.length() {
          after = Some(args[i + 1])
          i = i + 1
        } else if a == "--trace-id" && i + 1 < args.length() {
          trace_id = Some(args[i + 1])
          i = i + 1
        } else if a == "--service" && i + 1 < args.length() {
          service = Some(args[i + 1])
          i = i + 1
        } else if a == "--thread-id" && i + 1 < args.length() {
          thread_id = Some(args[i + 1])
          i = i + 1
        } else if a == "--sort-by-time" {
          sort_by_time = true
        }
        i = i + 1
      }
      cmd_context(
        args[2],
        args[3],
        before,
        after,
        trace_id,
        service,
        thread_id,
        sort_by_time,
      )
    }
  } else if cmd == "aggregate" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut by = "key"
      let mut kv_field : String? = (None : String?)
      let mut match_text : String? = (None : String?)
      let mut top : String? = (None : String?)
      let mut quantile : String? = (None : String?)
      let mut since : String? = (None : String?)
      let mut until : String? = (None : String?)
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
        } else if a == "--quantile" && i + 1 < args.length() {
          quantile = Some(args[i + 1])
          i = i + 1
        } else if a == "--match" && i + 1 < args.length() {
          match_text = Some(args[i + 1])
          i = i + 1
        } else if a == "--top" && i + 1 < args.length() {
          top = Some(args[i + 1])
          i = i + 1
        } else if a == "--since" && i + 1 < args.length() {
          since = Some(args[i + 1])
          i = i + 1
        } else if a == "--until" && i + 1 < args.length() {
          until = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_aggregate(
        args[2],
        by,
        kv_field,
        match_text,
        top,
        json,
        quantile,
        since,
        until,
      )
    }
  } else if cmd == "cluster" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut match_text : String? = (None : String?)
      let mut top : String? = (None : String?)
      let mut stacks = false
      let mut json = false
      let mut since : String? = (None : String?)
      let mut until : String? = (None : String?)
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--match" && i + 1 < args.length() {
          match_text = Some(args[i + 1])
          i = i + 1
        } else if a == "--top" && i + 1 < args.length() {
          top = Some(args[i + 1])
          i = i + 1
        } else if a == "--stacks" {
          stacks = true
        } else if a == "--json" {
          json = true
        } else if a == "--since" && i + 1 < args.length() {
          since = Some(args[i + 1])
          i = i + 1
        } else if a == "--until" && i + 1 < args.length() {
          until = Some(args[i + 1])
          i = i + 1
        } else {
          raise @io.IoError::Invalid("unknown cluster option: " + a)
        }
        i = i + 1
      }
      cmd_cluster(args[2], match_text, top, stacks, json, since, until)
    }
  } else if cmd == "trend" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut bucket = "hour"
      let mut match_text : String? = (None : String?)
      let mut width : String? = (None : String?)
      let mut since : String? = (None : String?)
      let mut until : String? = (None : String?)
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
        } else if a == "--since" && i + 1 < args.length() {
          since = Some(args[i + 1])
          i = i + 1
        } else if a == "--until" && i + 1 < args.length() {
          until = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_trend(args[2], bucket, match_text, width, since, until)
    }
  } else if cmd == "dashboard" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut last_sec = "3600"
      let mut bucket = "minute"
      let mut quantile_field : String? = (None : String?)
      let mut service : String? = (None : String?)
      let mut since : String? = (None : String?)
      let mut until : String? = (None : String?)
      let mut by = "service"
      let mut top = "5"
      let mut json = false
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--last" && i + 1 < args.length() {
          last_sec = args[i + 1]
          i = i + 1
        } else if a == "--bucket" && i + 1 < args.length() {
          bucket = args[i + 1]
          i = i + 1
        } else if a == "--quantile-field" && i + 1 < args.length() {
          quantile_field = Some(args[i + 1])
          i = i + 1
        } else if a == "--service" && i + 1 < args.length() {
          service = Some(args[i + 1])
          i = i + 1
        } else if a == "--since" && i + 1 < args.length() {
          since = Some(args[i + 1])
          i = i + 1
        } else if a == "--until" && i + 1 < args.length() {
          until = Some(args[i + 1])
          i = i + 1
        } else if a == "--by" && i + 1 < args.length() {
          by = args[i + 1]
          i = i + 1
        } else if a == "--top" && i + 1 < args.length() {
          top = args[i + 1]
          i = i + 1
        } else if a == "--json" {
          json = true
        } else {
          raise @io.IoError::Invalid("unknown dashboard option: " + a)
        }
        i = i + 1
      }
      cmd_dashboard(
        args[2],
        last_sec,
        bucket,
        quantile_field,
        service,
        since,
        until,
        by,
        top,
        json,
      )
    }
  } else if cmd == "anomalies" {
    if args.length() < 3 {
      println(USAGE)
    } else {
      let mut baseline_sec = "604800"
      let mut recent_sec = "3600"
      let mut sigma = "3"
      let mut min_count = "2"
      let mut top = "10"
      let mut service : String? = (None : String?)
      let mut since : String? = (None : String?)
      let mut until : String? = (None : String?)
      let mut json = false
      let mut i = 3
      while i < args.length() {
        let a = args[i]
        if a == "--baseline" && i + 1 < args.length() {
          baseline_sec = args[i + 1]
          i = i + 1
        } else if a == "--recent" && i + 1 < args.length() {
          recent_sec = args[i + 1]
          i = i + 1
        } else if a == "--sigma" && i + 1 < args.length() {
          sigma = args[i + 1]
          i = i + 1
        } else if a == "--min-count" && i + 1 < args.length() {
          min_count = args[i + 1]
          i = i + 1
        } else if a == "--top" && i + 1 < args.length() {
          top = args[i + 1]
          i = i + 1
        } else if a == "--service" && i + 1 < args.length() {
          service = Some(args[i + 1])
          i = i + 1
        } else if a == "--since" && i + 1 < args.length() {
          since = Some(args[i + 1])
          i = i + 1
        } else if a == "--until" && i + 1 < args.length() {
          until = Some(args[i + 1])
          i = i + 1
        } else if a == "--json" {
          json = true
        } else {
          raise @io.IoError::Invalid("unknown anomalies option: " + a)
        }
        i = i + 1
      }
      cmd_anomalies(
        args[2],
        baseline_sec,
        recent_sec,
        sigma,
        min_count,
        top,
        service,
        since,
        until,
        json,
      )
    }
  } else if cmd == "audit" {
    let mut actor_f : String? = (None : String?)
    let mut action_f : String? = (None : String?)
    let mut decision_f : String? = (None : String?)
    let mut since : String? = (None : String?)
    let mut until : String? = (None : String?)
    let mut limit : String? = (None : String?)
    let mut keep : String? = (None : String?)
    let mut json = false
    let mut all = false
    let mut verify = false
    let mut rotate = false
    let mut i = 3
    while i < args.length() {
      let a = args[i]
      if a == "--actor" && i + 1 < args.length() {
        actor_f = Some(args[i + 1])
        i = i + 1
      } else if a == "--action" && i + 1 < args.length() {
        action_f = Some(args[i + 1])
        i = i + 1
      } else if a == "--decision" && i + 1 < args.length() {
        decision_f = Some(args[i + 1])
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
      } else if a == "--keep" && i + 1 < args.length() {
        keep = Some(args[i + 1])
        i = i + 1
      } else if a == "--json" {
        json = true
      } else if a == "--all" {
        all = true
      } else if a == "--verify" {
        verify = true
      } else if a == "--rotate" {
        rotate = true
      } else {
        raise @io.IoError::Invalid("unknown audit option: " + a)
      }
      i = i + 1
    }
    cmd_audit(
      args[2],
      actor_f,
      action_f,
      decision_f,
      since,
      until,
      limit,
      json,
      all,
      verify,
      rotate,
      keep,
    )
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
  } else if cmd == "watch" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut threshold : String? = (None : String?)
      let mut window_sec : String? = (None : String?)
      let mut metric : String? = (None : String?)
      let mut metric_threshold : String? = (None : String?)
      let mut level_min : String? = (None : String?)
      let mut service : String? = (None : String?)
      let mut every_ms : String? = (None : String?)
      let mut notify_file : String? = (None : String?)
      let mut webhook : String? = (None : String?)
      let mut dingtalk : String? = (None : String?)
      let mut wecom : String? = (None : String?)
      let mut email_to : String? = (None : String?)
      let mut smtp_url : String? = (None : String?)
      let mut escalate_sec : String? = (None : String?)
      let mut min_samples_s : String? = (None : String?)
      let mut resolve_after_s : String? = (None : String?)
      let mut snooze_until_s : String? = (None : String?)
      let mut notify_dry = false
      let mut json = false
      let mut once = false
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--threshold" && i + 1 < args.length() {
          threshold = Some(args[i + 1])
          i = i + 1
        } else if a == "--window-sec" && i + 1 < args.length() {
          window_sec = Some(args[i + 1])
          i = i + 1
        } else if a == "--metric" && i + 1 < args.length() {
          metric = Some(args[i + 1])
          i = i + 1
        } else if a == "--metric-threshold" && i + 1 < args.length() {
          metric_threshold = Some(args[i + 1])
          i = i + 1
        } else if a == "--level-min" && i + 1 < args.length() {
          level_min = Some(args[i + 1])
          i = i + 1
        } else if a == "--service" && i + 1 < args.length() {
          service = Some(args[i + 1])
          i = i + 1
        } else if a == "--every" && i + 1 < args.length() {
          every_ms = Some(args[i + 1])
          i = i + 1
        } else if a == "--notify-file" && i + 1 < args.length() {
          notify_file = Some(args[i + 1])
          i = i + 1
        } else if a == "--webhook" && i + 1 < args.length() {
          webhook = Some(args[i + 1])
          i = i + 1
        } else if a == "--dingtalk" && i + 1 < args.length() {
          dingtalk = Some(args[i + 1])
          i = i + 1
        } else if a == "--wecom" && i + 1 < args.length() {
          wecom = Some(args[i + 1])
          i = i + 1
        } else if a == "--email" && i + 1 < args.length() {
          email_to = Some(args[i + 1])
          i = i + 1
        } else if a == "--smtp-url" && i + 1 < args.length() {
          smtp_url = Some(args[i + 1])
          i = i + 1
        } else if a == "--escalate-sec" && i + 1 < args.length() {
          escalate_sec = Some(args[i + 1])
          i = i + 1
        } else if a == "--min-samples" && i + 1 < args.length() {
          min_samples_s = Some(args[i + 1])
          i = i + 1
        } else if a == "--resolve-after" && i + 1 < args.length() {
          resolve_after_s = Some(args[i + 1])
          i = i + 1
        } else if a == "--snooze-until" && i + 1 < args.length() {
          snooze_until_s = Some(args[i + 1])
          i = i + 1
        } else if a == "--notify-dry-run" {
          notify_dry = true
        } else if a == "--json" {
          json = true
        } else if a == "--once" {
          once = true
        } else {
          raise @io.IoError::Invalid("unknown watch option: " + a)
        }
        i = i + 1
      }
      match threshold {
        Some(t) =>
          cmd_watch(
            args[2],
            args[3],
            t,
            match window_sec {
              Some(w) => w
              None => "5"
            },
            metric,
            metric_threshold,
            level_min,
            service,
            every_ms,
            notify_file,
            webhook,
            dingtalk,
            wecom,
            email_to,
            smtp_url,
            escalate_sec,
            notify_dry,
            json,
            once,
            min_samples_s,
            resolve_after_s,
            snooze_until_s,
          )
        None => raise @io.IoError::Invalid("watch requires --threshold")
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
      let mut json = false
      let mut i = 3
      while i < args.length() {
        if args[i] == "--dry-run" {
          dry = true
        } else if args[i] == "--json" {
          json = true
        }
        i = i + 1
      }
      cmd_ttl_expire(args[2], dry, json)
    }
  } else if cmd == "ha-failover" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut active : String? = (None : String?)
      let mut json = false
      let mut i = 4
      while i < args.length() {
        if args[i] == "--active" && i + 1 < args.length() {
          active = Some(args[i + 1])
          i = i + 1
        } else if args[i] == "--json" {
          json = true
        }
        i = i + 1
      }
      cmd_ha_failover(args[2], args[3], active, json)
    }
  } else if cmd == "ha-status" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_ha_status(args[2], args[3], args.length() > 4 && args[4] == "--json")
    }
  } else if cmd == "ha-rebalance" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_ha_rebalance(
        args[2],
        args[3],
        args.length() > 4 && args[4] == "--json",
      )
    }
  } else if cmd == "ha-watch" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      let mut active : String? = (None : String?)
      let mut interval = 1000
      let mut threshold = 3
      let mut json = false
      let mut once = false
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--active" && i + 1 < args.length() {
          active = Some(args[i + 1])
          i = i + 1
        } else if a == "--interval" && i + 1 < args.length() {
          interval = @string.parse_int(args[i + 1]) catch { _ => 1000 }
          i = i + 1
        } else if a == "--fail-threshold" && i + 1 < args.length() {
          threshold = @string.parse_int(args[i + 1]) catch { _ => 3 }
          i = i + 1
        } else if a == "--json" {
          json = true
        } else if a == "--once" {
          once = true
        }
        i = i + 1
      }
      match active {
        Some(link) =>
          cmd_ha_watch(args[2], args[3], link, interval, threshold, json, once)
        None => raise @io.IoError::Invalid("ha-watch requires --active <link>")
      }
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
  } else if cmd == "archive" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut list = false
      let mut extract = false
      let mut into : String? = (None : String?)
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--list" {
          list = true
        } else if a == "--extract" {
          extract = true
        } else if a == "--into" && i + 1 < args.length() {
          into = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_archive(args[2], args[3], list, extract, into)
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
      let mut json = false
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--dry-run" {
          dry = true
        } else if a == "--json" {
          json = true
        } else if a == "--warm" && i + 1 < args.length() {
          warm = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_tier(args[2], args[3], warm, dry, json)
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
      let mut mode = "text"
      let mut prefix : String? = (None : String?)
      let mut match_text : String? = (None : String?)
      let mut from_ts : String? = (None : String?)
      let mut until_ts : String? = (None : String?)
      let mut i = 4
      while i < args.length() {
        let a = args[i]
        if a == "--prefix" && i + 1 < args.length() {
          prefix = Some(args[i + 1])
          i = i + 1
        } else if a == "--match" && i + 1 < args.length() {
          match_text = Some(args[i + 1])
          i = i + 1
        } else if a == "--from" && i + 1 < args.length() {
          from_ts = Some(args[i + 1])
          i = i + 1
        } else if a == "--until" && i + 1 < args.length() {
          until_ts = Some(args[i + 1])
          i = i + 1
        } else if a == "text" || a == "base64" {
          mode = a
        }
        i = i + 1
      }
      cmd_export_jsonl(
        args[2],
        args[3],
        mode,
        prefix,
        match_text,
        from_ts,
        until_ts,
      )
    }
  } else if cmd == "purge" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      let mut into : String? = (None : String?)
      let mut i = 4
      while i < args.length() {
        if args[i] == "--into" && i + 1 < args.length() {
          into = Some(args[i + 1])
          i = i + 1
        }
        i = i + 1
      }
      cmd_purge(args[2], args[3], into)
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
  } else if cmd == "quota" {
    let mut recalc = false
    let mut i = 3
    while i < args.length() {
      if args[i] == "--recalc" {
        recalc = true
      } else {
        raise @io.IoError::Invalid("unknown quota option: " + args[i])
      }
      i = i + 1
    }
    cmd_quota(args[2], recalc)
  } else if cmd == "drill" {
    let keep = args.length() > 3 && args[3] == "--keep"
    cmd_drill(args[2], keep)
  } else if cmd == "selfmon" {
    let json = args.length() > 3 && args[3] == "--json"
    cmd_selfmon(args[2], json)
  } else {
    println(USAGE)
  }
}

///|
/// Record one failed command invocation for self-monitoring (6.4): the
/// events in `<dir>/SELFMON_ERRORS` feed the failure-rate gauge so the log
/// system's own breakage surfaces before user-facing breakage. Recording
/// failures are swallowed (best effort, no recursion).
fn selfmon_report_error(args : Array[String], msg : String) -> Unit {
  if args.length() < 3 {
    return
  }
  let cmd = args[1]
  if cmd == "selfmon" {
    // Self-monitoring failures are not operational failures of the store.
    return
  }
  let line = "{\"ts\":" +
    now_ms().to_string() +
    ",\"cmd\":\"" +
    json_escape_str(cmd) +
    "\",\"error\":\"" +
    json_escape_str(msg) +
    "\"}\n"
  ignore(
    @backend_native.append_file(args[2] + "/SELFMON_ERRORS", @utf8.encode(line)) catch {
      _ => ()
    },
  )
}

///|
/// Self-monitoring threshold override (`MOONLOG_SELFMON_<NAME>`, 6.4).

///|
/// Load `<dir>/SELFMON/thresholds` (`NAME=value` per line) so cron jobs can
/// pin thresholds without environment plumbing; malformed lines are ignored.
fn selfmon_load_thresholds(dir : String) -> @hashmap.HashMap[String, Int64] {
  let map : @hashmap.HashMap[String, Int64] = @hashmap.HashMap::HashMap([])
  let data = @backend_native.read_file(dir + "/SELFMON/thresholds")
  let mut start = 0
  let mut i = 0
  while i <= data.length() {
    if i == data.length() || data.at(i).to_int() == 10 {
      let line = @core.slice(data, start, i)
      if line.length() > 0 {
        for pair in @core.parse_kv_pairs(line) {
          let name = bytes_to_string(pair.0)
          let v = @string.parse_int64(@utf8.decode_lossy(pair.1)) catch {
            _ => -1
          }
          if v >= (0 : Int64) {
            map.set(name, v)
          }
        }
      }
      start = i + 1
    }
    i = i + 1
  }
  map
}

///|
/// Effective self-monitoring threshold: `MOONLOG_SELFMON_<NAME>` overrides the
/// directory file, which overrides the built-in default.
fn selfmon_threshold_cfg(
  cfg : @hashmap.HashMap[String, Int64],
  name : String,
  default : Int64,
) -> Int64 {
  match @env.get_env_var("MOONLOG_SELFMON_" + name) {
    Some(v) => @string.parse_int64(v) catch { _ => default }
    None =>
      match cfg.get(name) {
        Some(v) => v
        None => default
      }
  }
}

///|
fn selfmon_json_fields(line : Bytes) -> Array[(Bytes, Bytes)]? {
  Some(@core.json_object_fields(line)) catch {
    _ => None
  }
}

///|
/// Numeric field of a parsed JSON object as Int64, or -1 when absent.
fn selfmon_field_int64(fields : Array[(Bytes, Bytes)], key : Bytes) -> Int64 {
  for pair in fields {
    if pair.0 == key {
      return @string.parse_int64(@utf8.decode_lossy(pair.1)) catch { _ => -1 }
    }
  }
  -1
}

///|
/// String field of a parsed JSON object, or "" when absent.
fn selfmon_field_str(fields : Array[(Bytes, Bytes)], key : Bytes) -> String {
  for pair in fields {
    if pair.0 == key {
      return @utf8.decode_lossy(pair.1)
    }
  }
  ""
}

///|
/// Whether `name` is a canonical segment file (`<digits>.log`) — mirrors the
/// recovery-side rule so stray `.log` files never skew selfmon gauges.
fn selfmon_is_segment_name(name : String) -> Bool {
  if !name.has_suffix(".log") || name.length() <= 4 {
    return false
  }
  let digits = name[0:name.length() - 4].to_owned()
  for ch in digits {
    let c = ch.to_int()
    if c < 48 || c > 57 {
      return false
    }
  }
  true
}

///|
/// Count JSONL events with `ts >= since` in `path`; returns
/// (matching, total lines).

///|
/// Whether `cmd` is a query/read entry point for the failure-rate gauge.
/// Exports, deletes, configuration changes and audit queries are excluded so
/// they cannot dilute "query failure rate".
fn selfmon_is_query_cmd(cmd : String) -> Bool {
  let list : Array[String] = [
    "get", "getkey", "get-many", "getkey-live", "has-key", "scan", "scan-prefix",
    "scan-range", "scan-time", "tail", "follow", "search", "query", "context", "aggregate",
    "cluster", "trend", "alert", "baseline", "dashboard", "anomalies", "watch", "cursor-lag",
    "cursor-list", "stats", "partitions",
  ]
  for c in list {
    if c == cmd {
      return true
    }
  }
  false
}

///|
/// Window stats for audited command failures (write failures and selfmon's
/// own failures are excluded), plus the most frequent failing command — the
/// failure-rate numerator and the "what is breaking" pointer.
fn selfmon_error_stats(dir : String, since : Int64) -> (Int32, String, Int32) {
  let data = @backend_native.read_file(dir + "/SELFMON_ERRORS")
  let counts : @hashmap.HashMap[String, Int32] = @hashmap.HashMap::HashMap([])
  let mut fails = 0
  let mut start = 0
  let mut i = 0
  while i <= data.length() {
    if i == data.length() || data.at(i).to_int() == 10 {
      let line = @core.slice(data, start, i)
      if line.length() > 0 {
        match selfmon_json_fields(line) {
          Some(fields) =>
            if selfmon_field_int64(fields, b"ts") >= since {
              let cmd = selfmon_field_str(fields, b"cmd")
              if selfmon_is_query_cmd(cmd) {
                fails = fails + 1
                bump_string(counts, cmd)
              }
            }
          None => ()
        }
      }
      start = i + 1
    }
    i = i + 1
  }
  let mut top_cmd = ""
  let mut top_count = 0
  for k in counts.keys() {
    match counts.get(k) {
      Some(c) =>
        if c > top_count {
          top_cmd = k
          top_count = c
        }
      None => ()
    }
  }
  (fails, top_cmd, top_count)
}

///|
/// Window count of allowed audit events across the live trail and its
/// rotations (M172) — the failure-rate denominator. Zero when auditing is not
/// in force.
fn selfmon_audit_allows(dir : String, since : Int64) -> Int32 {
  let (lines, _) = audit_read_lines(dir, true)
  let mut allowed = 0
  for line in lines {
    match audit_parse(line) {
      Some((ts, _, action, decision, _)) =>
        if decision == "allow" && ts >= since && selfmon_is_query_cmd(action) {
          allowed = allowed + 1
        }
      None => ()
    }
  }
  allowed
}

///|
fn selfmon_newest_segment_age_ms(dir : String) -> Int64 {
  let names = @backend_native.list_dir(dir) catch { _ => [] }
  let mut newest : String? = None
  for name in names {
    if selfmon_is_segment_name(name) {
      match newest {
        Some(cur) => if name > cur { newest = Some(name) }
        None => newest = Some(name)
      }
    }
  }
  match newest {
    Some(name) => {
      let mtime = @backend_native.file_mtime_ns(dir + "/" + name)
      if mtime < 0 {
        return -1
      }
      let age = now_ms() - mtime / 1000000
      if age < 0 {
        0
      } else {
        age
      }
    }
    None => -1
  }
}

///|
/// Latest writer snapshot under `<dir>/SELFMON` (max ts across writers):
/// (writer, ts, pending, head_lag_ms, backlog_alerts); all -1/"" when no
/// writer has ever reported.

///|
/// Age (ms) of the newest event timestamp in the directory — collection
/// latency. A fresh segment mtime proves the writer is alive, but stale event
/// timestamps mean the source stopped feeding. -1 when there is no data yet.
fn selfmon_event_lag_ms(dir : String) -> Int64 {
  if !@backend_native.file_exists(dir + "/MANIFEST") {
    return -1
  }
  run_read_snapshot(dir, log => {
    let mut lag : Int64 = -1
    if log.segments.length() > 0 {
      let seg = log.segments[log.segments.length() - 1]
      if seg.record_count > 0 && seg.max_ts > (0 : Int64) {
        let age = now_ms() - seg.max_ts
        lag = if age >= 0 { age } else { 0 }
      }
    }
    lag
  }) catch {
    _ => -1
  }
}

///|
fn selfmon_latest_snapshot(
  dir : String,
) -> (String, Int64, Int64, Int64, Int64) {
  let names = @backend_native.list_dir(dir + "/SELFMON") catch { _ => [] }
  let mut best_writer = ""
  let mut best_ts : Int64 = -1
  let mut best_pending : Int64 = -1
  let mut best_lag : Int64 = -1
  let mut best_alerts : Int64 = -1
  for name in names {
    if name.has_suffix(".json") {
      let data = @backend_native.read_file(dir + "/SELFMON/" + name)
      match selfmon_json_fields(data) {
        Some(fields) => {
          let ts = selfmon_field_int64(fields, b"ts")
          if ts > best_ts {
            best_ts = ts
            best_writer = selfmon_field_str(fields, b"writer")
            best_pending = selfmon_field_int64(fields, b"pending")
            best_lag = selfmon_field_int64(fields, b"head_lag_ms")
            best_alerts = selfmon_field_int64(fields, b"backlog_alerts")
          }
        }
        None => ()
      }
    }
  }
  if best_ts < 0 {
    return ("", -1, -1, -1, -1)
  }
  (best_writer, best_ts, best_pending, best_lag, best_alerts)
}

///|
/// Self-monitoring (6.4): one independent health sweep over `dir` — disk
/// watermark, writer backlog snapshot, ingest staleness, command failure
/// rate and basic segment/manifest sanity — so the log system's own
/// failures surface before user commands break. Prints `STATUS=ok|warn|crit`
/// first (greppable by cron-style schedulers); `--json` emits the same
/// result structured. Deep on-disk verification stays with `fsck`.
fn cmd_selfmon(dir : String, json : Bool) -> Unit {
  let now = now_ms()
  let cfg = selfmon_load_thresholds(dir)
  let disk_warn = selfmon_threshold_cfg(cfg, "DISK_WARN_PCT", 80)
  let disk_crit = selfmon_threshold_cfg(cfg, "DISK_CRIT_PCT", 90)
  let backlog_warn = selfmon_threshold_cfg(cfg, "BACKLOG_WARN", 1000)
  let lag_warn = selfmon_threshold_cfg(cfg, "LAG_WARN_MS", 5000)
  let stale_warn = selfmon_threshold_cfg(cfg, "STALE_MS", 300000)
  let fails_warn = selfmon_threshold_cfg(cfg, "FAILS_WARN", 10)
  let window = selfmon_threshold_cfg(cfg, "WINDOW_MS", 300000)
  let active_window = selfmon_threshold_cfg(cfg, "ACTIVE_WINDOW_MS", 60000)
  let event_lag_warn = selfmon_threshold_cfg(cfg, "EVENT_LAG_MS", 300000)
  let fail_rate_warn = selfmon_threshold_cfg(cfg, "FAIL_RATE_WARN_PCT", 50)
  let since = now - window

  // --- disk watermark (6.4) ---
  let avail = @backend_native.fs_bytes_available(dir)
  let total = @backend_native.fs_bytes_total(dir)
  let dir_bytes = dir_log_bytes(dir)
  let mut disk_used : Int64 = -1
  if total > 0 && avail >= 0 {
    disk_used = (total - avail) * 100 / total
  }
  let mut disk_status = "ok"
  if disk_used >= disk_crit {
    disk_status = "crit"
  } else if disk_used >= disk_warn {
    disk_status = "warn"
  }

  // --- writer backlog snapshot (6.4) ---
  let (writer, snap_ts, pending, head_lag, alerts) = selfmon_latest_snapshot(
    dir,
  )
  let snapshot_present = snap_ts >= 0
  let snapshot_age = if snapshot_present { now - snap_ts } else { -1 }
  let writer_active = snapshot_present && snapshot_age <= active_window
  let writer_stale = snapshot_present && !writer_active
  // A graceful shutdown writes pending=0, so a stale snapshot with pending>0
  // means a crash left accepted-but-unwritten data behind — alert even after
  // the writer is no longer active.
  let mut backlog_status = "ok"
  if snapshot_present && (pending >= backlog_warn || head_lag >= lag_warn) {
    backlog_status = "warn"
  }

  // --- ingest staleness (6.4): an active writer whose newest segment is
  // aging past the threshold means collection stalled — alert even though
  // nothing has failed yet. ---
  let seg_age = selfmon_newest_segment_age_ms(dir)
  let mut stale_status = "ok"
  if writer_active && seg_age >= 0 && seg_age >= stale_warn {
    stale_status = "warn"
  }

  // --- collection latency (6.4): newest event age is independent of the
  // segment mtime, so a source that stops feeding is detected while the
  // writer is still alive. ---
  let event_lag = selfmon_event_lag_ms(dir)
  let mut ingest_status = "ok"
  if event_lag >= 0 && event_lag >= event_lag_warn {
    ingest_status = "warn"
  }

  // --- command failure rate (6.4) ---
  let (fails, top_error_cmd, top_error_count) = selfmon_error_stats(dir, since)
  let attempts = if audit_enabled(dir) {
    selfmon_audit_allows(dir, since)
  } else {
    0
  }
  let fail_rate : Int64 = if attempts > 0 {
    let r = fails.to_int64() * (100 : Int64) / attempts.to_int64()
    if r > (100 : Int64) {
      (100 : Int64)
    } else {
      r
    }
  } else {
    (0 : Int64)
  }
  let mut failures_status = "ok"
  if fails.to_int64() >= fails_warn ||
    (attempts > 0 && fail_rate >= fail_rate_warn) {
    failures_status = "warn"
  }

  // --- segment/manifest sanity ---
  let manifest_present = @backend_native.file_exists(dir + "/MANIFEST")
  let dir_names = @backend_native.list_dir(dir) catch { _ => [] }
  let mut segs = 0
  for name in dir_names {
    if selfmon_is_segment_name(name) {
      segs = segs + 1
    }
  }
  let mut segments_status = "ok"
  if !manifest_present && segs > 0 {
    segments_status = "warn"
  }

  let mut status = "ok"
  if disk_status == "crit" {
    status = "crit"
  } else if disk_status == "warn" ||
    backlog_status == "warn" ||
    stale_status == "warn" ||
    ingest_status == "warn" ||
    failures_status == "warn" ||
    segments_status == "warn" {
    status = "warn"
  }

  if json {
    println(
      "{\"status\":\"" +
      status +
      "\",\"window_ms\":" +
      window.to_string() +
      ",\"disk\":{\"fs_used_pct\":" +
      disk_used.to_string() +
      ",\"avail_bytes\":" +
      avail.to_string() +
      ",\"dir_bytes\":" +
      dir_bytes.to_string() +
      "},\"backlog\":{\"writer\":\"" +
      writer +
      "\",\"writer_active\":" +
      (if writer_active { "true" } else { "false" }) +
      ",\"pending\":" +
      pending.to_string() +
      ",\"head_lag_ms\":" +
      head_lag.to_string() +
      ",\"backlog_alerts\":" +
      alerts.to_string() +
      ",\"snapshot_age_ms\":" +
      snapshot_age.to_string() +
      ",\"writer_stale\":" +
      (if writer_stale { "true" } else { "false" }) +
      "},\"ingest\":{\"event_lag_ms\":" +
      event_lag.to_string() +
      ",\"status\":\"" +
      ingest_status +
      "\"},\"stale\":{\"last_data_age_ms\":" +
      seg_age.to_string() +
      "},\"failures\":{\"window_failures\":" +
      fails.to_string() +
      ",\"window_attempts\":" +
      attempts.to_string() +
      ",\"fail_rate_pct\":" +
      fail_rate.to_string() +
      ",\"top_error_cmd\":\"" +
      json_escape_str(top_error_cmd) +
      "\",\"top_error_count\":" +
      top_error_count.to_string() +
      "},\"segments\":{\"manifest\":" +
      (if manifest_present { "true" } else { "false" }) +
      ",\"count\":" +
      segs.to_string() +
      "}}",
    )
  } else {
    println("STATUS=" + status)
    println(
      "disk: fs_used_pct=" +
      disk_used.to_string() +
      " avail_bytes=" +
      avail.to_string() +
      " dir_bytes=" +
      dir_bytes.to_string() +
      " [" +
      disk_status +
      "]",
    )
    println(
      "backlog: writer=" +
      writer +
      " pending=" +
      pending.to_string() +
      " head_lag_ms=" +
      head_lag.to_string() +
      " alerts=" +
      alerts.to_string() +
      " snapshot_age_ms=" +
      snapshot_age.to_string() +
      " writer_stale=" +
      (if writer_stale { "true" } else { "false" }) +
      " [" +
      backlog_status +
      "]",
    )
    println(
      "ingest: event_lag_ms=" +
      event_lag.to_string() +
      " threshold_ms=" +
      event_lag_warn.to_string() +
      " [" +
      ingest_status +
      "]",
    )
    println(
      "stale: last_data_age_ms=" +
      seg_age.to_string() +
      " writer_active=" +
      (if writer_active { "true" } else { "false" }) +
      " [" +
      stale_status +
      "]",
    )
    println(
      "failures: window_ms=" +
      window.to_string() +
      " failures=" +
      fails.to_string() +
      " attempts=" +
      attempts.to_string() +
      " fail_rate_pct=" +
      fail_rate.to_string() +
      (if top_error_cmd != "" {
        " top=" + top_error_cmd + "x" + top_error_count.to_string()
      } else {
        ""
      }) +
      " [" +
      failures_status +
      "]",
    )
    println(
      "segments: manifest=" +
      (if manifest_present { "present" } else { "missing" }) +
      " count=" +
      segs.to_string() +
      " [" +
      segments_status +
      "]",
    )
  }
}

///|
fn main {
  let args = @env.args()
  dispatch(args) catch {
    @io.IoError::Closed => {
      println("error: io closed")
      selfmon_report_error(args, "io closed")
    }
    @io.IoError::OutOfBounds(o) => {
      println("error: out of bounds " + o.to_string())
      selfmon_report_error(args, "out of bounds " + o.to_string())
    }
    @io.IoError::Corrupt(o) => {
      println("error: corrupt at " + o.to_string())
      selfmon_report_error(args, "corrupt at " + o.to_string())
    }
    @io.IoError::Syscall(c) => {
      println("error: syscall " + c.to_string())
      selfmon_report_error(args, "syscall " + c.to_string())
    }
    @io.IoError::Invalid(m) => {
      println("error: " + m)
      // Quota rejections (6.2) are expected tenant behavior, not store
      // breakage — keep them out of the failure-rate gauge.
      if !@core.bytes_contains(@utf8.encode(m), b"quota exceeded") {
        selfmon_report_error(args, m)
      }
    }
  }
}
