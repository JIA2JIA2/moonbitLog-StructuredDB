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
