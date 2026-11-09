///|
let sensitive_names : Array[Bytes] = [
  b"password", b"passwd", b"pwd", b"secret", b"secret_key", b"token", b"api_key",
  b"apikey", b"access_key", b"authorization", b"auth", b"credential", b"credentials",
  b"session", b"session_id", b"sessionid", b"cookie", b"private_key",
]

///|
let redacted_marker : Bytes = b"[REDACTED]"

///|
fn lower_byte(c : Int32) -> Int32 {
  if c >= 65 && c <= 90 {
    c + 32
  } else {
    c
  }
}

///|
fn is_digit_c(c : Int32) -> Bool {
  c >= 48 && c <= 57
}

///|
fn is_hex_c(c : Int32) -> Bool {
  (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
}

///|
fn is_word_c(c : Int32) -> Bool {
  (c >= 48 && c <= 57) ||
  (c >= 65 && c <= 90) ||
  (c >= 97 && c <= 122) ||
  c == 95
}

///|
fn is_token_c(c : Int32) -> Bool {
  is_word_c(c) || c == 45 || c == 46
}

///|
/// ASCII case-insensitive byte equality.
fn bytes_eq_ci(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if lower_byte(a.at(i).to_int()) != lower_byte(b.at(i).to_int()) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Value start position when `b` at `i` begins a sensitive field name
/// followed by `=` or `:`. JSON shapes (`"token":"..."`, `"token": "..."`)
/// and a closing quote after the key are accepted; an opening quote of the
/// value, when present, is consumed. Returns None when this position is not
/// such a field.
fn field_value_start(b : Bytes, i : Int32, name : Bytes) -> Int32? {
  if i > 0 && is_word_c(b.at(i - 1).to_int()) {
    return None
  }
  let n = name.length()
  if i + n > b.length() {
    return None
  }
  let mut j = i
  while j < i + n {
    if lower_byte(b.at(j).to_int()) != lower_byte(name.at(j - i).to_int()) {
      return None
    }
    j = j + 1
  }
  if j < b.length() && b.at(j).to_int() == 34 {
    j = j + 1
  }
  while j < b.length() && b.at(j).to_int() == 32 {
    j = j + 1
  }
  if j >= b.length() {
    return None
  }
  let sep = b.at(j).to_int()
  if sep != 61 && sep != 58 {
    return None
  }
  j = j + 1
  // JSON allows spaces after the colon; after `=` a leading space means an
  // empty value (kept as-is, as before).
  if sep == 58 {
    while j < b.length() && b.at(j).to_int() == 32 {
      j = j + 1
    }
  }
  if j < b.length() && b.at(j).to_int() == 34 {
    j = j + 1
  }
  Some(j)
}

///|
/// True when `b` at `i` is the standalone word `Bearer` followed by one
/// space and a token run of at least 8 characters.
fn bearer_at(b : Bytes, i : Int32) -> Bool {
  if i > 0 && is_word_c(b.at(i - 1).to_int()) {
    return false
  }
  if i + 7 >= b.length() {
    return false
  }
  if !bytes_eq_ci(slice(b, i, i + 6), b"bearer") {
    return false
  }
  if b.at(i + 6).to_int() != 32 {
    return false
  }
  let mut j = i + 7
  while j < b.length() && is_token_c(b.at(j).to_int()) {
    j = j + 1
  }
  j - (i + 7) >= 8
}

///|
/// True when `b` at `i` looks like the start of a JWT (`eyJ` prefix outside
/// a larger token run).
fn jwt_start_at(b : Bytes, i : Int32) -> Bool {
  if i + 3 > b.length() {
    return false
  }
  if i > 0 && is_token_c(b.at(i - 1).to_int()) {
    return false
  }
  lower_byte(b.at(i).to_int()) == 101 &&
  lower_byte(b.at(i + 1).to_int()) == 121 &&
  lower_byte(b.at(i + 2).to_int()) == 106
}

///|
/// Length of a known provider secret starting at `b[i]` (`sk-…`, `AKIA…`,
/// `ghp_…`, `github_pat_…`, `xox?-…`), or 0. Prefix-specific minimum lengths
/// keep ordinary hyphenated identifiers such as `disk-usage-report` intact.
fn provider_secret_len(b : Bytes, i : Int32) -> Int32 {
  if i > 0 && is_token_c(b.at(i - 1).to_int()) {
    return 0
  }
  let len = b.length()
  // sk- (OpenAI/Anthropic style): prefix + >=16 token chars.
  if i + 3 <= len &&
    b.at(i).to_int() == 115 &&
    b.at(i + 1).to_int() == 107 &&
    b.at(i + 2).to_int() == 45 {
    let mut j = i + 3
    while j < len && is_token_c(b.at(j).to_int()) {
      j = j + 1
    }
    if j - i >= 19 {
      return j - i
    }
  }
  // AWS access key id: AKIA + >=16 alphanumerics.
  if i + 4 <= len &&
    b.at(i).to_int() == 65 &&
    b.at(i + 1).to_int() == 75 &&
    b.at(i + 2).to_int() == 73 &&
    b.at(i + 3).to_int() == 65 {
    let mut j = i + 4
    let mut n = 0
    while j < len && is_word_c(b.at(j).to_int()) {
      j = j + 1
      n = n + 1
    }
    if n >= 16 {
      return j - i
    }
  }
  // GitHub: ghp_/gho_/ghs_/ghu_ + >=20, github_pat_ + >=20.
  if i + 4 <= len &&
    b.at(i).to_int() == 103 &&
    b.at(i + 1).to_int() == 104 &&
    b.at(i + 3).to_int() == 95 {
    let k = b.at(i + 2).to_int()
    if k == 112 || k == 111 || k == 115 || k == 117 {
      let mut j = i + 4
      while j < len && is_token_c(b.at(j).to_int()) {
        j = j + 1
      }
      if j - i >= 24 {
        return j - i
      }
    }
  }
  if i + 11 <= len && bytes_eq_ci(slice(b, i, i + 11), b"github_pat_") {
    let mut j = i + 11
    while j < len && is_token_c(b.at(j).to_int()) {
      j = j + 1
    }
    if j - i >= 31 {
      return j - i
    }
  }
  // Slack: xoxb-/xoxp-/xoxa-/xoxr-/xoxs- + >=10.
  if i + 5 <= len &&
    b.at(i).to_int() == 120 &&
    b.at(i + 1).to_int() == 111 &&
    b.at(i + 2).to_int() == 120 &&
    b.at(i + 4).to_int() == 45 {
    let k = b.at(i + 3).to_int()
    if k == 98 || k == 112 || k == 97 || k == 114 || k == 115 {
      let mut j = i + 5
      while j < len && is_token_c(b.at(j).to_int()) {
        j = j + 1
      }
      if j - i >= 15 {
        return j - i
      }
    }
  }
  0
}

///|
/// Mask sensitive content in a log value before it is written (2.4). Single
/// scan, no regex engine; every byte that is not part of a match is copied
/// verbatim. A `name=value` segment whose field name is in the built-in
/// sensitive list (password/secret/token/api_key/authorization/...) or in
/// `extra` (ASCII case-insensitive) becomes `name=[REDACTED]`; `Bearer <t>`
/// runs (token >= 8 chars) and JWT-shaped runs (`eyJ` prefix, two dots)
/// become `[REDACTED]`; an 11-digit CN mobile number keeps 3+4 digits
/// (`138****5678`); a 15-digit or 17-digit+X ID number keeps first 3 / last
/// 4; a hex run of 20+ chars (md5/sha1/sha256 — UUID segments and epoch
/// nanoseconds stay below the bar) becomes `[REDACTED]`.
pub fn mask_sensitive(value : Bytes, extra : Array[Bytes]) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  let len = value.length()
  let names : Array[Bytes] = []
  for nm in sensitive_names {
    names.push(nm)
  }
  for nm in extra {
    names.push(nm)
  }
  let mut i = 0
  while i < len {
    // 1. sensitive field name=value → name=[REDACTED]
    let mut matched = false
    for name in names {
      match field_value_start(value, i, name) {
        Some(vstart) => {
          // Quoted JSON values run to the closing quote; bare values run to a
          // space, comma or closing brace.
          let quoted = vstart > 0 && value.at(vstart - 1).to_int() == 34
          let mut j = vstart
          if quoted {
            while j < len && value.at(j).to_int() != 34 {
              j = j + 1
            }
          } else {
            while j < len {
              let c = value.at(j).to_int()
              if c == 32 || c == 44 || c == 125 {
                break
              }
              j = j + 1
            }
          }
          if j > vstart {
            out.write_bytes(slice(value, i, vstart))
            out.write_bytes(redacted_marker)
            i = j
            matched = true
          }
        }
        None => ()
      }
      if matched {
        break
      }
    }
    if matched {
      continue
    }
    // 2. Bearer <token> → Bearer [REDACTED]
    if bearer_at(value, i) {
      let mut j = i + 7
      while j < len && is_token_c(value.at(j).to_int()) {
        j = j + 1
      }
      out.write_bytes(slice(value, i, i + 7))
      out.write_bytes(redacted_marker)
      i = j
      continue
    }
    // 3. Known provider secret prefixes → [REDACTED]
    let plen = provider_secret_len(value, i)
    if plen > 0 {
      out.write_bytes(redacted_marker)
      i = i + plen
      continue
    }
    // 4. JWT (eyJ...d.d.s) → [REDACTED]
    if jwt_start_at(value, i) {
      let mut j = i
      let mut dots = 0
      while j < len && is_token_c(value.at(j).to_int()) {
        if value.at(j).to_int() == 46 {
          dots = dots + 1
        }
        j = j + 1
      }
      if dots >= 2 {
        out.write_bytes(redacted_marker)
        i = j
        continue
      }
    }
    // 4. numeric/hex runs
    if is_hex_c(value.at(i).to_int()) {
      let prev_hex = i > 0 && is_hex_c(value.at(i - 1).to_int())
      if !prev_hex {
        let mut j = i
        let mut all_digit = true
        while j < len && is_hex_c(value.at(j).to_int()) {
          if !is_digit_c(value.at(j).to_int()) {
            all_digit = false
          }
          j = j + 1
        }
        let l = j - i
        let mobile = all_digit &&
          l == 11 &&
          value.at(i).to_int() == 49 &&
          value.at(i + 1).to_int() >= 51 &&
          value.at(i + 1).to_int() <= 57
        let id15 = all_digit && l == 15
        let id18 = all_digit &&
          l == 17 &&
          j < len &&
          lower_byte(value.at(j).to_int()) == 120
        if mobile {
          out.write_bytes(slice(value, i, i + 3))
          out.write_bytes(b"****")
          out.write_bytes(slice(value, i + 7, j))
          i = j
          continue
        }
        if id15 {
          out.write_bytes(slice(value, i, i + 3))
          out.write_bytes(b"********")
          out.write_bytes(slice(value, i + 11, j))
          i = j
          continue
        }
        if id18 {
          out.write_bytes(slice(value, i, i + 3))
          out.write_bytes(b"***********")
          out.write_bytes(slice(value, i + 14, i + 17))
          out.write_bytes(slice(value, j, j + 1))
          i = j + 1
          continue
        }
        if l >= 20 {
          out.write_bytes(redacted_marker)
          i = j
          continue
        }
        out.write_bytes(slice(value, i, j))
        i = j
        continue
      }
    }
    // 5. verbatim byte
    out.write_byte(value.at(i))
    i = i + 1
  }
  out.to_bytes()
}
