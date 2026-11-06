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
  value : Bytes,
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
    let pairs = parse_kv_pairs(value)
    for pair in pairs {
      if pair.0 == cfg.level_field {
        let rank = level_rank(pair.1)
        if rank >= 0 && rank < cfg.min_level {
          return false
        }
      }
    }
  }
  sample_passes(raw_line, cfg.sample_rate)
}
