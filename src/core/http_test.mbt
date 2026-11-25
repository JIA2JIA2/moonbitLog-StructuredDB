///|
test "parse_http_request extracts method path and content length" {
  let head = b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n"
  match @core.parse_http_request(head) {
    Some(r) => {
      assert_eq(r.verb, b"POST")
      assert_eq(r.path, b"/")
      assert_eq(r.content_length, 12)
    }
    None => panic()
  }
  let get = b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
  match @core.parse_http_request(get) {
    Some(r) => {
      assert_eq(r.verb, b"GET")
      assert_eq(r.path, b"/health")
      assert_eq(r.content_length, 0)
    }
    None => panic()
  }
  // Header names are case-insensitive.
  let lower = b"POST /push HTTP/1.1\r\ncontent-length: 7\r\n\r\n"
  match @core.parse_http_request(lower) {
    Some(r) => {
      assert_eq(r.path, b"/push")
      assert_eq(r.content_length, 7)
    }
    None => panic()
  }
}

///|
test "parse_http_request extracts the authorization header" {
  let head = b"POST / HTTP/1.1\r\nAuthorization: Bearer tok-1\r\nContent-Length: 0\r\n\r\n"
  match @core.parse_http_request(head) {
    Some(r) => {
      assert_eq(r.authorization, b"Bearer tok-1")
      assert_eq(r.verb, b"POST")
      assert_eq(r.content_length, 0)
    }
    None => panic()
  }
  // Header names are case-insensitive; a missing header yields empty bytes.
  let lower = b"POST /push HTTP/1.1\r\nauthorization: Bearer tok-2\r\n\r\n"
  match @core.parse_http_request(lower) {
    Some(r) => assert_eq(r.authorization, b"Bearer tok-2")
    None => panic()
  }
  match @core.parse_http_request(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n") {
    Some(r) => assert_eq(r.authorization, b"")
    None => panic()
  }
}

///|
test "parse_http_request detects chunked transfer encoding" {
  match
    @core.parse_http_request(
      b"POST /push HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
    ) {
    Some(r) => assert_eq(r.chunked, true)
    None => panic()
  }
  // Header name and token compare case-insensitively.
  match
    @core.parse_http_request(
      b"POST / HTTP/1.1\r\nTRANSFER-ENCODING: Chunked\r\n\r\n",
    ) {
    Some(r) => assert_eq(r.chunked, true)
    None => panic()
  }
  // A non-chunked encoding does not change body framing.
  match
    @core.parse_http_request(
      b"POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n",
    ) {
    Some(r) => assert_eq(r.chunked, false)
    None => panic()
  }
  match @core.parse_http_request(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n") {
    Some(r) => assert_eq(r.chunked, false)
    None => panic()
  }
}

///|
test "decode_chunked_body de-frames multi-chunk payloads" {
  match @core.decode_chunked_body(b"3\r\nl1\n\r\n3\r\nl2\n\r\n0\r\n\r\n") {
    @core.ChunkedBody::Complete(d) => assert_eq(d, b"l1\nl2\n")
    _ => panic()
  }
}

///|
test "decode_chunked_body ignores extensions and trailers" {
  match @core.decode_chunked_body(b"3;name=value\r\nl1\n\r\n0\r\n\r\n") {
    @core.ChunkedBody::Complete(d) => assert_eq(d, b"l1\n")
    _ => panic()
  }
  match @core.decode_chunked_body(b"3\r\nl1\n\r\n0\r\nX-Trailer: v\r\n\r\n") {
    @core.ChunkedBody::Complete(d) => assert_eq(d, b"l1\n")
    _ => panic()
  }
  // Hex sizes are case-insensitive and zero terminates.
  match @core.decode_chunked_body(b"A\r\n0123456789\r\n0\r\n\r\n") {
    @core.ChunkedBody::Complete(d) => assert_eq(d, b"0123456789")
    _ => panic()
  }
}

///|
test "decode_chunked_body asks for more on incomplete input" {
  match @core.decode_chunked_body(b"") {
    @core.ChunkedBody::NeedMore => ()
    _ => panic()
  }
  match @core.decode_chunked_body(b"5\r\nab") {
    @core.ChunkedBody::NeedMore => ()
    _ => panic()
  }
  // Data present but the trailing CRLF of the chunk has not arrived yet.
  match @core.decode_chunked_body(b"2\r\nab") {
    @core.ChunkedBody::NeedMore => ()
    _ => panic()
  }
}

///|
test "decode_chunked_body rejects malformed framing" {
  // Non-hex chunk size.
  match @core.decode_chunked_body(b"zz\r\nab\r\n") {
    @core.ChunkedBody::Malformed => ()
    _ => panic()
  }
  // Missing digit in the size line.
  match @core.decode_chunked_body(b"\r\n") {
    @core.ChunkedBody::Malformed => ()
    _ => panic()
  }
  // Chunk data not terminated by CRLF.
  match @core.decode_chunked_body(b"2\r\nabXY\r\n") {
    @core.ChunkedBody::Malformed => ()
    _ => panic()
  }
}

///|
test "parse_http_request rejects malformed request lines" {
  match @core.parse_http_request(b"\r\n\r\n") {
    Some(_) => panic()
    None => ()
  }
  match @core.parse_http_request(b"POST") {
    Some(_) => panic()
    None => ()
  }
}
