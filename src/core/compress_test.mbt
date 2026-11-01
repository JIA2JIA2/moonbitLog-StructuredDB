///|
test "rle round-trips assorted data" {
  let cases : Array[Bytes] = [
    b"", b"a", b"abc", b"aabbcc", b"\xff", b"\xff\xff\xff", b"\xff\x00\xff\xff\x00\x00\x00\x00",
    b"key\x00\x00\x00\x00value",
  ]
  for c in cases {
    let enc = @core.rle_compress(c)
    let dec = @core.rle_decompress(enc, c.length().to_int64()) catch {
      _ => panic()
    }
    assert_eq(dec, c)
  }
}

///|
test "rle compacts long runs" {
  let data = @buffer.Buffer::Buffer()
  for i = 0; i < 1000; i = i + 1 {
    data.write_byte((7 : Byte))
  }
  let src = data.to_bytes()
  let enc = @core.rle_compress(src)
  assert_true(enc.length() < src.length())
  let dec = @core.rle_decompress(enc, src.length().to_int64()) catch {
    _ => panic()
  }
  assert_eq(dec, src)
}

///|
test "rle decompress rejects a truncated escape" {
  let mut raised = false
  try {
    let _ = @core.rle_decompress(b"\xff\x05", (10 : Int64))
  } catch {
    _ => raised = true
  }
  assert_true(raised)
}
