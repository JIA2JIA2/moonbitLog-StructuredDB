///|
/// A parsed HTTP/1.x request head. `authorization` carries the raw
/// `Authorization:` header value (6.2: the `Bearer <token>` credential the
/// push endpoint authenticates against RBAC), empty when absent.
pub(all) struct HttpRequest {
  verb : Bytes
  path : Bytes
  content_length : Int32
  authorization : Bytes
  // 1.4 batch id: raw `X-Batch-Id:` header value (empty when absent) — a
  // confirmed batch id is replayed as a no-op so client retries never
  // duplicate data.
  batch_id : Bytes
  // `Transfer-Encoding: chunked`: the body has no Content-Length and must be
  // de-framed before it is parsed as log lines. Treating the chunk framing as
  // payload used to land garbage records in the store with a 202 response.
  chunked : Bool
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
  let mut batch_id : Bytes = b""
  let mut chunked = false
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
    } else if has_ci_prefix_http(line, b"x-batch-id:") {
      let mut v = 11
      while v < line.length() && line.at(v).to_int() == 32 {
        v = v + 1
      }
      batch_id = slice(line, v, line.length())
    } else if has_ci_prefix_http(line, b"transfer-encoding:") {
      let mut v = 18
      while v < line.length() && line.at(v).to_int() == 32 {
        v = v + 1
      }
      if has_ci_token_http(line, v, b"chunked") {
        chunked = true
      }
    }
    pos = end + 1
  }
  Some({
    verb: parts[0],
    path: parts[1],
    content_length,
    authorization,
    batch_id,
    chunked,
  })
}

///|
/// Result of de-framing a chunked body. `NeedMore` means the buffer does not
/// yet hold a whole body (read another chunk); `Malformed` is a framing error
/// and must be rejected instead of being parsed as data.
pub(all) enum ChunkedBody {
  Complete(Bytes)
  NeedMore
  Malformed
}

///|
/// Decode an HTTP/1.1 chunked body: `<hex-size>[;ext]\r\n<data>\r\n` repeated,
/// terminated by a zero-size chunk. Chunk extensions and trailer headers are
/// ignored; the returned payload carries no framing bytes.
pub fn decode_chunked_body(data : Bytes) -> ChunkedBody {
  let out = @buffer.Buffer::Buffer()
  let mut pos = 0
  let mut total = 0
  while true {
    let size_end = find_crlf_http(data, pos)
    if size_end < 0 {
      // A size line longer than this cannot be a valid hex chunk size; fail
      // fast instead of buffering an unbounded "line".
      if data.length() - pos > 64 {
        return Malformed
      }
      return NeedMore
    }
    let mut size = 0
    let mut saw_digit = false
    let mut i = pos
    while i < size_end {
      let c = data.at(i).to_int()
      if c == 59 {
        // ';' starts a chunk extension: the rest of the size line is metadata.
        i = size_end
      } else {
        let d = hex_value_http(c)
        if d < 0 {
          // Tolerate surrounding spaces (some clients pad), nothing else.
          if c != 32 {
            return Malformed
          }
          i = i + 1
        } else {
          saw_digit = true
          size = size * 16 + d
          if size > 1_048_576 {
            return Malformed
          }
          i = i + 1
        }
      }
    }
    if !saw_digit {
      return Malformed
    }
    if size == 0 {
      // Zero chunk: the payload is complete (trailers are not needed).
      return Complete(out.to_bytes())
    }
    let data_start = size_end + 2
    if data_start + size + 2 > data.length() {
      return NeedMore
    }
    if data.at(data_start + size).to_int() != 13 ||
      data.at(data_start + size + 1).to_int() != 10 {
      return Malformed
    }
    out.write_bytes(slice(data, data_start, data_start + size))
    total = total + size
    if total > 1_048_576 {
      return Malformed
    }
    pos = data_start + size + 2
  }
  Complete(out.to_bytes())
}

///|
fn hex_value_http(c : Int32) -> Int32 {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 97 && c <= 102 {
    c - 97 + 10
  } else if c >= 65 && c <= 70 {
    c - 65 + 10
  } else {
    -1
  }
}

///|
fn find_crlf_http(data : Bytes, from : Int32) -> Int32 {
  let mut i = from
  while i + 1 < data.length() {
    if data.at(i).to_int() == 13 && data.at(i + 1).to_int() == 10 {
      return i
    }
    i = i + 1
  }
  -1
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

///|
fn has_ci_token_http(data : Bytes, from : Int32, needle : Bytes) -> Bool {
  let mut i = from
  while i + needle.length() <= data.length() {
    let mut j = 0
    let mut ok = true
    while j < needle.length() && ok {
      if lower_ascii(data.at(i + j).to_int()) !=
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
