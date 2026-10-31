///|
test "record encode/decode roundtrip" {
  let rec : @core.Record = {
    offset: (42 : UInt64),
    timestamp: (1700000000000 : Int64),
    kind: @core.RecordKind::Put,
    key: b"user:1",
    value: b"hello world",
  }
  let encoded = rec.encode()
  let (decoded, next) = @core.decode_record(encoded, 0) catch { _ => panic() }
  assert_eq(decoded.offset, (42 : UInt64))
  assert_eq(decoded.timestamp, (1700000000000 : Int64))
  assert_eq(decoded.key, b"user:1")
  assert_eq(decoded.value, b"hello world")
  assert_eq(decoded.kind, @core.RecordKind::Put)
  assert_eq(next, encoded.length())
}

///|
test "delete record roundtrips and reports as tombstone" {
  let rec : @core.Record = {
    offset: (7 : UInt64),
    timestamp: (99 : Int64),
    kind: @core.RecordKind::Delete,
    key: b"user:1",
    value: b"",
  }
  let encoded = rec.encode()
  let (decoded, next) = @core.decode_record(encoded, 0) catch { _ => panic() }
  assert_eq(decoded.kind, @core.RecordKind::Delete)
  assert_true(decoded.is_delete())
  assert_eq(decoded.key, b"user:1")
  assert_eq(next, encoded.length())
}

///|
test "record with empty key and value" {
  let rec : @core.Record = {
    offset: (0 : UInt64),
    timestamp: (0 : Int64),
    kind: @core.RecordKind::Put,
    key: b"",
    value: b"",
  }
  let encoded = rec.encode()
  let (decoded, next) = @core.decode_record(encoded, 0) catch { _ => panic() }
  assert_eq(decoded.key.length(), 0)
  assert_eq(decoded.value.length(), 0)
  assert_eq(next, encoded.length())
}

///|
test "crc32 known value" {
  assert_eq(@core.crc32(b"123456789"), (0xCBF43926 : UInt32))
}

///|
test "decode truncated raises" {
  let rec : @core.Record = {
    offset: (1 : UInt64),
    timestamp: (1 : Int64),
    kind: @core.RecordKind::Put,
    key: b"k",
    value: b"v",
  }
  let encoded = rec.encode()
  let short = @core.slice(encoded, 0, 3)
  let mut raised = false
  try {
    let _ = @core.decode_record(short, 0)
  } catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "decode bad crc raises" {
  let rec : @core.Record = {
    offset: (5 : UInt64),
    timestamp: (5 : Int64),
    kind: @core.RecordKind::Put,
    key: b"k",
    value: b"v",
  }
  let encoded = rec.encode()
  let bad = @core.slice(encoded, 0, encoded.length() - 1) + b"\x00"
  let mut raised = false
  try {
    let _ = @core.decode_record(bad, 0)
  } catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "scan two concatenated records" {
  let r1 : @core.Record = {
    offset: (0 : UInt64),
    timestamp: (10 : Int64),
    kind: @core.RecordKind::Put,
    key: b"a",
    value: b"one",
  }
  let r2 : @core.Record = {
    offset: (1 : UInt64),
    timestamp: (20 : Int64),
    kind: @core.RecordKind::Delete,
    key: b"b",
    value: b"",
  }
  let combined = r1.encode() + r2.encode()
  let (d1, p1) = @core.decode_record(combined, 0) catch { _ => panic() }
  let (d2, p2) = @core.decode_record(combined, p1) catch { _ => panic() }
  assert_eq(d1.offset, (0 : UInt64))
  assert_eq(d2.offset, (1 : UInt64))
  assert_true(d2.is_delete())
  assert_eq(p2, combined.length())
}

///|
test "body_len_at reads the length prefix without decoding" {
  let rec : @core.Record = {
    offset: (3 : UInt64),
    timestamp: (3 : Int64),
    kind: @core.RecordKind::Put,
    key: b"k",
    value: b"value",
  }
  let encoded = rec.encode()
  let len = @core.body_len_at(encoded, 0) catch { _ => panic() }
  assert_eq(len, 25 + 1 + 5)
}
