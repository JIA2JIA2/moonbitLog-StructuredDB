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
/// A compiled template placeholder. `<name>` captures up to the next literal
/// (the original M115 behavior). `<name:pattern>` adds a restricted
/// Grok-style field pattern: one character class plus an optional quantifier,
/// e.g. `<status:\d+>`, `<msg:[^"]+>`, `<ws:\s*>`, `<path:\S+?>`.
priv struct TemplateField {
  name : Bytes
  class : Bytes
  min_len : Int32
  max_len : Int32
  greedy : Bool
}

///|
/// Split a placeholder body into name and a parsed field pattern. A pattern
/// with more than one token falls back to the default capture so the parser
/// stays linear and predictable (no backtracking engine).
fn template_field(body : Bytes) -> TemplateField {
  let mut colon = -1
  let mut i = 0
  while i < body.length() {
    if body.at(i).to_int() == 58 {
      colon = i
      break
    }
    i = i + 1
  }
  if colon < 0 {
    return { name: body, class: b"", min_len: 0, max_len: -1, greedy: false, }
  }
  let name = slice(body, 0, colon)
  let pat = slice(body, colon + 1, body.length())
  let mut cls : Bytes = b""
  let mut j = 0
  if pat.length() == 0 {
    ()
  } else if pat.at(0).to_int() == 91 {
    let mut k = 1
    while k < pat.length() && pat.at(k).to_int() != 93 {
      k = k + 1
    }
    if k < pat.length() {
      cls = slice(pat, 0, k + 1)
      j = k + 1
    } else {
      return { name, class: b"", min_len: 0, max_len: -1, greedy: false, }
    }
  } else if pat.at(0).to_int() == 92 {
    if pat.length() < 2 {
      return { name, class: b"", min_len: 0, max_len: -1, greedy: false, }
    }
    cls = slice(pat, 0, 2)
    j = 2
  } else {
    cls = slice(pat, 0, 1)
    j = 1
  }
  let mut min_len = 1
  let mut max_len = 1
  let mut greedy = true
  if j < pat.length() {
    let q = pat.at(j).to_int()
    if q == 63 {
      min_len = 0
      j = j + 1
    } else if q == 42 {
      min_len = 0
      max_len = -1
      j = j + 1
    } else if q == 43 {
      max_len = -1
      j = j + 1
    }
    if j < pat.length() && pat.at(j).to_int() == 63 {
      greedy = false
      j = j + 1
    }
  }
  if j < pat.length() {
    // Multi-token pattern: fall back to the default capture.
    return { name, class: b"", min_len: 0, max_len: -1, greedy: false, }
  }
  { name, class: cls, min_len, max_len, greedy, }
}

///|
/// Whether `c` belongs to a compiled character class (`\d`, `\w`, `\s`,
/// `\S`, `.`, `[a-z]`, `[^...]`, or a single literal byte).
fn template_class_matches(cls : Bytes, c : Int32) -> Bool {
  if cls.length() == 0 {
    return true
  }
  let first = cls.at(0).to_int()
  if first == 46 {
    return true
  }
  if first == 92 && cls.length() == 2 {
    let k = cls.at(1).to_int()
    if k == 100 {
      return c >= 48 && c <= 57
    }
    if k == 119 {
      return (c >= 48 && c <= 57) ||
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        c == 95
    }
    if k == 115 {
      return c == 32 || c == 9 || c == 13
    }
    if k == 83 {
      return !(c == 32 || c == 9 || c == 13)
    }
    return c == k
  }
  if first == 91 {
    let mut neg = false
    let mut i = 1
    if cls.length() > 1 && cls.at(1).to_int() == 94 {
      neg = true
      i = 2
    }
    let mut hit = false
    while i < cls.length() && cls.at(i).to_int() != 93 {
      if cls.at(i).to_int() == 92 && i + 1 < cls.length() {
        // Escaped shorthands are allowed inside a class (`[\d.]`, `[^\s]`).
        let k = cls.at(i + 1).to_int()
        if k == 100 {
          if c >= 48 && c <= 57 {
            hit = true
          }
        } else if k == 119 {
          if (c >= 48 && c <= 57) ||
            (c >= 65 && c <= 90) ||
            (c >= 97 && c <= 122) ||
            c == 95 {
            hit = true
          }
        } else if k == 115 {
          if c == 32 || c == 9 || c == 13 {
            hit = true
          }
        } else if k == 83 {
          if !(c == 32 || c == 9 || c == 13) {
            hit = true
          }
        } else if c == k {
          hit = true
        }
        i = i + 2
      } else if i + 2 < cls.length() &&
        cls.at(i + 1).to_int() == 45 &&
        cls.at(i + 2).to_int() != 93 {
        if c >= cls.at(i).to_int() && c <= cls.at(i + 2).to_int() {
          hit = true
        }
        i = i + 3
      } else {
        if c == cls.at(i).to_int() {
          hit = true
        }
        i = i + 1
      }
    }
    return if neg { !hit } else { hit }
  }
  c == first
}

///|
/// Match one placeholder at `pos`, given the literal that follows it (empty
/// for a trailing placeholder). Returns the captured end position.
fn template_capture_end(
  line : Bytes,
  pos : Int32,
  field : TemplateField,
  next_literal : Bytes,
) -> Int32? {
  if field.class.length() == 0 {
    // Default placeholder: capture up to the first occurrence of the next
    // literal, or to the end of the line when there is none.
    if next_literal.length() == 0 {
      return Some(line.length())
    }
    let n = next_literal.length()
    let mut scan = pos
    while scan + n <= line.length() {
      let mut j = 0
      let mut ok = true
      while j < n && ok {
        if line.at(scan + j).to_int() != next_literal.at(j).to_int() {
          ok = false
        }
        j = j + 1
      }
      if ok {
        return Some(scan)
      }
      scan = scan + 1
    }
    return None
  }
  // Pattern capture: consume the class greedily, then honour the quantifier
  // and the following literal (greedy searches the literal right-to-left).
  let mut e = pos
  while e < line.length() &&
        template_class_matches(field.class, line.at(e).to_int()) {
    e = e + 1
    if field.max_len >= 0 && e - pos >= field.max_len {
      break
    }
  }
  let min_end = pos + field.min_len
  if e < min_end {
    return None
  }
  if next_literal.length() == 0 {
    return Some(if field.greedy { e } else { min_end })
  }
  let n = next_literal.length()
  if field.greedy {
    let mut scan = e
    while scan >= min_end {
      if scan + n <= line.length() {
        let mut j = 0
        let mut ok = true
        while j < n && ok {
          if line.at(scan + j).to_int() != next_literal.at(j).to_int() {
            ok = false
          }
          j = j + 1
        }
        if ok {
          return Some(scan)
        }
      }
      scan = scan - 1
    }
  } else {
    let mut scan = min_end
    while scan <= e && scan + n <= line.length() {
      let mut j = 0
      let mut ok = true
      while j < n && ok {
        if line.at(scan + j).to_int() != next_literal.at(j).to_int() {
          ok = false
        }
        j = j + 1
      }
      if ok {
        return Some(scan)
      }
      scan = scan + 1
    }
  }
  None
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
/// Parse a raw line against a template of literal text and placeholders
/// (a lightweight, regex-free Grok equivalent). `<name>` captures up to the
/// next literal token (the last placeholder captures to end of line);
/// `<name:pattern>` adds a restricted pattern over one character class and
/// quantifier, e.g. `<status:\d+>`, `<msg:[^"]+>`, `<ws:\s*>`, `<path:\S+?>`.
/// Returns the extracted `name=value` pairs, or None when a literal or
/// pattern does not match the line at the expected position.
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
      let field = template_field(text)
      let next_literal = if i + 1 < segments.length() && !segments[i + 1].0 {
        segments[i + 1].1
      } else {
        b""
      }
      match template_capture_end(line, pos, field, next_literal) {
        Some(end) => {
          out.push((field.name, slice(line, pos, end)))
          pos = end
        }
        None => return None
      }
    }
    i = i + 1
  }
  Some(out)
}

///|
/// Recursively flatten a JSON value: nested objects become dotted field names
/// (`a.b.c`), arrays serialize as compact JSON, scalars render as text.
fn flatten_json_value(
  prefix : String,
  value : Json,
  out : Array[(Bytes, Bytes)],
) -> Unit {
  match value {
    Object(map) =>
      for name, v in map {
        let key = if prefix.length() == 0 { name } else { prefix + "." + name }
        flatten_json_value(key, v, out)
      }
    _ => {
      let text = match value {
        String(s) => s
        Number(n, ..) => n.to_string()
        True => "true"
        False => "false"
        Null => "null"
        _ => value.stringify()
      }
      out.push((@utf8.encode(prefix), @utf8.encode(text)))
    }
  }
}

///|
/// Flatten a JSON object into `name=value` field pairs (the same Bytes model
/// as the kv ingest format). Nested objects are flattened with dotted names
/// (`request.user_id`), so structured logs keep nested fields addressable;
/// arrays serialize as compact JSON text. Non-object JSON yields an empty
/// array; malformed JSON raises ParseError (the caller decides whether to
/// keep the raw line). String values are kept verbatim; numbers, booleans and
/// null render as text.
pub fn json_object_fields(
  line : Bytes,
) -> Array[(Bytes, Bytes)] raise @json.ParseError {
  let text = @utf8.decode_lossy(line)
  let parsed = @json.parse(text)
  let out : Array[(Bytes, Bytes)] = []
  match parsed {
    Object(_) => flatten_json_value("", parsed, out)
    _ => ()
  }
  out
}
