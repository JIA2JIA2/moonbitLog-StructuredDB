///|
test "tokenize folds case and splits on non-word bytes" {
  assert_eq(@segment.tokenize(b"level=ERROR msg=ok42", 64), [
    b"level", b"error", b"msg", b"ok42",
  ])
  assert_eq(@segment.tokenize(b"hello, world! 99x", 64), [
    b"hello", b"world", b"99x",
  ])
  // A single run longer than 32 bytes is dropped entirely (33 letters).
  assert_eq(
    @segment.tokenize(b"abcdefghijklmnopqrstuvwxyzaabbccd", 64).length(),
    0,
  )
  // Underscores split words: 11 short tokens, all kept.
  assert_eq(
    @segment.tokenize(
      b"truncated_chain_long_enough_to_be_skipped_due_to_length_limit", 64,
    ).length(),
    11,
  )
  assert_eq(@segment.tokenize(b"", 64).length(), 0)
  // max_terms caps the output.
  assert_eq(@segment.tokenize(b"a b c d e", 3).length(), 3)
}

///|
test "build and lookups match record content" {
  let store = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (0 : UInt64),
  )
  ignore(
    seg.append(b"orders", b"level=error trace_id=t9 msg=db_down", (1 : Int64)) catch {
      _ => panic()
    },
  )
  ignore(
    seg.append(b"payments", b"level=warn trace_id=t8 msg=slow", (2 : Int64)) catch {
      _ => panic()
    },
  )
  ignore(
    seg.append(b"orders", b"level=error msg=retry", (3 : Int64)) catch {
      _ => panic()
    },
  )
  seg.build_inv_index()
  // Term postings: "error" appears in records 0 and 2, "warn" in record 1.
  assert_eq(seg.inv_term_postings(b"error"), [0, 2])
  assert_eq(seg.inv_term_postings(b"warn"), [1])
  assert_eq(seg.inv_term_postings(b"missing").length(), 0)
  // Field columns: exact name=value pairs and the record key.
  assert_eq(seg.inv_field_postings(b"level", b"error"), [0, 2])
  assert_eq(seg.inv_field_postings(b"level", b"warn"), [1])
  assert_eq(seg.inv_field_postings(b"__key__", b"payments"), [1])
  assert_eq(seg.inv_field_postings(b"level", b"fatal").length(), 0)
  // Offsets derived from postings point at the right records.
  let p0 = seg.inv_field_postings(b"trace_id", b"t9")
  assert_eq(p0.length(), 1)
  let rec = seg.get(seg.base_offset + p0[0].to_uint64()) catch { _ => panic() }
  match rec {
    Some(r) => assert_eq(r.value, b"level=error trace_id=t9 msg=db_down")
    None => panic()
  }
}

///|
test "inv sidecar roundtrip preserves both tables" {
  let store = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (5 : UInt64),
  )
  ignore(
    seg.append(b"svc", b"level=error msg=boom", (1 : Int64)) catch {
      _ => panic()
    },
  )
  seg.build_inv_index()
  let ix = match seg.inv_index {
    Some(ix) => ix
    None => panic()
  }
  let raw = ix.encode()
  let stage = try {
    ignore(@segment.decode_inv_index(raw))
    "decode-ok"
  } catch {
    @core.MetaError::BadMagic => "bad-magic"
    @core.MetaError::BadVersion(_) => "bad-version"
    @core.MetaError::Truncated(p) => "truncated-" + p.to_string()
    @core.MetaError::BadCrc(e, a) =>
      "bad-crc-" + e.to_string() + "-" + a.to_string()
  }
  println("stage=" + stage + " total=" + raw.length().to_string())
  assert_true(stage == "decode-ok")
  let decoded = @segment.decode_inv_index(raw) catch { _ => panic() }
  assert_eq(decoded.terms.get(b"boom"), ix.terms.get(b"boom"))
  assert_eq(decoded.fields.get(b"level=error"), ix.fields.get(b"level=error"))
  assert_eq(decoded.fields.get(b"__key__=svc"), ix.fields.get(b"__key__=svc"))
  // Corrupted sidecar is rejected by the CRC.
  let raw = ix.encode()
  let bad = @core.slice(raw, 0, raw.length() - 5) + b"\x00\x00\x00\x00\x00"
  let raised = try {
    ignore(@segment.decode_inv_index(bad))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "inv sidecar uses columnar varint postings (3.3)" {
  let store = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (0 : UInt64),
  )
  // 500 records sharing one field → dense columns with 500 postings each.
  for i = 0; i < 500; i = i + 1 {
    ignore(
      seg.append(b"svc", b"level=info", i.to_int64()) catch {
        _ => panic()
      },
    )
  }
  seg.build_inv_index()
  let ix = match seg.inv_index {
    Some(ix) => ix
    None => panic()
  }
  let raw = ix.encode()
  // A fixed 4-byte-per-posting layout (v1) would need ~30k bytes for these
  // tables; the varint deltas (all 1) shrink it to ~7.6k. Assert well under
  // half of the fixed-layout estimate so the compression is actually proven.
  assert_true(raw.length() < 15000)
  // Semantics unchanged after decode.
  let decoded = @segment.decode_inv_index(raw) catch { _ => panic() }
  assert_eq(decoded.fields.get(b"level=info"), ix.fields.get(b"level=info"))
  assert_eq(decoded.terms.get(b"level"), ix.terms.get(b"level"))
  assert_eq(decoded.terms.get(b"info"), ix.terms.get(b"info"))
}
