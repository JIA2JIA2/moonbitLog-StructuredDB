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
/// and separators, accepts common aliases including OTel-style names
/// (`service.name`, `trace.id`, `host.name`, `severity_text`, `body`) and
/// container-prefixed paths (`resource.service.name`, `error.message`,
/// `log.level`, `kubernetes.labels.app`): leading segments are peeled only
/// while they are known log-pipeline containers, so `user.message` or
/// `myapp.servicename` stay unrecognized.
pub fn canonical_field(name : Bytes) -> Int32 {
  if field_name_matches(name, canonical_ts_names) {
    0
  } else if field_name_matches(name, canonical_level_names) {
    1
  } else if field_name_matches(name, service_names) {
    2
  } else if field_name_matches(name, host_names) {
    3
  } else if field_name_matches(name, trace_names) {
    4
  } else if field_name_matches(name, message_names) {
    5
  } else {
    -1
  }
}

///|
/// Event-time field spellings (2.2/2.3): OTel `timeUnixNano` and journald
/// `__REALTIME_TIMESTAMP` carry the event time like `ts`/`@timestamp`.
let ts_names : Array[Bytes] = [
  b"ts", b"timestamp", b"time", b"timeunixnano", b"realtimetimestamp",
]

///|
/// OTel observed time: a fallback timestamp source consulted only when no
/// event-time field is present.
let observed_ts_names : Array[Bytes] = [b"observedtimeunixnano"]

///|
/// Canonical lookup superset for slot resolution. Level keeps the numeric
/// OTel form so TTL rules and inverted-index slots keep working; syslog
/// `priority` is deliberately NOT a slot: its 0-7 scale collides with the
/// OTel 1-24 rank, so it only feeds the schema normalization rounds below.
let canonical_ts_names : Array[Bytes] = [
  b"ts", b"timestamp", b"time", b"timeunixnano", b"realtimetimestamp", b"observedtimeunixnano",
]

///|
let canonical_level_names : Array[Bytes] = [
  b"level", b"severity", b"severitytext", b"severitynumber", b"lvl",
]

///|
/// Level round 1: word forms always win, whatever the field order.
let level_word_names : Array[Bytes] = [
  b"level", b"severity", b"severitytext", b"lvl",
]

///|
/// Level round 2: OTel numeric severity, normalized to the word form so the
/// stored schema shape matches word-emitting services.
let level_number_names : Array[Bytes] = [b"severitynumber"]

///|
/// Level round 3: journald/syslog PRIORITY (0-7).
let priority_names : Array[Bytes] = [b"priority"]

///|
let service_names : Array[Bytes] = [
  b"service", b"servicename", b"app", b"application", b"svc", b"syslogidentifier",
]

///|
let host_names : Array[Bytes] = [b"host", b"hostname", b"node"]

///|
let trace_names : Array[Bytes] = [b"traceid", b"trace"]

///|
let message_names : Array[Bytes] = [
  b"message", b"msg", b"log", b"body", b"bodystringvalue",
]

///|
/// Log-pipeline container segments whose leading prefix is peeled when
/// resolving a field name: `resource.service.name`, `attributes.trace.id`,
/// `kubernetes.labels.app`, `error.message`, `log.level`, ...
let container_prefixes : Array[Bytes] = [
  b"resource", b"attributes", b"labels", b"fields", b"tags", b"event", b"log", b"error",
  b"record", b"metadata", b"kubernetes", b"otel",
]

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
/// ASCII-lowercase squash of `name[start, end)` (separators dropped).
fn squash_span(name : Bytes, start : Int32, end : Int32) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  let mut i = start
  while i < end {
    let c = name.at(i).to_int()
    if !is_field_sep(c) {
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
fn is_field_sep(c : Int32) -> Bool {
  c == 95 || c == 45 || c == 46 || c == 64
}

///|
/// Alias match with container-prefix peeling: the full squashed name is
/// tried first, then leading segments that are known log-pipeline containers
/// are peeled one at a time (`kubernetes.labels.app` → `app`). Any hit
/// accepts the field; a non-container leading segment stops the peel, so
/// `user.message` and `myapp.servicename` stay unrecognized.
fn field_name_matches(name : Bytes, names : Array[Bytes]) -> Bool {
  let s = squash_field_name(name)
  for n in names {
    if s == n {
      return true
    }
  }
  let len = name.length()
  let mut i = 0
  while i < len {
    let mut j = i
    while j < len && !is_field_sep(name.at(j).to_int()) {
      j = j + 1
    }
    if j == i || j == len {
      break
    }
    let seg = squash_span(name, i, j)
    let mut container = false
    for c in container_prefixes {
      if seg == c {
        container = true
        break
      }
    }
    if !container {
      break
    }
    let rest = squash_span(name, j + 1, len)
    for n in names {
      if rest == n {
        return true
      }
    }
    i = j + 1
  }
  false
}

///|
/// First field whose name matches any alias (with container peeling); the
/// field order in the record decides within a round.
fn find_value(fields : Array[(Bytes, Bytes)], names : Array[Bytes]) -> Bytes? {
  for pair in fields {
    if field_name_matches(pair.0, names) {
      return Some(pair.1)
    }
  }
  None
}

///|
/// OTel severity number (1-24) normalized to the word form the rank table
/// uses, so `severity_number: 17` and `severity_text: "ERROR"` store the
/// same schema shape (word forms keep cross-service filtering literal).
fn level_word_from_number(v : Bytes) -> Bytes? {
  let len = v.length()
  if len == 0 || len > 2 {
    return None
  }
  let mut value = 0
  let mut i = 0
  while i < len {
    let c = v.at(i).to_int()
    if c < 48 || c > 57 {
      return None
    }
    value = value * 10 + (c - 48)
    i = i + 1
  }
  if value < 1 || value > 24 {
    return None
  }
  let word = if value <= 8 {
    b"debug"
  } else if value <= 12 {
    b"info"
  } else if value <= 16 {
    b"warn"
  } else if value <= 20 {
    b"error"
  } else {
    b"fatal"
  }
  Some(word)
}

///|
/// Syslog/journald PRIORITY (0-7) mapped to the same word form: 0-2
/// (emerg/alert/crit) → fatal, 3 (err) → error, 4 (warning) → warn,
/// 5-6 (notice/info) → info, 7 → debug.
fn level_word_from_syslog(v : Bytes) -> Bytes? {
  if v.length() != 1 {
    return None
  }
  let c = v.at(0).to_int()
  if c < 48 || c > 55 {
    return None
  }
  let word = if c <= 50 {
    b"fatal"
  } else if c == 51 {
    b"error"
  } else if c == 52 {
    b"warn"
  } else if c <= 54 {
    b"info"
  } else {
    b"debug"
  }
  Some(word)
}

///|
/// Extract the six canonical fields from a parsed field set. Timestamp values
/// are parsed as epoch milliseconds; an unparsable value falls back to
/// `fallback`. Timestamps go through `normalize_ts` (any numeric precision
/// or ISO-8601 zone offset). Each slot resolves in priority rounds instead of
/// one shared first-match pass: ts consults event-time fields before OTel
/// observed time; level consults word forms, then the OTel number, then
/// syslog PRIORITY — so a record carrying both severity_text and
/// severity_number normalizes to the word whatever the field order.
pub fn schema_from_fields(
  fields : Array[(Bytes, Bytes)],
  fallback : Int64,
) -> SchemaFields {
  let ts_opt : Int64? = match find_value(fields, ts_names) {
    Some(v) => Some(normalize_ts(v, fallback))
    None =>
      match find_value(fields, observed_ts_names) {
        Some(v) => Some(normalize_ts(v, fallback))
        None => None
      }
  }
  let level_opt : Bytes? = match find_value(fields, level_word_names) {
    Some(v) => Some(v)
    None =>
      match find_value(fields, level_number_names) {
        Some(v) => level_word_from_number(v)
        None =>
          match find_value(fields, priority_names) {
            Some(v) => level_word_from_syslog(v)
            None => None
          }
      }
  }
  {
    ts: ts_opt,
    level: level_opt,
    service: find_value(fields, service_names),
    host: find_value(fields, host_names),
    trace_id: find_value(fields, trace_names),
    message: find_value(fields, message_names),
  }
}

///|
/// Quote a field value for the canonical `name=value` serialization when it
/// contains spaces (logfmt quoting): the value is wrapped in double quotes
/// with embedded `"` escaped, so `parse_kv_pairs` reads the exact value back.
/// Values without spaces stay bare.
fn kv_quote_value(v : Bytes) -> Bytes {
  let mut has_space = false
  let mut i = 0
  while i < v.length() {
    if v.at(i).to_int() == 32 {
      has_space = true
      break
    }
    i = i + 1
  }
  if !has_space {
    return v
  }
  let buf = @buffer.Buffer::Buffer()
  buf.write_byte((34 : Byte))
  i = 0
  while i < v.length() {
    let c = v.at(i).to_int()
    if c == 34 || c == 92 {
      buf.write_byte((92 : Byte))
    }
    buf.write_byte(c.to_byte())
    i = i + 1
  }
  buf.write_byte((34 : Byte))
  buf.to_bytes()
}

///|
/// Canonical value for a schema record: the standard fields re-serialized in
/// fixed order (level, host, trace_id, message) as a `name=value` string, so
/// every service ingested with `--schema` has the same shape. Absent fields
/// are skipped; values containing spaces are logfmt-quoted so a re-parse
/// round-trips.
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
      v.write_bytes(kv_quote_value(l))
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
      v.write_bytes(kv_quote_value(h))
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
      v.write_bytes(kv_quote_value(t))
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
      v.write_bytes(kv_quote_value(m))
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
