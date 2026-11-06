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
/// True when `b` at `i` starts with `name` (ASCII case-insensitive) followed
/// by `=`, with a word boundary before `name`.
fn field_at(b : Bytes, i : Int32, name : Bytes) -> Bool {
  if i > 0 && is_word_c(b.at(i - 1).to_int()) {
    return false
  }
  let n = name.length()
  if i + n + 1 > b.length() {
    return false
  }
  let mut j = 0
  while j < n {
    if lower_byte(b.at(i + j).to_int()) != lower_byte(name.at(j).to_int()) {
      return false
    }
    j = j + 1
  }
  b.at(i + n).to_int() == 61
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
      if field_at(value, i, name) {
        let vstart = i + name.length() + 1
        let mut j = vstart
        while j < len && value.at(j).to_int() != 32 {
          j = j + 1
        }
        if j > vstart {
          out.write_bytes(slice(value, i, vstart))
          out.write_bytes(redacted_marker)
          i = j
          matched = true
        }
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
    // 3. JWT (eyJ...d.d.s) → [REDACTED]
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
