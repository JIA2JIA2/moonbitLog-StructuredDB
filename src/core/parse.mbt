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

///|
/// Severity rank for common log levels: debug=0, info=1, warn/warning=2,
/// error/err=3, fatal=4. Unknown levels return -1 (never filtered by severity).
pub fn level_rank(level : Bytes) -> Int32 {
  if level == b"debug" {
    0
  } else if level == b"info" {
    1
  } else if level == b"warn" || level == b"warning" {
    2
  } else if level == b"error" || level == b"err" {
    3
  } else if level == b"fatal" {
    4
  } else {
    -1
  }
}

///|
/// Severity rank found directly in a raw line (`level=warn`, `level:"warn"`,
/// `"level":"warn"`) for formats without parsed fields (e.g. `--format lines`).
/// Returns -1 when absent or unknown.
fn level_rank_in_line(raw_line : Bytes, level_field : Bytes) -> Int32 {
  let n = raw_line.length()
  let m = level_field.length()
  let mut i = 0
  while i + m < n {
    let mut same = true
    let mut k = 0
    while k < m {
      if raw_line.at(i + k) != level_field.at(k) {
        same = false
        break
      }
      k = k + 1
    }
    if same {
      let prev = if i == 0 { 0 } else { raw_line.at(i - 1).to_int() }
      let boundary = i == 0 ||
        prev == 32 ||
        prev == 34 ||
        prev == 123 ||
        prev == 44 ||
        prev == 9
      let mut j = i + m
      if boundary && j < n && raw_line.at(j).to_int() == 34 {
        j = j + 1
      }
      if boundary &&
        j < n &&
        (raw_line.at(j).to_int() == 61 || raw_line.at(j).to_int() == 58) {
        let mut s = j + 1
        while s < n &&
              (
                raw_line.at(s).to_int() == 32 ||
                raw_line.at(s).to_int() == 34 ||
                raw_line.at(s).to_int() == 9
              ) {
          s = s + 1
        }
        let mut e = s
        while e < n {
          let c = raw_line.at(e).to_int()
          if c == 32 || c == 34 || c == 44 || c == 125 || c == 9 || c == 13 {
            break
          }
          e = e + 1
        }
        if e > s {
          let rank = level_rank(slice(raw_line, s, e))
          if rank >= 0 {
            return rank
          }
        }
      }
    }
    i = i + 1
  }
  -1
}

///|
/// FNV-1a 32-bit hash: deterministic per content, so sampling decisions are
/// stable across replays (the same line always gets the same verdict, which
/// keeps idempotent replay consistent).
pub fn fnv1a_hash(data : Bytes) -> UInt32 {
  let mut h : UInt32 = 2166136261
  let mut i = 0
  while i < data.length() {
    h = h ^ data.at(i).to_int().reinterpret_as_uint()
    h = h * (16777619 : UInt32)
    i = i + 1
  }
  h
}

///|
/// Deterministic proportional sampling: keep the line when its FNV-1a hash
/// modulo 100 is below `rate` (percent, 0..100). `rate = 100` keeps everything,
/// `rate = 0` drops everything.
pub fn sample_passes(data : Bytes, rate : Int32) -> Bool {
  if rate >= 100 {
    return true
  }
  if rate <= 0 {
    return false
  }
  fnv1a_hash(data) % (100 : UInt32) < rate.reinterpret_as_uint()
}

///|
/// One sampled-ingest rule set: minimum severity (a kv `level` field), include/
/// exclude substring rules over the raw line, and the deterministic sample
/// rate. -1/empty/100 mean the corresponding rule is disabled.
pub(all) struct SamplingConfig {
  min_level : Int32
  level_field : Bytes
  sample_rate : Int32
  include_text : Bytes
  exclude_text : Bytes
}

///|
/// Sampling decision for one line: it must pass the include rule (raw line
/// contains), the exclude rule (raw line does not contain), the minimum
/// severity (the `level_field` pair inside the parsed value, when that field
/// is present — unknown levels are never filtered by severity), and the
/// proportional sample rate.
pub fn sampling_allows(
  raw_line : Bytes,
  fields : Array[(Bytes, Bytes)],
  cfg : SamplingConfig,
) -> Bool {
  if cfg.include_text.length() > 0 &&
    !bytes_contains_ci(raw_line, cfg.include_text) {
    return false
  }
  if cfg.exclude_text.length() > 0 &&
    bytes_contains_ci(raw_line, cfg.exclude_text) {
    return false
  }
  if cfg.min_level >= 0 {
    let mut matched = false
    for pair in fields {
      if pair.0 == cfg.level_field {
        matched = true
        let rank = level_rank(pair.1)
        if rank >= 0 && rank < cfg.min_level {
          return false
        }
      }
    }
    // Formats without parsed fields (plain lines) still carry a level in the
    // raw text: `level=warn`, `level:"warn"` or `"level":"warn"`.
    if !matched {
      let rank = level_rank_in_line(raw_line, cfg.level_field)
      if rank >= 0 && rank < cfg.min_level {
        return false
      }
    }
  }
  sample_passes(raw_line, cfg.sample_rate)
}

///|
/// Tokenize a template into literal and placeholder (`<name>`) segments.
fn template_segments(template : Bytes) -> Array[(Bool, Bytes)] {
  let out : Array[(Bool, Bytes)] = []
  let mut start = 0
  let mut i = 0
  while i < template.length() {
    if template.at(i).to_int() == 60 {
      if i > start {
        out.push((false, slice(template, start, i)))
      }
      let close = find_byte_http(template, 62, i + 1)
      if close < 0 {
        out.push((false, slice(template, i, template.length())))
        return out
      }
      out.push((true, slice(template, i + 1, close)))
      i = close + 1
      start = i
    } else {
      i = i + 1
    }
  }
  if start < template.length() {
    out.push((false, slice(template, start, template.length())))
  }
  out
}

///|
/// Parse a raw line against a template of literal text and `<name>`
/// placeholders (a lightweight, regex-free Grok equivalent): each placeholder
/// captures up to the next literal token, and the last placeholder captures to
/// the end of the line. Returns the extracted `name=value` pairs, or None when
/// a literal in the template does not match the line at the expected position.
pub fn parse_by_template(
  line : Bytes,
  template : Bytes,
) -> Array[(Bytes, Bytes)]? {
  let segments = template_segments(template)
  let out : Array[(Bytes, Bytes)] = []
  let mut pos = 0
  let mut i = 0
  while i < segments.length() {
    let is_placeholder = segments[i].0
    let text = segments[i].1
    if !is_placeholder {
      let n = text.length()
      if pos + n > line.length() {
        return None
      }
      let mut j = 0
      while j < n {
        if line.at(pos + j).to_int() != text.at(j).to_int() {
          return None
        }
        j = j + 1
      }
      pos = pos + n
    } else {
      let mut end = line.length()
      if i + 1 < segments.length() {
        // Next literal: capture up to its first occurrence at/after pos.
        let next = segments[i + 1].1
        let n = next.length()
        let mut found = -1
        let mut scan = pos
        while scan + n <= line.length() && found < 0 {
          let mut j = 0
          let mut ok = true
          while j < n && ok {
            if line.at(scan + j).to_int() != next.at(j).to_int() {
              ok = false
            }
            j = j + 1
          }
          if ok {
            found = scan
          }
          scan = scan + 1
        }
        if found < 0 {
          return None
        }
        end = found
      }
      out.push((text, slice(line, pos, end)))
      pos = end
    }
    i = i + 1
  }
  Some(out)
}

///|
/// Flatten a top-level JSON object into `name=value` field pairs (the same
/// Bytes model as the kv ingest format). Non-object JSON yields an empty
/// array; malformed JSON raises ParseError (the caller decides whether to
/// keep the raw line). String values are kept verbatim; numbers, booleans and
/// null render as text; nested arrays/objects serialize as compact JSON.
pub fn json_object_fields(
  line : Bytes,
) -> Array[(Bytes, Bytes)] raise @json.ParseError {
  let text = @utf8.decode_lossy(line)
  let parsed = @json.parse(text)
  let out : Array[(Bytes, Bytes)] = []
  match parsed {
    Object(map) =>
      for name, value in map {
        let v = match value {
          String(s) => s
          Number(n, ..) => n.to_string()
          True => "true"
          False => "false"
          Null => "null"
          _ => value.stringify()
        }
        out.push((@utf8.encode(name), @utf8.encode(v)))
      }
    _ => ()
  }
  out
}
