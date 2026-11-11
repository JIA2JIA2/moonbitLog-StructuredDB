///|
fn ascii_digit(c : Int32) -> Int64? {
  if c >= 48 && c <= 57 {
    Some((c - 48).to_int64())
  } else {
    None
  }
}

///|
/// Read exactly `n` ASCII digits starting at `i`; None when out of range or
/// a non-digit is met. Returns `(value, index_past_digits)`.
fn read_digits(b : Bytes, i : Int32, n : Int32) -> (Int64, Int32)? {
  let mut v : Int64 = 0
  let mut j = i
  while j < i + n {
    if j >= b.length() {
      return None
    }
    match ascii_digit(b.at(j).to_int()) {
      Some(d) => {
        v = v * 10 + d
        j = j + 1
      }
      None => return None
    }
  }
  Some((v, i + n))
}

///|
/// Days since 1970-01-01 for a civil date (proleptic Gregorian, the
/// days-from-civil algorithm — the inverse of `format_utc`'s days-to-civil).
fn days_from_civil(y : Int64, m : Int64, d : Int64) -> Int64 {
  let yy = if m <= 2 { y - 1 } else { y }
  let era = (if yy >= 0 { yy } else { yy - 399 }) / 400
  let yoe = yy - era * 400
  let mp = if m > 2 { m - 3 } else { m + 9 }
  let doy = ((153 : Int64) * mp + (2 : Int64)) / (5 : Int64) + d - (1 : Int64)
  let doe = yoe * (365 : Int64) + yoe / (4 : Int64) - yoe / (100 : Int64) + doy
  era * (146097 : Int64) + doe - (719468 : Int64)
}

///|
/// Whether a 3-byte zone tag is `UTC` or `GMT` (ASCII case-insensitive).
fn tag_utc_gmt(t : Bytes) -> Bool {
  if t.length() != 3 {
    return false
  }
  let a = t.at(0).to_int()
  let b = t.at(1).to_int()
  let c = t.at(2).to_int()
  let la = if a >= 65 && a <= 90 { a + 32 } else { a }
  let lb = if b >= 65 && b <= 90 { b + 32 } else { b }
  let lc = if c >= 65 && c <= 90 { c + 32 } else { c }
  (la == 117 && lb == 116 && lc == 99) || (la == 103 && lb == 109 && lc == 116)
}

///|
/// Read a `±HH[:MM]` zone offset at `i` (the `+`/`-` byte itself); returns
/// `(offset_minutes, index_past_offset)`. A missing `MM` after two digit
/// bytes keeps `mm = 0` and stops after `HH` (residual bytes are rejected by
/// the caller's end check), mirroring the permissive `±HH` form.
fn read_zone_offset(b : Bytes, i : Int32) -> (Int64, Int32)? {
  let c = b.at(i).to_int()
  let sign : Int64 = if c == 45 { -1 } else { 1 }
  let hh = match read_digits(b, i + 1, 2) {
    Some(v) => v
    None => return None
  }
  let mut mm : Int64 = 0
  let mut next = hh.1
  if next < b.length() && b.at(next).to_int() == 58 {
    match read_digits(b, next + 1, 2) {
      Some(v) => {
        mm = v.0
        next = v.1
      }
      None => return None
    }
  } else if next + 2 <= b.length() {
    match read_digits(b, next, 2) {
      Some(v) => {
        mm = v.0
        next = v.1
      }
      None => ()
    }
  }
  if hh.0 > 23 || mm > 59 {
    return None
  }
  Some((sign * (hh.0 * (60 : Int64) + mm), next))
}

///|
/// Parse an ISO-8601-ish date-time into epoch milliseconds:
/// `YYYY-MM-DD[ T]HH:MM[:SS][.frac|,frac]` optionally followed by `Z`/`z`,
/// `±HH:MM`, `±HHMM`, `±HH`, or a space-separated ` UTC`/` GMT` tag or
/// `±HH[:MM]` offset; no zone suffix means UTC. Date separators may be `-` or
/// `/` (a common log format); fractional seconds accept `.` or `,`
/// (Java/log4j style) and truncate to millisecond precision. A bare date
/// (`YYYY-MM-DD`) parses as midnight UTC. Anything that does not match the
/// shape returns `fallback`. No calendar/regex library is used.
pub fn parse_iso8601_ms(b : Bytes, fallback : Int64) -> Int64 {
  let len = b.length()
  // Date-only (`YYYY-MM-DD` / `YYYY/MM/DD`): midnight UTC. A bare date is a
  // complete, valid value — much closer to the event than falling back to
  // the ingest time would be.
  if len == 10 {
    let s4 = b.at(4).to_int()
    let s7 = b.at(7).to_int()
    if (s4 == 45 || s4 == 47) && (s7 == 45 || s7 == 47) {
      let year = match read_digits(b, 0, 4) {
        Some(v) => v.0
        None => return fallback
      }
      let month = match read_digits(b, 5, 2) {
        Some(v) => v.0
        None => return fallback
      }
      let day = match read_digits(b, 8, 2) {
        Some(v) => v.0
        None => return fallback
      }
      if month < 1 || month > 12 || day < 1 || day > 31 {
        return fallback
      }
      return days_from_civil(year, month, day) * (86400000 : Int64)
    }
    return fallback
  }
  if len < 16 {
    return fallback
  }
  let sep4 = b.at(4).to_int()
  let sep7 = b.at(7).to_int()
  if (sep4 != 45 && sep4 != 47) || (sep7 != 45 && sep7 != 47) {
    return fallback
  }
  if b.at(13).to_int() != 58 {
    return fallback
  }
  let sep = b.at(10).to_int()
  if sep != 84 && sep != 116 && sep != 32 {
    return fallback
  }
  let year = match read_digits(b, 0, 4) {
    Some(v) => v.0
    None => return fallback
  }
  let month = match read_digits(b, 5, 2) {
    Some(v) => v.0
    None => return fallback
  }
  let day = match read_digits(b, 8, 2) {
    Some(v) => v.0
    None => return fallback
  }
  let hour = match read_digits(b, 11, 2) {
    Some(v) => v.0
    None => return fallback
  }
  let minute = match read_digits(b, 14, 2) {
    Some(v) => v.0
    None => return fallback
  }
  // Seconds are optional (`YYYY-MM-DD HH:MM` is a common log shape).
  let mut second : Int64 = 0
  let mut i : Int32 = 16
  if i < len && b.at(i).to_int() == 58 {
    second = match read_digits(b, 17, 2) {
      Some(v) => v.0
      None => return fallback
    }
    i = 19
  }
  if month < 1 ||
    month > 12 ||
    day < 1 ||
    day > 31 ||
    hour > 23 ||
    minute > 59 ||
    second > 60 {
    return fallback
  }
  let mut frac_ms : Int64 = 0
  if i < len && (b.at(i).to_int() == 46 || b.at(i).to_int() == 44) {
    i = i + 1
    let mut scale : Int64 = 100
    let mut k = 0
    while i < len && k < 3 {
      match ascii_digit(b.at(i).to_int()) {
        Some(d) => {
          frac_ms = frac_ms + d * scale
          scale = scale / 10
          i = i + 1
          k = k + 1
        }
        None => break
      }
    }
    while i < len {
      match ascii_digit(b.at(i).to_int()) {
        Some(_) => i = i + 1
        None => break
      }
    }
  }
  let mut offset_min : Int64 = 0
  if i < len {
    let c = b.at(i).to_int()
    if c == 90 || c == 122 {
      i = i + 1
    } else if c == 43 || c == 45 {
      match read_zone_offset(b, i) {
        Some(v) => {
          offset_min = v.0
          i = v.1
        }
        None => return fallback
      }
    } else if c == 32 {
      // ` UTC` / ` GMT` tags and ` ±HH[:MM]` offsets (optionally with extra
      // spaces) — e.g. `2026-11-11 10:00:00.123 +08:00`.
      i = i + 1
      while i < len && b.at(i).to_int() == 32 {
        i = i + 1
      }
      if i < len {
        let zc = b.at(i).to_int()
        if zc == 43 || zc == 45 {
          match read_zone_offset(b, i) {
            Some(v) => {
              offset_min = v.0
              i = v.1
            }
            None => return fallback
          }
        } else if i + 3 <= len && tag_utc_gmt(slice(b, i, i + 3)) {
          i = i + 3
        } else {
          return fallback
        }
      } else {
        return fallback
      }
    } else {
      return fallback
    }
  }
  if i != len {
    return fallback
  }
  let days = days_from_civil(year, month, day)
  days * (86400000 : Int64) +
  hour * (3600000 : Int64) +
  minute * (60000 : Int64) +
  second * (1000 : Int64) +
  frac_ms -
  offset_min * (60000 : Int64)
}

///|
/// Month number for a 3-letter name at `i` (Jan..Dec, ASCII
/// case-insensitive); None otherwise.
fn month_from_name(b : Bytes, i : Int32) -> Int64? {
  if i + 3 > b.length() {
    return None
  }
  let a = lower_ascii(b.at(i).to_int())
  let m = lower_ascii(b.at(i + 1).to_int())
  let d = lower_ascii(b.at(i + 2).to_int())
  if a == 106 && m == 97 && d == 110 {
    Some((1 : Int64)) // jan
  } else if a == 102 && m == 101 && d == 98 {
    Some((2 : Int64)) // feb
  } else if a == 109 && m == 97 && d == 114 {
    Some((3 : Int64)) // mar
  } else if a == 97 && m == 112 && d == 114 {
    Some((4 : Int64)) // apr
  } else if a == 109 && m == 97 && d == 121 {
    Some((5 : Int64)) // may
  } else if a == 106 && m == 117 && d == 110 {
    Some((6 : Int64)) // jun
  } else if a == 106 && m == 117 && d == 108 {
    Some((7 : Int64)) // jul
  } else if a == 97 && m == 117 && d == 103 {
    Some((8 : Int64)) // aug
  } else if a == 115 && m == 101 && d == 112 {
    Some((9 : Int64)) // sep
  } else if a == 111 && m == 99 && d == 116 {
    Some((10 : Int64)) // oct
  } else if a == 110 && m == 111 && d == 118 {
    Some((11 : Int64)) // nov
  } else if a == 100 && m == 101 && d == 99 {
    Some((12 : Int64)) // dec
  } else {
    None
  }
}

///|
/// Parse an RFC 2822 date-time (`Tue, 11 Nov 2026 10:00:00 +0800`, the
/// mail/HTTP Date shape; the weekday part is optional) into epoch
/// milliseconds: 1-2 digit day, month name, 4-digit year, `HH:MM[:SS]`, then
/// `±HHMM`/`±HH:MM` or `GMT`/`UTC`; no zone means UTC. Month names fail
/// fast for non-date shapes, so numeric/ISO inputs fall back to their own
/// parsers unchanged.
pub fn parse_rfc2822_ms(b : Bytes, fallback : Int64) -> Int64 {
  let len = b.length()
  let mut i = 0
  while i < len {
    let c = b.at(i).to_int()
    if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) {
      i = i + 1
    } else {
      break
    }
  }
  if i < len && b.at(i).to_int() == 44 {
    i = i + 1
  }
  while i < len && b.at(i).to_int() == 32 {
    i = i + 1
  }
  let day = match read_digits(b, i, 1) {
    Some(v) => {
      i = v.1
      let mut d = v.0
      if i < len {
        match ascii_digit(b.at(i).to_int()) {
          Some(d2) => {
            d = d * (10 : Int64) + d2
            i = i + 1
          }
          None => ()
        }
      }
      d
    }
    None => return fallback
  }
  while i < len && b.at(i).to_int() == 32 {
    i = i + 1
  }
  let month = match month_from_name(b, i) {
    Some(m) => {
      i = i + 3
      m
    }
    None => return fallback
  }
  while i < len && b.at(i).to_int() == 32 {
    i = i + 1
  }
  let year = match read_digits(b, i, 4) {
    Some(v) => {
      i = v.1
      v.0
    }
    None => return fallback
  }
  while i < len && b.at(i).to_int() == 32 {
    i = i + 1
  }
  if i + 5 > len || b.at(i + 2).to_int() != 58 {
    return fallback
  }
  let hour = match read_digits(b, i, 2) {
    Some(v) => v.0
    None => return fallback
  }
  let minute = match read_digits(b, i + 3, 2) {
    Some(v) => v.0
    None => return fallback
  }
  i = i + 5
  let mut second : Int64 = 0
  if i < len && b.at(i).to_int() == 58 {
    match read_digits(b, i + 1, 2) {
      Some(v) => {
        second = v.0
        i = v.1
      }
      None => return fallback
    }
  }
  while i < len && b.at(i).to_int() == 32 {
    i = i + 1
  }
  let mut offset_min : Int64 = 0
  if i < len {
    let c = b.at(i).to_int()
    if c == 43 || c == 45 {
      match read_zone_offset(b, i) {
        Some(v) => {
          offset_min = v.0
          i = v.1
        }
        None => return fallback
      }
    } else if i + 3 <= len && tag_utc_gmt(slice(b, i, i + 3)) {
      i = i + 3
    } else {
      return fallback
    }
  }
  while i < len && b.at(i).to_int() == 32 {
    i = i + 1
  }
  if i != len {
    return fallback
  }
  if month < 1 ||
    month > 12 ||
    day < 1 ||
    day > 31 ||
    hour > 23 ||
    minute > 59 ||
    second > 60 {
    return fallback
  }
  let days = days_from_civil(year, month, day)
  days * (86400000 : Int64) +
  hour * (3600000 : Int64) +
  minute * (60000 : Int64) +
  second * (1000 : Int64) -
  offset_min * (60000 : Int64)
}

///|
/// Normalize a timestamp value from any ingestion source to epoch
/// milliseconds (2.3): a pure decimal number is scaled by digit count —
/// seconds (<1e11), milliseconds (<1e14), microseconds (<1e17), nanoseconds
/// otherwise — and an epoch-seconds value with a fractional part
/// (`1794391200.512`, the Python `time.time()` shape) keeps up to three
/// fractional digits as milliseconds. Any other shape is tried as RFC 2822
/// (letter-led, e.g. `Tue, 11 Nov 2026 10:00:00 +0800`) and then as
/// ISO-8601 (any zone offset, see `parse_iso8601_ms`). Returns `fallback`
/// when the value matches none of the shapes, so arrival-order timestamps
/// keep working.
pub fn normalize_ts(b : Bytes, fallback : Int64) -> Int64 {
  let len = b.length()
  if len == 0 {
    return fallback
  }
  let start = if b.at(0).to_int() == 45 { 1 } else { 0 }
  if start == len {
    return fallback
  }
  let mut all_digits = true
  let mut i = start
  while i < len {
    match ascii_digit(b.at(i).to_int()) {
      Some(_) => i = i + 1
      None => {
        all_digits = false
        break
      }
    }
  }
  if all_digits {
    let v = @string.parse_int64(@utf8.decode_lossy(b)) catch {
      _ => return fallback
    }
    let n = if v < 0 { -v } else { v }
    if n < (100_000_000_000 : Int64) {
      v * (1000 : Int64)
    } else if n < (100_000_000_000_000 : Int64) {
      v
    } else if n < (100_000_000_000_000_000 : Int64) {
      v / (1000 : Int64)
    } else {
      v / (1000000 : Int64)
    }
  } else {
    // Epoch seconds with a fraction: one dot, digits on both sides, integer
    // part short enough to be a seconds value (<1e11 digits). The fractional
    // part contributes its first three digits as milliseconds, right-padded
    // (`1794391200.5` → 500).
    let mut dot : Int32 = -1
    let mut ok = true
    let mut j = start
    while j < len {
      let c = b.at(j).to_int()
      if c == 46 {
        if dot >= 0 {
          ok = false
        }
        dot = j
      } else if ascii_digit(c) is Some(_) {
        ()
      } else {
        ok = false
      }
      if !ok {
        j = len
      } else {
        j = j + 1
      }
    }
    if ok && dot > start {
      let int_len = dot - start
      if int_len < 11 {
        let v = @string.parse_int64(@utf8.decode_lossy(slice(b, start, dot))) catch {
          _ => return fallback
        }
        let mut frac_ms : Int64 = 0
        let mut scale : Int64 = 100
        let mut k = dot + 1
        while k < len && k < dot + 4 {
          match ascii_digit(b.at(k).to_int()) {
            Some(d) => {
              frac_ms = frac_ms + d * scale
              scale = scale / 10
              k = k + 1
            }
            None => return fallback
          }
        }
        return v * (1000 : Int64) + frac_ms
      }
    }
    parse_rfc2822_ms(b, parse_iso8601_ms(b, fallback))
  }
}
