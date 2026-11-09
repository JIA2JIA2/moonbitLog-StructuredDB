///|
/// True when `value[start, end)` begins with `prefix`.
fn starts_at(value : Bytes, start : Int32, end : Int32, prefix : Bytes) -> Bool {
  if start + prefix.length() > end {
    return false
  }
  let mut k = 0
  while k < prefix.length() {
    if value.at(start + k).to_int() != prefix.at(k).to_int() {
      return false
    }
    k = k + 1
  }
  true
}

///|
/// True when `value[start, end)` ends with `suffix`.
fn ends_at(value : Bytes, start : Int32, end : Int32, suffix : Bytes) -> Bool {
  if end - start < suffix.length() {
    return false
  }
  let mut k = 0
  while k < suffix.length() {
    if value.at(end - suffix.length() + k).to_int() != suffix.at(k).to_int() {
      return false
    }
    k = k + 1
  }
  true
}

///|
/// True when a log value looks like one line of a multi-line stack trace,
/// so it can be merged into the cluster of the exception header that
/// precedes it (5.2). Recognized shapes (after trimming):
/// - Java / .NET / Node frame: `at com.foo.Bar.m(Bar.java:12)` — "at "
///   prefix plus a "(...:...)" parenthesized location;
/// - Python frame: `File "/app/x.py", line 42, in foo`;
/// - Rust frame: `at ./src/main.rs:12:5` (no parentheses), `   0:
///   std::panicking::begin_panic`;
/// - Go frame: `goroutine 1 [running]:`, `created by main.main`,
///   `main.handler(0xc0000140a0)`, or a `.../x.go:12 +0x1d` line;
/// - exception-chain lines: `Caused by: ...`, `Suppressed: ...`, and the
///   JVM tail `... 23 more` — they continue the same cluster rather than
///   opening a new one.
pub fn is_stack_frame(value : Bytes) -> Bool {
  let n = value.length()
  // trim leading spaces/tabs
  let mut i = 0
  while i < n {
    let c = value.at(i).to_int()
    if c == 32 || c == 9 {
      i = i + 1
    } else {
      break
    }
  }
  // trim trailing whitespace
  let mut e = n
  while e > i {
    let c = value.at(e - 1).to_int()
    if c == 32 || c == 9 || c == 13 {
      e = e - 1
    } else {
      break
    }
  }
  let len = e - i
  if len < 4 {
    return false
  }
  let part = slice(value, i, e)
  // Java / .NET / Node frame: "at " with a "(...:...)" location.
  if starts_at(value, i, e, b"at ") {
    let has_paren = bytes_contains(part, b"(")
    let has_colon = bytes_contains(part, b":")
    if has_paren && has_colon {
      return true
    }
    // Rust backtrace location: "at ./src/main.rs:12:5" (no parentheses).
    if has_colon && (bytes_contains(part, b"/") || bytes_contains(part, b".")) {
      return true
    }
  }
  // Python frame: File "..." prefix
  if starts_at(value, i, e, b"File \"") {
    return true
  }
  // Exception chain: "Caused by: ..." and "Suppressed: ...".
  if starts_at(value, i, e, b"Caused by: ") ||
    starts_at(value, i, e, b"Suppressed: ") {
    return true
  }
  // Go runtime backtrace.
  if starts_at(value, i, e, b"goroutine ") && bytes_contains(part, b"[") {
    return true
  }
  if starts_at(value, i, e, b"created by ") {
    return true
  }
  if bytes_contains(part, b"+0x") && bytes_contains(part, b".go:") {
    return true
  }
  if bytes_contains(part, b"(0x") {
    return true
  }
  // Rust numbered frame: "   0: std::panicking::begin_panic".
  let mut d = i
  while d < e {
    let c = value.at(d).to_int()
    if c >= 48 && c <= 57 {
      d = d + 1
    } else {
      break
    }
  }
  if d > i &&
    d + 2 <= e &&
    value.at(d).to_int() == 58 &&
    value.at(d + 1).to_int() == 32 &&
    bytes_contains(slice(value, d + 2, e), b"::") {
    return true
  }
  // JVM omitted-frames tail: "... 23 more".
  if starts_at(value, i, e, b"... ") && ends_at(value, i, e, b" more") {
    return true
  }
  false
}
