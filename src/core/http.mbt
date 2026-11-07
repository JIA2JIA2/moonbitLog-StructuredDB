///|
/// A parsed HTTP/1.x request head. `authorization` carries the raw
/// `Authorization:` header value (6.2: the `Bearer <token>` credential the
/// push endpoint authenticates against RBAC), empty when absent.
pub(all) struct HttpRequest {
  verb : Bytes
  path : Bytes
  content_length : Int32
  authorization : Bytes
}

///|
/// Parse the head of an HTTP/1.x request (the bytes up to and including the
/// blank line). Returns None when the request line is malformed. Header names
/// compare case-insensitively; `Content-Length` defaults to 0 and
/// `Authorization` to empty when absent or unparsable.
pub fn parse_http_request(head : Bytes) -> HttpRequest? {
  let first_end = find_byte_http(head, 10, 0)
  if first_end < 0 {
    return None
  }
  let first_len = trim_cr_http(head, 0, first_end)
  let parts = split_spaces_http(slice(head, 0, first_len))
  if parts.length() < 2 {
    return None
  }
  let mut content_length = 0
  let mut authorization : Bytes = b""
  let mut pos = first_end + 1
  while pos < head.length() {
    let end = find_byte_http(head, 10, pos)
    if end < 0 {
      break
    }
    let line_len = trim_cr_http(head, pos, end)
    let line = slice(head, pos, line_len)
    if line.length() == 0 {
      break
    }
    if has_ci_prefix_http(line, b"content-length:") {
      let mut v = 15
      while v < line.length() && line.at(v).to_int() == 32 {
        v = v + 1
      }
      let mut num = 0
      while v < line.length() &&
            line.at(v).to_int() >= 48 &&
            line.at(v).to_int() <= 57 {
        num = num * 10 + (line.at(v).to_int() - 48)
        v = v + 1
      }
      content_length = num
    } else if has_ci_prefix_http(line, b"authorization:") {
      let mut v = 14
      while v < line.length() && line.at(v).to_int() == 32 {
        v = v + 1
      }
      authorization = slice(line, v, line.length())
    }
    pos = end + 1
  }
  Some({ verb: parts[0], path: parts[1], content_length, authorization, })
}

///|
fn find_byte_http(data : Bytes, target : Int32, from : Int32) -> Int32 {
  let mut i = from
  while i < data.length() {
    if data.at(i).to_int() == target {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// `end` with a trailing CR trimmed (the LF itself is excluded by the caller).
fn trim_cr_http(data : Bytes, start : Int32, end : Int32) -> Int32 {
  if end > start && data.at(end - 1).to_int() == 13 {
    end - 1
  } else {
    end
  }
}

///|
fn split_spaces_http(data : Bytes) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let mut start = 0
  let mut i = 0
  while i <= data.length() {
    if i == data.length() || data.at(i).to_int() == 32 {
      if i > start {
        out.push(slice(data, start, i))
      }
      start = i + 1
    }
    i = i + 1
  }
  out
}

///|
fn has_ci_prefix_http(data : Bytes, prefix : Bytes) -> Bool {
  if data.length() < prefix.length() {
    return false
  }
  let mut i = 0
  while i < prefix.length() {
    if lower_ascii(data.at(i).to_int()) != lower_ascii(prefix.at(i).to_int()) {
      return false
    }
    i = i + 1
  }
  true
}
