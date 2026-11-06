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
