///|
fn wc_char_eq(a : Int32, b : Int32, ignore_case : Bool) -> Bool {
  if a == b {
    true
  } else if ignore_case {
    let la = if a >= 65 && a <= 90 { a + 32 } else { a }
    let lb = if b >= 65 && b <= 90 { b + 32 } else { b }
    la == lb
  } else {
    false
  }
}

///|
/// Full-string wildcard match over `[ts, te)` of text against `[ps, pe)` of
/// pattern: `*` matches any byte sequence (including empty), `?` matches
/// exactly one byte, every other pattern byte matches itself (ASCII
/// case-folded when `ignore_case`). Greedy two-pointer with backtracking to
/// the last `*` — the classic linear-space wildcard matcher, no regex engine.
fn wc_match(
  text : Bytes,
  ts : Int32,
  te : Int32,
  pattern : Bytes,
  ps : Int32,
  pe : Int32,
  ignore_case : Bool,
) -> Bool {
  let mut s = ts
  let mut p = ps
  let mut star : Int32 = -1
  let mut sstar : Int32 = -1
  while s < te {
    let mut matched = false
    if p < pe {
      let pc = pattern.at(p).to_int()
      if pc == 42 {
        // '*' — remember position, try to consume as little as possible.
        star = p
        sstar = s
        p = p + 1
        matched = true
      } else if pc == 63 {
        // '?' — consume exactly one byte.
        s = s + 1
        p = p + 1
        matched = true
      } else if wc_char_eq(pc, text.at(s).to_int(), ignore_case) {
        s = s + 1
        p = p + 1
        matched = true
      }
    }
    if !matched {
      if star >= 0 {
        // Pattern exhausted or byte mismatch: let the last '*' absorb one
        // more byte and retry from just after it.
        p = star + 1
        sstar = sstar + 1
        s = sstar
      } else {
        return false
      }
    }
  }
  while p < pe && pattern.at(p).to_int() == 42 {
    p = p + 1
  }
  p == pe
}

///|
/// Wildcard substring match (4.1): the pattern matches any substring of
/// `text`. `*` matches any byte sequence (including empty), `?` matches
/// exactly one byte, other bytes match themselves — ASCII case-folded when
/// `ignore_case`. Multi-byte UTF-8 (Chinese and any other script)
/// participates byte-wise, so literal CJK patterns work unchanged; the
/// pattern bytes that are not `*`/`?` behave like the substring `search`.
/// Implemented by wrapping the pattern in `*` on both sides and running the
/// greedy full-string matcher.
pub fn wildcard_contains(
  text : Bytes,
  pattern : Bytes,
  ignore_case : Bool,
) -> Bool {
  let full = @buffer.Buffer::Buffer()
  full.write_byte(b'*')
  full.write_bytes(pattern)
  full.write_byte(b'*')
  let fp = full.to_bytes()
  wc_match(text, 0, text.length(), fp, 0, fp.length(), ignore_case)
}
