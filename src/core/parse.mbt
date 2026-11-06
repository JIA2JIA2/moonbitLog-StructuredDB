///|
/// Parse space-separated `name=value` pairs from a log line. Empty segments
/// and segments without `=` are skipped; only the first `=` in a segment
/// separates the name from the value (values may contain further `=`).
pub fn parse_kv_pairs(line : Bytes) -> Array[(Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes)] = []
  let mut start = 0
  let mut i = 0
  while i <= line.length() {
    if i == line.length() || line.at(i).to_int() == 32 {
      if i > start {
        match split_kv_segment(slice(line, start, i)) {
          Some(pair) => out.push(pair)
          None => ()
        }
      }
      start = i + 1
    }
    i = i + 1
  }
  out
}

///|
/// Whether `hay` contains `needle` as a byte substring; an empty needle
/// always matches. Linear search — intended for log-line sized inputs.
pub fn bytes_contains(hay : Bytes, needle : Bytes) -> Bool {
  let n = needle.length()
  if n == 0 {
    return true
  }
  let h = hay.length()
  if n > h {
    return false
  }
  let mut i = 0
  while i + n <= h {
    let mut j = 0
    let mut ok = true
    while j < n && ok {
      if hay.at(i + j).to_int() != needle.at(j).to_int() {
        ok = false
      }
      j = j + 1
    }
    if ok {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// ASCII case-insensitive variant of `bytes_contains`: bytes in `A-Z`/`a-z`
/// compare case-insensitively, everything else byte-exactly.
pub fn bytes_contains_ci(hay : Bytes, needle : Bytes) -> Bool {
  let n = needle.length()
  if n == 0 {
    return true
  }
  let h = hay.length()
  if n > h {
    return false
  }
  let mut i = 0
  while i + n <= h {
    let mut j = 0
    let mut ok = true
    while j < n && ok {
      if lower_ascii(hay.at(i + j).to_int()) !=
        lower_ascii(needle.at(j).to_int()) {
        ok = false
      }
      j = j + 1
    }
    if ok {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn lower_ascii(b : Int32) -> Int32 {
  if b >= 65 && b <= 90 {
    b + 32
  } else {
    b
  }
}

///|
/// Split one `name=value` segment; returns None when the segment has no `=`.
fn split_kv_segment(seg : Bytes) -> (Bytes, Bytes)? {
  let mut i = 0
  while i < seg.length() {
    if seg.at(i).to_int() == 61 {
      return Some((slice(seg, 0, i), slice(seg, i + 1, seg.length())))
    }
    i = i + 1
  }
  None
}

///|
/// Quote `s` as a single POSIX shell argument: the value is wrapped in single
/// quotes and every embedded single quote becomes `'\''`. Safe for building
/// `curl`-style command lines from user-provided URLs and payloads.
pub fn shell_quote(s : String) -> String {
  let sb = StringBuilder()
  sb.write_string("'")
  for ch in s {
    if ch.to_int() == 39 {
      sb.write_string("'\\''")
    } else {
      sb.write_char(ch)
    }
  }
  sb.write_string("'")
  sb.to_string()
}
