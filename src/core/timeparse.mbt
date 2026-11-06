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
/// Parse an ISO-8601 date-time into epoch milliseconds:
/// `YYYY-MM-DD[ T]HH:MM:SS[.frac]` optionally followed by `Z`, `±HH:MM` or
/// `±HHMM`; no zone suffix means UTC. Fractional seconds are truncated to
/// millisecond precision. Anything that does not match the shape returns
/// `fallback`. No calendar/regex library is used.
pub fn parse_iso8601_ms(b : Bytes, fallback : Int64) -> Int64 {
  let len = b.length()
  if len < 19 {
    return fallback
  }
  if b.at(4).to_int() != 45 ||
    b.at(7).to_int() != 45 ||
    b.at(13).to_int() != 58 ||
    b.at(16).to_int() != 58 {
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
  let second = match read_digits(b, 17, 2) {
    Some(v) => v.0
    None => return fallback
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
  let mut i : Int32 = 19
  if i < len && b.at(i).to_int() == 46 {
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
      let sign : Int64 = if c == 45 { -1 } else { 1 }
      i = i + 1
      let hh = match read_digits(b, i, 2) {
        Some(v) => {
          i = v.1
          v.0
        }
        None => return fallback
      }
      if i < len && b.at(i).to_int() == 58 {
        i = i + 1
      }
      let mm = match read_digits(b, i, 2) {
        Some(v) => {
          i = v.1
          v.0
        }
        None => return fallback
      }
      if hh > 23 || mm > 59 {
        return fallback
      }
      offset_min = sign * (hh * 60 + mm)
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
/// Normalize a timestamp value from any ingestion source to epoch
/// milliseconds (2.3): a pure decimal number is scaled by digit count —
/// seconds (<1e11), milliseconds (<1e14), microseconds (<1e17), nanoseconds
/// otherwise — and any other shape is tried as ISO-8601 (any zone offset,
/// see `parse_iso8601_ms`). Returns `fallback` when the value matches
/// neither shape, so arrival-order timestamps keep working.
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
    parse_iso8601_ms(b, fallback)
  }
}
