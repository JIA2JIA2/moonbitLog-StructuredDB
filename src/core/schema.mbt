///|
/// Normalize a schema field name for alias matching: ASCII lowercase with the
/// separators `.`, `-`, `_` and `@` dropped. This makes `service.name`
/// (OTel / JSON-flattened), `service-name`, `serviceName` and `SERVICE_NAME`
/// all compare as `servicename`; `@timestamp` becomes `timestamp`.
fn squash_field_name(name : Bytes) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  let mut i = 0
  while i < name.length() {
    let c = name.at(i).to_int()
    if c != 95 && c != 45 && c != 46 && c != 64 {
      if c >= 65 && c <= 90 {
        buf.write_byte((c + 32).to_byte())
      } else {
        buf.write_byte(c.to_byte())
      }
    }
    i = i + 1
  }
  buf.to_bytes()
}

///|
/// Canonical slot for a unified-schema field name (2.2): ts=0, level=1,
/// service=2, host=3, trace_id=4, message=5, other=-1. Matching squashes case
/// and separators, then accepts common aliases including OTel-style names
/// (`service.name`, `trace.id`, `host.name`, `severity_text`, `body`).
pub fn canonical_field(name : Bytes) -> Int32 {
  let s = squash_field_name(name)
  if s == b"ts" || s == b"timestamp" || s == b"time" {
    0
  } else if s == b"level" ||
    s == b"severity" ||
    s == b"severitytext" ||
    s == b"lvl" {
    1
  } else if s == b"service" ||
    s == b"servicename" ||
    s == b"app" ||
    s == b"application" ||
    s == b"svc" {
    2
  } else if s == b"host" || s == b"hostname" || s == b"node" {
    3
  } else if s == b"traceid" || s == b"trace" {
    4
  } else if s == b"message" || s == b"msg" || s == b"log" || s == b"body" {
    5
  } else {
    -1
  }
}

///|
let ts_names : Array[Bytes] = [b"ts", b"timestamp", b"time"]

///|
let level_names : Array[Bytes] = [
  b"level", b"severity", b"severitytext", b"lvl",
]

///|
let service_names : Array[Bytes] = [
  b"service", b"servicename", b"app", b"application", b"svc",
]

///|
let host_names : Array[Bytes] = [b"host", b"hostname", b"node"]

///|
let trace_names : Array[Bytes] = [b"traceid", b"trace"]

///|
let message_names : Array[Bytes] = [b"message", b"msg", b"log", b"body"]

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
/// `fallback`. Timestamps go through `normalize_ts` (any numeric precision
/// or ISO-8601 zone offset). Implemented as six independent first-match
/// lookups over the field list (no shared loop state, no mutable struct
/// fields).
pub fn schema_from_fields(
  fields : Array[(Bytes, Bytes)],
  fallback : Int64,
) -> SchemaFields {
  fn first_value(names : Array[Bytes]) -> Bytes? {
    for pair in fields {
      let s = squash_field_name(pair.0)
      for name in names {
        if s == name {
          return Some(pair.1)
        }
      }
    }
    None
  }
  let ts_opt : Int64? = match first_value(ts_names) {
    Some(v) => Some(normalize_ts(v, fallback))
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
/// ASCII case-insensitive byte equality (schema field values are compared this
/// way so `ERROR` / `Error` / `error` agree across services).
fn bytes_equal_ci(a : Bytes, b : Bytes) -> Bool {
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
/// ASCII lowercase copy (schema levels are compared case-insensitively).
fn lower_bytes_ascii(s : Bytes) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  let mut i = 0
  while i < s.length() {
    let c = s.at(i).to_int()
    if c >= 65 && c <= 90 {
      buf.write_byte((c + 32).to_byte())
    } else {
      buf.write_byte(c.to_byte())
    }
    i = i + 1
  }
  buf.to_bytes()
}

///|
/// Level equality that also treats known synonyms as equal (warn == warning,
/// case-insensitive), falling back to case-insensitive text for unknown levels.
fn level_equal(a : Bytes, b : Bytes) -> Bool {
  let ra = level_rank(lower_bytes_ascii(a))
  let rb = level_rank(lower_bytes_ascii(b))
  if ra >= 0 && rb >= 0 {
    ra == rb
  } else {
    bytes_equal_ci(a, b)
  }
}

///|
/// Unified-schema filter: every given condition must hold (AND). A None
/// condition is ignored. `service` matches the record key (schema ingest
/// stores the service name as the key) or the parsed service field;
/// `level`/`host`/`trace_id` match the parsed fields case-insensitively
/// (levels also honour warn/warning synonyms); `contains` matches the raw
/// value as a case-insensitive substring.
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
        Some(lv) => level_equal(lv, l)
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
        Some(sv) => bytes_equal_ci(sv, s)
        None => false
      }
      if !bytes_equal_ci(key, s) && !fm {
        return false
      }
    }
    None => ()
  }
  match host {
    Some(h) => {
      let fm = match f.host {
        Some(hv) => bytes_equal_ci(hv, h)
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
        Some(tv) => bytes_equal_ci(tv, t)
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
