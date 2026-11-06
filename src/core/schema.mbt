///|
/// Canonical slot for a unified-schema field name (2.2): ts=0, level=1,
/// service=2, host=3, trace_id=4, message=5, other=-1. Each slot accepts
/// common aliases (e.g. severity→level, msg→message, @timestamp→ts).
pub fn canonical_field(name : Bytes) -> Int32 {
  if name == b"ts" ||
    name == b"timestamp" ||
    name == b"time" ||
    name == b"@timestamp" {
    0
  } else if name == b"level" || name == b"severity" {
    1
  } else if name == b"service" ||
    name == b"service_name" ||
    name == b"app" ||
    name == b"application" {
    2
  } else if name == b"host" || name == b"hostname" {
    3
  } else if name == b"trace_id" || name == b"traceId" || name == b"trace" {
    4
  } else if name == b"message" || name == b"msg" {
    5
  } else {
    -1
  }
}

///|
let ts_names : Array[Bytes] = [b"ts", b"timestamp", b"time", b"@timestamp"]

///|
let level_names : Array[Bytes] = [b"level", b"severity"]

///|
let service_names : Array[Bytes] = [
  b"service", b"service_name", b"app", b"application",
]

///|
let host_names : Array[Bytes] = [b"host", b"hostname"]

///|
let trace_names : Array[Bytes] = [b"trace_id", b"traceId", b"trace"]

///|
let message_names : Array[Bytes] = [b"message", b"msg"]

///|
/// The six canonical fields extracted from a parsed field set. Absent fields
/// are None; the first pair mapping to a slot wins.
pub(all) struct SchemaFields {
  ts : Int64?
  level : Bytes?
  service : Bytes?
  host : Bytes?
  trace_id : Bytes?
  message : Bytes?
}

///|
/// Extract the six canonical fields from a parsed field set. Timestamp values
/// are parsed as epoch milliseconds; an unparsable value falls back to
/// `fallback`. Implemented as six independent first-match lookups over the
/// field list (no shared loop state, no mutable struct fields).
pub fn schema_from_fields(
  fields : Array[(Bytes, Bytes)],
  fallback : Int64,
) -> SchemaFields {
  fn first_value(names : Array[Bytes]) -> Bytes? {
    for pair in fields {
      for name in names {
        if pair.0 == name {
          return Some(pair.1)
        }
      }
    }
    None
  }
  let ts_opt : Int64? = match first_value(ts_names) {
    Some(v) =>
      Some(@string.parse_int64(@utf8.decode_lossy(v)) catch { _ => fallback })
    None => None
  }
  {
    ts: ts_opt,
    level: first_value(level_names),
    service: first_value(service_names),
    host: first_value(host_names),
    trace_id: first_value(trace_names),
    message: first_value(message_names),
  }
}

///|
/// Canonical value for a schema record: the standard fields re-serialized in
/// fixed order (level, host, trace_id, message) as a `name=value` string, so
/// every service ingested with `--schema` has the same shape. Absent fields
/// are skipped.
pub fn schema_value(f : SchemaFields) -> Bytes {
  let v = @buffer.Buffer::Buffer()
  let mut first = true
  match f.level {
    Some(l) => {
      if !first {
        v.write_bytes(b" ")
      }
      first = false
      v.write_bytes(b"level=")
      v.write_bytes(l)
    }
    None => ()
  }
  match f.host {
    Some(h) => {
      if !first {
        v.write_bytes(b" ")
      }
      first = false
      v.write_bytes(b"host=")
      v.write_bytes(h)
    }
    None => ()
  }
  match f.trace_id {
    Some(t) => {
      if !first {
        v.write_bytes(b" ")
      }
      first = false
      v.write_bytes(b"trace_id=")
      v.write_bytes(t)
    }
    None => ()
  }
  match f.message {
    Some(m) => {
      if !first {
        v.write_bytes(b" ")
      }
      first = false
      v.write_bytes(b"message=")
      v.write_bytes(m)
    }
    None => ()
  }
  v.to_bytes()
}

///|
/// Unified-schema filter: every given condition must hold (AND). A None
/// condition is ignored. `service` matches the record key (schema ingest
/// stores the service name as the key) or the parsed service field;
/// `level`/`host`/`trace_id` match the parsed fields; `contains` matches the
/// raw value as a substring.
pub fn schema_matches(
  fields : Array[(Bytes, Bytes)],
  key : Bytes,
  raw_value : Bytes,
  level : Bytes?,
  service : Bytes?,
  host : Bytes?,
  trace_id : Bytes?,
  contains : Bytes?,
) -> Bool {
  let f = schema_from_fields(fields, (0 : Int64))
  match level {
    Some(l) => {
      let fm = match f.level {
        Some(lv) => lv == l
        None => false
      }
      if !fm {
        return false
      }
    }
    None => ()
  }
  match service {
    Some(s) => {
      let fm = match f.service {
        Some(sv) => sv == s
        None => false
      }
      if key != s && !fm {
        return false
      }
    }
    None => ()
  }
  match host {
    Some(h) => {
      let fm = match f.host {
        Some(hv) => hv == h
        None => false
      }
      if !fm {
        return false
      }
    }
    None => ()
  }
  match trace_id {
    Some(t) => {
      let fm = match f.trace_id {
        Some(tv) => tv == t
        None => false
      }
      if !fm {
        return false
      }
    }
    None => ()
  }
  match contains {
    Some(c) => if !bytes_contains_ci(raw_value, c) { return false }
    None => ()
  }
  true
}
