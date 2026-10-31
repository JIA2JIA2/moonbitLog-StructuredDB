///|
/// Command-line front end for the append-only event log. Runs on the native
/// target with a directory of `*.log` segment files as its store.
///
/// Usage:
///   moonlog <command> <dir> [args...]
///
/// Commands:
///   put <dir> <key> <value>          append a key/value record
///   delete <dir> <key>               append a tombstone for a key
///   get <dir> <offset>               fetch one record by offset
///   scan <dir> [from] [to]           list records in [from, to)
///   recover <dir>                    open + recover, then report counts
///   prune <dir> <keep-segments>      keep only the newest segments
///   cursor <dir> <start> <limit>     poll a consumer cursor batch
///   stats <dir>                      print record/segment counts
type CliLog = @log.Log[@backend_native.NativeFileLog, @backend_native.NativeFileLog]

///|
const ROLL_SIZE : Int64 = 1_048_576

///|
const USAGE : String = "usage: moonlog <put|delete|get|scan|recover|prune|cursor|stats> <dir> [args]"

///|
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn bytes_to_string(b : Bytes) -> String {
  @utf8.decode(b) catch { _ => "<binary:" + b.length().to_string() + ">" }
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
fn open_log(dir : String) -> CliLog raise @io.IoError {
  ignore(@backend_native.ensure_dir(dir))
  @backend_native.open_log_dir(dir, ROLL_SIZE)
}

///|
fn close_log(log : CliLog) -> Unit {
  for seg in log.segments {
    seg.writer.close()
  }
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
fn cmd_put(dir : String, key : String, value : String) -> Unit raise @io.IoError {
  let log = open_log(dir)
  let off = log.append(@utf8.encode(key), @utf8.encode(value), now_ms())
  println("offset " + off.to_string())
  @backend_native.flush_meta(dir, log)
  close_log(log)
}

///|
fn cmd_delete(dir : String, key : String) -> Unit raise @io.IoError {
  let log = open_log(dir)
  let off = log.delete(@utf8.encode(key), now_ms())
  println("offset " + off.to_string())
  @backend_native.flush_meta(dir, log)
  close_log(log)
}

///|
fn cmd_get(dir : String, offset : String) -> Unit raise @io.IoError {
  let log = open_log(dir)
  let off = parse_offset(offset)
  match log.get(off) {
    Some(rec) => print_record(rec)
    None => println("not found")
  }
  close_log(log)
}

///|
fn cmd_scan(dir : String, from : String?, to : String?) -> Unit raise @io.IoError {
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
}

///|
fn cmd_recover(dir : String) -> Unit raise @io.IoError {
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
}

///|
fn cmd_prune(dir : String, keep : String) -> Unit raise @io.IoError {
  let log = open_log(dir)
  let n = parse_count(keep)
  let dropped = log.retain_last(n, seg => {
    @backend_native.remove_segment_files(dir, seg.base_offset)
    seg.writer.close()
  })
  println("dropped " + dropped.to_string())
  @backend_native.flush_meta(dir, log)
  close_log(log)
}

///|
fn cmd_cursor(dir : String, start : String, limit : String) -> Unit raise @io.IoError {
  let log = open_log(dir)
  let cur = @log.ConsumerCursor::new(parse_offset(start))
  let recs = cur.poll(log, parse_count(limit))
  for rec in recs {
    print_record(rec)
  }
  println("cursor " + cur.position().to_string())
  close_log(log)
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
  } else if cmd == "recover" || cmd == "stats" {
    cmd_recover(args[2])
  } else if cmd == "prune" {
    if args.length() < 4 {
      println(USAGE)
    } else {
      cmd_prune(args[2], args[3])
    }
  } else if cmd == "cursor" {
    if args.length() < 5 {
      println(USAGE)
    } else {
      cmd_cursor(args[2], args[3], args[4])
    }
  } else {
    println(USAGE)
  }
}

///|
fn main {
  let args = @env.args()
  try {
    dispatch(args)
  } catch {
    @io.IoError::Closed => println("error: io closed")
    @io.IoError::OutOfBounds(o) => println("error: out of bounds " + o.to_string())
    @io.IoError::Corrupt(o) => println("error: corrupt at " + o.to_string())
    @io.IoError::Syscall(c) => println("error: syscall " + c.to_string())
    @io.IoError::Invalid(m) => println("error: " + m)
  }
}