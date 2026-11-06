///|
/// True when a log value looks like one line of a multi-line stack trace,
/// so it can be merged into the cluster of the exception header that
/// precedes it (5.2). Recognized shapes (after trimming):
/// - Java frame: `at com.foo.Bar.m(Bar.java:12)` — "at " prefix plus a
///   "(...:...)" parenthesized location;
/// - Python frame: `File "/app/x.py", line 42, in foo`;
/// - exception-chain head: `Caused by: <anything>` — it continues the same
///   stack cluster rather than opening a new one.
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
  let at_i = i + 3
  // Java frame: "at " prefix
  if value.at(i).to_int() == 97 &&
    value.at(i + 1).to_int() == 116 &&
    value.at(i + 2).to_int() == 32 &&
    len > 6 {
    // requires a "(...:...)" location somewhere after the "at "
    let mut has_paren = false
    let mut has_colon = false
    let mut j = at_i
    while j < e {
      let c = value.at(j).to_int()
      if c == 40 {
        has_paren = true
      }
      if c == 58 {
        has_colon = true
      }
      j = j + 1
    }
    if has_paren && has_colon {
      return true
    }
  }
  // Python frame: File "..." prefix
  if e - i > 6 &&
    value.at(i).to_int() == 70 &&
    value.at(i + 1).to_int() == 105 &&
    value.at(i + 2).to_int() == 108 &&
    value.at(i + 3).to_int() == 101 &&
    value.at(i + 4).to_int() == 32 &&
    value.at(i + 5).to_int() == 34 {
    return true
  }
  // Exception chain: "Caused by: ..."
  if len > 11 &&
    value.at(i).to_int() == 67 &&
    value.at(i + 1).to_int() == 97 &&
    value.at(i + 2).to_int() == 117 &&
    value.at(i + 3).to_int() == 115 &&
    value.at(i + 4).to_int() == 101 &&
    value.at(i + 5).to_int() == 100 &&
    value.at(i + 6).to_int() == 32 &&
    value.at(i + 7).to_int() == 98 &&
    value.at(i + 8).to_int() == 121 &&
    value.at(i + 9).to_int() == 58 {
    return true
  }
  false
}
