///|
/// Normalize a log line into a clustering template: digit runs become
/// `<num>`, `0x`/`0X`-prefixed hex runs become `<hex>`, single- and
/// double-quoted spans become `<str>`, and `key=value` whitespace tokens
/// collapse to `key=<v>` unless the value is a common enum word (level
/// words like `error`/`warn`, booleans, ...) — bare values such as
/// `host=alpha` are variable content that used to split equal-shaped
/// messages into separate clusters.
pub fn normalize_log_template(line : Bytes) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  let n = line.length()
  let mut i = 0
  let mut tok_start = -1
  while i < n {
    let b = line.at(i).to_int()
    if b == 34 || b == 39 {
      // Quoted span: settle any open token first, then consume the span.
      if tok_start >= 0 {
        normalize_template_token(slice(line, tok_start, i), out)
        tok_start = -1
      }
      out.write_bytes(b"<str>")
      i = i + 1
      while i < n && line.at(i).to_int() != b {
        i = i + 1
      }
      if i < n {
        i = i + 1
      }
    } else if b == 32 || b == 9 {
      // Whitespace: token boundary, passed through verbatim.
      if tok_start >= 0 {
        normalize_template_token(slice(line, tok_start, i), out)
        tok_start = -1
      }
      out.write_bytes(slice(line, i, i + 1))
      i = i + 1
    } else {
      if tok_start < 0 {
        tok_start = i
      }
      i = i + 1
    }
  }
  if tok_start >= 0 {
    normalize_template_token(slice(line, tok_start, n), out)
  }
  out.to_bytes()
}

///|
fn normalize_template_token(t : Bytes, out : @buffer.Buffer) -> Unit {
  // key=value token: collapse the value unless it is a common enum word.
  let mut eq = -1
  let mut j = 0
  while j < t.length() {
    if t.at(j).to_int() == 61 {
      eq = j
      break
    }
    j = j + 1
  }
  if eq > 0 &&
    eq + 1 < t.length() &&
    !reserved_enum_value(slice(t, eq + 1, t.length())) {
    out.write_bytes(slice(t, 0, eq))
    out.write_bytes(b"=<v>")
    return
  }
  let n = t.length()
  let mut i = 0
  while i < n {
    let b = t.at(i).to_int()
    if b == 48 &&
      i + 1 < n &&
      (t.at(i + 1).to_int() == 120 || t.at(i + 1).to_int() == 88) &&
      i + 2 < n &&
      is_hex_digit(t.at(i + 2).to_int()) {
      // 0x1234 style hex run.
      out.write_bytes(b"<hex>")
      i = i + 2
      while i < n && is_hex_digit(t.at(i).to_int()) {
        i = i + 1
      }
    } else if b >= 48 && b <= 57 {
      // Digit run.
      out.write_bytes(b"<num>")
      while i < n && t.at(i).to_int() >= 48 && t.at(i).to_int() <= 57 {
        i = i + 1
      }
    } else {
      // Batch-copy the plain-byte run up to the next variable start — one
      // byte at a time dominated cluster/anomaly scans on large inputs.
      let start = i
      while i < n {
        let c = t.at(i).to_int()
        if c >= 48 && c <= 57 {
          break
        }
        if c == 48 &&
          i + 1 < n &&
          (t.at(i + 1).to_int() == 120 || t.at(i + 1).to_int() == 88) &&
          i + 2 < n &&
          is_hex_digit(t.at(i + 2).to_int()) {
          break
        }
        i = i + 1
      }
      out.write_bytes(slice(t, start, i))
    }
  }
}

///|
/// True when a `key=value` value is a common enum word (case-insensitive)
/// that carries meaning worth keeping distinct in templates: level words,
/// booleans and a few frequent status words.
fn reserved_enum_value(v : Bytes) -> Bool {
  let buf = @buffer.Buffer::Buffer()
  let n = v.length()
  let mut i = 0
  while i < n {
    let c = v.at(i).to_int()
    if c >= 65 && c <= 90 {
      buf.write_byte((c + 32).to_byte())
    } else {
      buf.write_byte(c.to_byte())
    }
    i = i + 1
  }
  let s = buf.to_bytes()
  s == b"error" ||
  s == b"warn" ||
  s == b"warning" ||
  s == b"info" ||
  s == b"debug" ||
  s == b"fatal" ||
  s == b"trace" ||
  s == b"critical" ||
  s == b"true" ||
  s == b"false" ||
  s == b"ok" ||
  s == b"success" ||
  s == b"fail" ||
  s == b"failed" ||
  s == b"none" ||
  s == b"null"
}

///|
fn is_hex_digit(b : Int32) -> Bool {
  (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
}

///|
/// Format a millisecond timestamp as UTC text at the given precision:
/// `minute` → "YYYY-MM-DD HH:MM", `hour` → "YYYY-MM-DD HH:00", `day` →
/// "YYYY-MM-DD" (anything else is treated as `hour`). Negative timestamps
/// clamp to the epoch. Uses the days-to-civil algorithm, no calendar library.
pub fn format_utc(ms : Int64, precision : String) -> String {
  let secs = if ms < (0 : Int64) { (0 : Int64) } else { ms / (1000 : Int64) }
  let days = secs / (86400 : Int64)
  let rem = secs % (86400 : Int64)
  let hour = rem / (3600 : Int64)
  let minute = rem % (3600 : Int64) / (60 : Int64)
  let z = days + (719468 : Int64)
  let era = (if z >= (0 : Int64) { z } else { z - (146096 : Int64) }) /
    (146097 : Int64)
  let doe = z - era * (146097 : Int64)
  let yoe = (
      doe -
      doe / (1460 : Int64) +
      doe / (36524 : Int64) -
      doe / (146096 : Int64)
    ) /
    (365 : Int64)
  let y = yoe + era * (400 : Int64)
  let doy = doe -
    ((365 : Int64) * yoe + yoe / (4 : Int64) - yoe / (100 : Int64))
  let mp = ((5 : Int64) * doy + (2 : Int64)) / (153 : Int64)
  let d = doy - ((153 : Int64) * mp + (2 : Int64)) / (5 : Int64) + (1 : Int64)
  let m = if mp < (10 : Int64) { mp + (3 : Int64) } else { mp - (9 : Int64) }
  let yy = if m <= (2 : Int64) { y + (1 : Int64) } else { y }
  let date = yy.to_string() + "-" + pad2(m) + "-" + pad2(d)
  if precision == "day" {
    date
  } else if precision == "minute" {
    date + " " + pad2(hour) + ":" + pad2(minute)
  } else {
    date + " " + pad2(hour) + ":00"
  }
}

///|
fn pad2(v : Int64) -> String {
  if v < (10 : Int64) {
    "0" + v.to_string()
  } else {
    v.to_string()
  }
}
