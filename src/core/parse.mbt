///|
/// Parse space-separated `name=value` pairs from a log line (logfmt). Empty
/// segments and segments without `=` are skipped; only the first `=` in a
/// segment separates the name from the value (values may contain further `=`).
/// A value may be double-quoted to carry spaces (`message="user login failed"`)
/// — spaces inside quotes never split segments and `\"` / `\\` unescape to
/// `"` / `\`. An unterminated quote keeps the rest of the line in the current
/// segment.
pub fn parse_kv_pairs(line : Bytes) -> Array[(Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes)] = []
  let mut start = 0
  let mut i = 0
  let mut in_quotes = false
  while i <= line.length() {
    if i == line.length() {
      if i > start {
        match split_kv_segment(slice(line, start, i)) {
          Some(pair) => out.push(pair)
          None => ()
        }
      }
      break
    }
    let c = line.at(i).to_int()
    if c == 92 && i + 1 < line.length() && line.at(i + 1).to_int() == 34 {
      // `\"` never opens or closes quoting: it stays inside the segment.
      i = i + 1
    } else if c == 34 {
      in_quotes = !in_quotes
    } else if !in_quotes && c == 32 {
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
/// A value wrapped in double quotes is unquoted with `\"` / `\\` unescaped
/// (logfmt); a bare value is kept byte-exactly.
fn split_kv_segment(seg : Bytes) -> (Bytes, Bytes)? {
  let mut i = 0
  while i < seg.length() {
    if seg.at(i).to_int() == 61 {
      let name = slice(seg, 0, i)
      let raw = slice(seg, i + 1, seg.length())
      if raw.length() >= 2 &&
        raw.at(0).to_int() == 34 &&
        raw.at(raw.length() - 1).to_int() == 34 {
        return Some((name, kv_unquote(slice(raw, 1, raw.length() - 1))))
      }
      return Some((name, raw))
    }
    i = i + 1
  }
  None
}

///|
/// Unescape `\"` to `"` and `\\` to `\` inside a quoted logfmt value. Values
/// without a backslash are returned as-is (no copy).
fn kv_unquote(inner : Bytes) -> Bytes {
  let mut i = 0
  let mut escaped = false
  while i < inner.length() {
    if inner.at(i).to_int() == 92 {
      escaped = true
      break
    }
    i = i + 1
  }
  if !escaped {
    return inner
  }
  let buf = @buffer.Buffer::Buffer()
  i = 0
  while i < inner.length() {
    let c = inner.at(i).to_int()
    if c == 92 && i + 1 < inner.length() {
      let next = inner.at(i + 1).to_int()
      if next == 34 || next == 92 {
        buf.write_byte(next.to_byte())
        i = i + 2
        continue
      }
    }
    buf.write_byte(c.to_byte())
    i = i + 1
  }
  buf.to_bytes()
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
/// Numeric level values follow the OTel severity_number bands (2.2):
/// 1-8 → debug(0), 9-12 → info(1), 13-16 → warn(2), 17-20 → error(3),
/// 21-24 → fatal(4); 0 and out-of-range numbers stay unknown (-1).
pub fn level_rank(level : Bytes) -> Int32 {
  level_rank_span(level, 0, level.length())
}

///|
/// Case-insensitive equality of `raw[start, end)` with `word`, without
/// allocating a slice (this runs per record on bulk ingest).
fn span_eq_ci(raw : Bytes, start : Int32, end : Int32, word : Bytes) -> Bool {
  if end - start != word.length() {
    return false
  }
  let mut k = 0
  while k < word.length() {
    if lower_ascii(raw.at(start + k).to_int()) !=
      lower_ascii(word.at(k).to_int()) {
      return false
    }
    k = k + 1
  }
  true
}

///|
/// Named-level rank for a span of a raw line. Covers the common syslog
/// severity words: `crit`/`critical`/`alert`/`emerg`/`panic` rank as fatal (4)
/// — they used to return -1 and be treated as unknown by every
/// `--level-min`/error-detection consumer. Comparisons are case-insensitive:
/// SDKs emit `DEBUG`/`INFO`/`WARN`/`ERROR` far more often than lowercase, and a
/// case-sensitive table silently made `--min-level` a no-op on those records.
fn level_rank_word(raw : Bytes, start : Int32, end : Int32) -> Int32 {
  if span_eq_ci(raw, start, end, b"debug") {
    0
  } else if span_eq_ci(raw, start, end, b"info") {
    1
  } else if span_eq_ci(raw, start, end, b"warn") ||
    span_eq_ci(raw, start, end, b"warning") {
    2
  } else if span_eq_ci(raw, start, end, b"error") ||
    span_eq_ci(raw, start, end, b"err") {
    3
  } else if span_eq_ci(raw, start, end, b"fatal") ||
    span_eq_ci(raw, start, end, b"critical") ||
    span_eq_ci(raw, start, end, b"crit") ||
    span_eq_ci(raw, start, end, b"alert") ||
    span_eq_ci(raw, start, end, b"emerg") ||
    span_eq_ci(raw, start, end, b"panic") {
    4
  } else {
    -1
  }
}

///|
/// Severity rank of `raw[start, end)` without slicing the line (the raw-line
/// fallback and leading-token detector run once per record).
fn level_rank_span(raw : Bytes, start : Int32, end : Int32) -> Int32 {
  let n = end - start
  if n >= 1 && n <= 2 {
    let mut all_digits = true
    let mut i = start
    while i < end {
      let c = raw.at(i).to_int()
      if c < 48 || c > 57 {
        all_digits = false
        i = end
      }
      i = i + 1
    }
    if all_digits {
      let v = if n == 1 {
        raw.at(start).to_int() - 48
      } else {
        (raw.at(start).to_int() - 48) * 10 + (raw.at(end - 1).to_int() - 48)
      }
      if v >= 1 && v <= 24 {
        if v <= 8 {
          0
        } else if v <= 12 {
          1
        } else if v <= 16 {
          2
        } else if v <= 20 {
          3
        } else {
          4
        }
      } else {
        -1
      }
    } else {
      level_rank_word(raw, start, end)
    }
  } else {
    level_rank_word(raw, start, end)
  }
}

///|
/// Number of level-field aliases consulted when `--level-field` is not given
/// explicitly.
const LEVEL_ALIAS_COUNT : Int32 = 6

///|
/// Level field spellings SDKs actually emit (OTel and common structured
/// loggers); flattened JSON paths such as `log.level` match by their trailing
/// segment too.
fn level_field_alias(i : Int32) -> Bytes {
  match i {
    0 => b"level"
    1 => b"lvl"
    2 => b"severity"
    3 => b"severity_text"
    4 => b"loglevel"
    5 => b"log.level"
    _ => b""
  }
}

///|
/// Case-insensitive equality of `raw[i, i+len(field))` with `field`, without
/// allocating a slice (this runs per byte over every line).
fn field_eq_ci_at(raw : Bytes, i : Int32, field : Bytes) -> Bool {
  let mut k = 0
  while k < field.length() {
    if lower_ascii(raw.at(i + k).to_int()) != lower_ascii(field.at(k).to_int()) {
      return false
    }
    k = k + 1
  }
  true
}

///|
/// Whether a parsed field name carries the level. An empty `configured` means
/// auto-detect (aliases above); an explicit `--level-field` matches that name
/// case-insensitively plus the trailing segment of a flattened JSON path
/// (`log.<name>`), but not arbitrary lookalikes such as `mylevel`.
fn level_field_matches(name : Bytes, configured : Bytes) -> Bool {
  if configured.length() > 0 {
    bytes_eq_ci(name, configured) ||
    (
      name.length() > configured.length() + 1 &&
      name.at(name.length() - configured.length() - 1).to_int() == 46 &&
      span_eq_ci(
        name,
        name.length() - configured.length(),
        name.length(),
        configured,
      )
    )
  } else {
    let mut i = 0
    let mut hit = false
    while i < LEVEL_ALIAS_COUNT && !hit {
      let cand = level_field_alias(i)
      if bytes_eq_ci(name, cand) ||
        (
          name.length() > cand.length() + 1 &&
          name.at(name.length() - cand.length() - 1).to_int() == 46 &&
          span_eq_ci(name, name.length() - cand.length(), name.length(), cand)
        ) {
        hit = true
      }
      i = i + 1
    }
    hit
  }
}

///|
/// Severity drawn from one `name=value` / `name:"value"` / `"name":"value"`
/// occurrence of `field` inside a raw line. Case-insensitive on the field name
/// (SDKs emit `Level=`/`LEVEL=`) and on the value (`level_rank`).
fn level_rank_for_field(raw_line : Bytes, field : Bytes) -> Int32 {
  let n = raw_line.length()
  let m = field.length()
  if m == 0 {
    return -1
  }
  let mut i = 0
  while i + m < n {
    if field_eq_ci_at(raw_line, i, field) {
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
          let rank = level_rank_span(raw_line, s, e)
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
/// Severity rank found directly in a raw line (`level=warn`, `level:"warn"`,
/// `"level":"warn"`). With no explicit `--level-field` every alias is tried.
/// Returns -1 when absent or unknown.
fn level_rank_in_line(raw_line : Bytes, level_field : Bytes) -> Int32 {
  // No `=`/`:` anywhere means no `name=value` or `"name":"value"` can exist:
  // skip the alias scans entirely and let the leading-token fallback handle a
  // plain `INFO message` line (six full scans per line is measurable on bulk
  // plain-text ingest).
  if !bytes_contains(raw_line, b"=") && !bytes_contains(raw_line, b":") {
    return -1
  }
  if level_field.length() > 0 {
    return level_rank_for_field(raw_line, level_field)
  }
  let mut i = 0
  while i < LEVEL_ALIAS_COUNT {
    let rank = level_rank_for_field(raw_line, level_field_alias(i))
    if rank >= 0 {
      return rank
    }
    i = i + 1
  }
  -1
}

///|
fn wrap_char(c : Int32) -> Bool {
  c == 91 || c == 93 || c == 40 || c == 41 || c == 58
}

///|
/// Severity from a leading plain-text level token (`ERROR ...`, `[WARN] ...`,
/// `INFO: ...`, after a timestamp). Only the first three whitespace-separated
/// tokens that consist solely of ASCII letters (after trimming `[]() :`) are
/// considered, so prose, numbers and timestamps are not mistaken for levels.
fn level_rank_at_head(raw_line : Bytes) -> Int32 {
  let n = raw_line.length()
  let mut i = 0
  let mut tokens = 0
  while i < n && tokens < 3 {
    while i < n &&
          (raw_line.at(i).to_int() == 32 || raw_line.at(i).to_int() == 9) {
      i = i + 1
    }
    let raw_start = i
    while i < n && raw_line.at(i).to_int() != 32 && raw_line.at(i).to_int() != 9 {
      i = i + 1
    }
    let mut start = raw_start
    let mut end = i
    while start < end && wrap_char(raw_line.at(start).to_int()) {
      start = start + 1
    }
    while end > start && wrap_char(raw_line.at(end - 1).to_int()) {
      end = end - 1
    }
    if end - start >= 3 && end - start <= 8 {
      let mut letters = true
      let mut k = start
      while k < end {
        let c = raw_line.at(k).to_int()
        if !((c >= 65 && c <= 90) || (c >= 97 && c <= 122)) {
          letters = false
          k = end
        }
        k = k + 1
      }
      if letters {
        let rank = level_rank_span(raw_line, start, end)
        if rank >= 0 {
          return rank
        }
      }
    }
    if end > start {
      tokens = tokens + 1
    }
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
/// Why the sampling pipeline dropped a line. `Rate` is the only reason that
/// depends on `--sample-rate`, so counting it separately lets callers report
/// the rate's observed keep percentage (1.5 "采样率实际生效") instead of a
/// combined figure that cannot distinguish level/rule filtering from sampling.
pub(all) enum SampleDrop {
  Include
  Exclude
  BelowLevel
  Rate
}

///|
/// Sampling decision for one line: it must pass the include rule (raw line
/// contains), the exclude rule (raw line does not contain), the minimum
/// severity, and the proportional sample rate. Returns the reason it was
/// dropped, or None when kept.
///
/// Severity lookup: parsed level fields are matched by name case-insensitively
/// and by common aliases (`severity`, `severity_text`, `lvl`, `loglevel`, and
/// the trailing segment of flattened JSON such as `log.level`) when
/// `--level-field` is not explicit; unknown severity values are never filtered
/// (a new level word must not silently drop data). Raw-line fallback handles
/// `level=WARN` / `Level:"WARN"` (case-insensitive) and a leading plain-text
/// token (`ERROR ...`, `[WARN] ...`).
pub fn sampling_reason(
  raw_line : Bytes,
  fields : Array[(Bytes, Bytes)],
  cfg : SamplingConfig,
) -> SampleDrop? {
  if cfg.include_text.length() > 0 &&
    !bytes_contains_ci(raw_line, cfg.include_text) {
    return Some(Include)
  }
  if cfg.exclude_text.length() > 0 &&
    bytes_contains_ci(raw_line, cfg.exclude_text) {
    return Some(Exclude)
  }
  if cfg.min_level >= 0 {
    let mut matched = false
    let mut field_rank = -1
    for pair in fields {
      if level_field_matches(pair.0, cfg.level_field) {
        matched = true
        let rank = level_rank(pair.1)
        if rank >= 0 {
          field_rank = rank
          if rank < cfg.min_level {
            return Some(BelowLevel)
          }
        }
      }
    }
    // Fields without a usable level (or no parsed fields at all): look in the
    // raw text, then at a leading plain-text level token.
    if !matched || field_rank < 0 {
      let mut rank = level_rank_in_line(raw_line, cfg.level_field)
      if rank < 0 {
        rank = level_rank_at_head(raw_line)
      }
      if rank >= 0 && rank < cfg.min_level {
        return Some(BelowLevel)
      }
    }
  }
  if !sample_passes(raw_line, cfg.sample_rate) {
    return Some(Rate)
  }
  None
}

///|
/// Whether the line passes every sampling rule (see `sampling_reason`).
pub fn sampling_allows(
  raw_line : Bytes,
  fields : Array[(Bytes, Bytes)],
  cfg : SamplingConfig,
) -> Bool {
  sampling_reason(raw_line, fields, cfg) is None
}

///|
/// One token of a placeholder pattern: a literal byte run, or a character
/// class with a quantifier. Compiling a pattern into tokens lets the matcher
/// handle multi-token Grok-style patterns (`\d+\.\d+\.\d+\.\d+`,
/// `\d+-\d+-\d+ \d+:\d+:\d+,\d+`) instead of silently falling back to a greedy
/// default capture — which parsed the line "successfully" while putting the
/// wrong bytes in the field (an accuracy report then looks green while every
/// value is wrong).
priv enum PatTok {
  Lit(Bytes)
  Class(Bytes, Int32, Int32, Bool)
}

///|
/// A compiled template placeholder. `<name>` captures up to the next literal
/// (the original M115 behavior). `<name:pattern>` compiles a restricted
/// Grok-style pattern into tokens: literal runs, `\d`/`\w`/`\s`/`\S`/`.`,
/// `[a-z]`/`[^...]` classes, and `?`/`*`/`+` (a trailing `?` makes it
/// non-greedy).
priv struct TemplateField {
  name : Bytes
  toks : Array[PatTok]
}

///|
/// Parse the quantifier that follows a class token: `?`, `*`, `+` (default one)
/// plus an optional `?` for non-greedy. Returns `(min, max, greedy, next)`.
fn pattern_quantifier(pat : Bytes, j : Int32) -> (Int32, Int32, Bool, Int32) {
  let mut min_len = 1
  let mut max_len = 1
  let mut greedy = true
  let mut k = j
  if k < pat.length() {
    let q = pat.at(k).to_int()
    if q == 63 {
      min_len = 0
      k = k + 1
    } else if q == 42 {
      min_len = 0
      max_len = -1
      k = k + 1
    } else if q == 43 {
      max_len = -1
      k = k + 1
    }
  }
  if k < pat.length() && pat.at(k).to_int() == 63 {
    greedy = false
    k = k + 1
  }
  (min_len, max_len, greedy, k)
}

///|
/// Compile a placeholder pattern into tokens. Returns None for a malformed
/// pattern (unterminated class, trailing backslash, or an unreasonable number
/// of tokens/quantifiers) so the caller falls back to the default capture
/// instead of guessing.
fn parse_pattern(pat : Bytes) -> Array[PatTok]? {
  let toks : Array[PatTok] = []
  let mut lit = @buffer.Buffer::Buffer()
  let mut i = 0
  let mut quantifiers = 0
  while i < pat.length() {
    let c = pat.at(i).to_int()
    if c == 91 {
      // `[...]` character class (escaped bytes inside do not close it).
      if lit.length() > 0 {
        toks.push(Lit(lit.to_bytes()))
        lit = @buffer.Buffer::Buffer()
      }
      let mut k = i + 1
      let mut closed = false
      while k < pat.length() {
        if pat.at(k).to_int() == 92 && k + 1 < pat.length() {
          k = k + 2
        } else if pat.at(k).to_int() == 93 {
          closed = true
          break
        } else {
          k = k + 1
        }
      }
      if !closed {
        return None
      }
      let (mn, mx, gr, next) = pattern_quantifier(pat, k + 1)
      toks.push(Class(slice(pat, i, k + 1), mn, mx, gr))
      if mn != 1 || mx != 1 {
        quantifiers = quantifiers + 1
      }
      i = next
    } else if c == 92 {
      if i + 1 >= pat.length() {
        return None
      }
      let k = pat.at(i + 1).to_int()
      if k == 100 || k == 119 || k == 115 || k == 83 {
        if lit.length() > 0 {
          toks.push(Lit(lit.to_bytes()))
          lit = @buffer.Buffer::Buffer()
        }
        let (mn, mx, gr, next) = pattern_quantifier(pat, i + 2)
        toks.push(Class(slice(pat, i, i + 2), mn, mx, gr))
        if mn != 1 || mx != 1 {
          quantifiers = quantifiers + 1
        }
        i = next
      } else {
        lit.write_byte(pat.at(i + 1))
        i = i + 2
      }
    } else if c == 46 {
      // `.` matches any byte; a literal dot must be escaped (`\.`).
      if lit.length() > 0 {
        toks.push(Lit(lit.to_bytes()))
        lit = @buffer.Buffer::Buffer()
      }
      let (mn, mx, gr, next) = pattern_quantifier(pat, i + 1)
      toks.push(Class(b".", mn, mx, gr))
      if mn != 1 || mx != 1 {
        quantifiers = quantifiers + 1
      }
      i = next
    } else {
      lit.write_byte(pat.at(i))
      i = i + 1
    }
    if toks.length() > 32 || quantifiers > 8 {
      // Keep backtracking bounded and predictable.
      return None
    }
  }
  if lit.length() > 0 {
    toks.push(Lit(lit.to_bytes()))
  }
  Some(toks)
}

///|
/// Split a placeholder body into name and compiled pattern tokens. An empty
/// token list means "default capture" (up to the next literal).
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
    return { name: body, toks: [], }
  }
  let name = slice(body, 0, colon)
  let pat = slice(body, colon + 1, body.length())
  if pat.length() == 0 {
    return { name, toks: [], }
  }
  match parse_pattern(pat) {
    Some(toks) => { name, toks, }
    None => { name, toks: [], }
  }
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
/// Greediness of a compiled pattern, taken from its last quantified class:
/// `\S+?` is non-greedy, `\d+` is greedy (the default). Used to choose whether
/// candidate capture windows are tried longest-first or shortest-first.
fn pattern_greedy(toks : Array[PatTok]) -> Bool {
  let mut i = toks.length() - 1
  while i >= 0 {
    match toks[i] {
      Class(_, _, _, gr) => return gr
      Lit(_) => i = i - 1
    }
  }
  true
}

///|
/// Match one placeholder at `pos`, given the literal that follows it (empty
/// for a trailing placeholder). Returns the captured end position.
fn lit_at(line : Bytes, pos : Int32, lit : Bytes) -> Bool {
  if pos + lit.length() > line.length() {
    return false
  }
  let mut j = 0
  while j < lit.length() {
    if line.at(pos + j).to_int() != lit.at(j).to_int() {
      return false
    }
    j = j + 1
  }
  true
}

///|
/// Match compiled tokens exactly against `line[pos, end)`. Greedy classes
/// consume as much as possible then backtrack; non-greedy the other way. The
/// token/quantifier count is bounded by `parse_pattern`, so failure cannot
/// explode exponentially on realistic templates.
fn pat_match_exact(
  line : Bytes,
  pos : Int32,
  end : Int32,
  toks : Array[PatTok],
  ti : Int32,
) -> Bool {
  if ti >= toks.length() {
    return pos == end
  }
  match toks[ti] {
    Lit(lit) =>
      if pos + lit.length() <= end && lit_at(line, pos, lit) {
        pat_match_exact(line, pos + lit.length(), end, toks, ti + 1)
      } else {
        false
      }
    Class(cls, mn, mx, gr) => {
      let mut maxp = pos
      while maxp < end &&
            (mx < 0 || maxp - pos < mx) &&
            template_class_matches(cls, line.at(maxp).to_int()) {
        maxp = maxp + 1
      }
      if maxp - pos < mn {
        return false
      }
      if gr {
        let mut p = maxp
        while p >= pos + mn {
          if pat_match_exact(line, p, end, toks, ti + 1) {
            return true
          }
          p = p - 1
        }
        false
      } else {
        let mut p = pos + mn
        while p <= maxp {
          if pat_match_exact(line, p, end, toks, ti + 1) {
            return true
          }
          p = p + 1
        }
        false
      }
    }
  }
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
  if field.toks.length() == 0 {
    // Default placeholder: capture up to the first occurrence of the next
    // literal, or to the end of the line when there is none.
    if next_literal.length() == 0 {
      return Some(line.length())
    }
    let n = next_literal.length()
    let mut scan = pos
    while scan + n <= line.length() {
      if lit_at(line, scan, next_literal) {
        return Some(scan)
      }
      scan = scan + 1
    }
    return None
  }
  if next_literal.length() == 0 {
    // A trailing pattern must consume the rest of the line.
    if pat_match_exact(line, pos, line.length(), field.toks, 0) {
      return Some(line.length())
    }
    // A lone `-` is the conventional missing value even at the end.
    if pos + 1 == line.length() && line.at(pos).to_int() == 45 {
      return Some(pos + 1)
    }
    return None
  }
  // Candidate ends are every occurrence of the next literal. A greedy pattern
  // tries the longest window first (a `\S+` capture stops at the last literal);
  // a non-greedy one tries the shortest first (`\S+?` stops at the first). Both
  // orders let a multi-token pattern span internal separators (a timestamp's
  // space, a dotted IP) instead of being cut at the first one.
  let n = next_literal.length()
  let ends : Array[Int32] = []
  let mut scan = pos
  while scan + n <= line.length() {
    if lit_at(line, scan, next_literal) {
      ends.push(scan)
    }
    scan = scan + 1
  }
  if pattern_greedy(field.toks) {
    let mut k = ends.length() - 1
    while k >= 0 {
      let e = ends[k]
      if pat_match_exact(line, pos, e, field.toks, 0) {
        return Some(e)
      }
      k = k - 1
    }
  } else {
    let mut k = 0
    while k < ends.length() {
      let e = ends[k]
      if pat_match_exact(line, pos, e, field.toks, 0) {
        return Some(e)
      }
      k = k + 1
    }
  }
  // Missing-value placeholder: nginx/apache write `-` where a numeric field has
  // no value. Accept it as the field value instead of dropping the whole line.
  if pos < line.length() && line.at(pos).to_int() == 45 {
    if pos + 1 == line.length() || lit_at(line, pos + 1, next_literal) {
      return Some(pos + 1)
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

///|
/// Locate the first balanced `{...}` object in a line, respecting JSON strings
/// and escapes. Used only when the whole line is not valid JSON: container
/// runtimes and syslog shippers wrap one JSON object in a timestamp/stream
/// prefix (or append text), which used to yield zero fields.
fn json_object_span(line : Bytes) -> (Int32, Int32)? {
  let mut start = -1
  let mut i = 0
  while i < line.length() {
    if line.at(i).to_int() == 123 {
      start = i
      break
    }
    i = i + 1
  }
  if start < 0 {
    return None
  }
  let mut depth = 0
  let mut in_str = false
  let mut esc = false
  let mut j = start
  while j < line.length() {
    let c = line.at(j).to_int()
    if in_str {
      if esc {
        esc = false
      } else if c == 92 {
        esc = true
      } else if c == 34 {
        in_str = false
      }
    } else if c == 34 {
      in_str = true
    } else if c == 123 {
      depth = depth + 1
    } else if c == 125 {
      depth = depth - 1
      if depth == 0 {
        return Some((start, j + 1))
      }
    }
    j = j + 1
  }
  None
}

///|
/// Parse one JSON line into flattened `name=value` fields. Non-object JSON
/// yields an empty array; malformed JSON raises ParseError (the caller decides
/// whether to keep the raw line). A line that is not wholly JSON is retried on
/// its first balanced object, so a wrapper prefix/suffix does not drop every
/// field.
pub fn json_object_fields(
  line : Bytes,
) -> Array[(Bytes, Bytes)] raise @json.ParseError {
  let out : Array[(Bytes, Bytes)] = []
  let direct : Json? = Some(@json.parse(@utf8.decode_lossy(line))) catch {
    _ => None
  }
  match direct {
    Some(parsed) => {
      match parsed {
        Object(_) => flatten_json_value("", parsed, out)
        _ => ()
      }
      out
    }
    None =>
      match json_object_span(line) {
        Some((start, end)) => {
          let parsed = @json.parse(@utf8.decode_lossy(slice(line, start, end))) catch {
            _ => raise @json.ParseError::InvalidEof
          }
          match parsed {
            Object(_) => flatten_json_value("", parsed, out)
            _ => ()
          }
          out
        }
        None => raise @json.ParseError::InvalidEof
      }
  }
}
