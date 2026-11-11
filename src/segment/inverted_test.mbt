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

///|
test "inv sidecar front coding roundtrips shared-prefix keys" {
  let store = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (0 : UInt64),
  )
  let ids : Array[Bytes] = [b"t1", b"t2", b"t10", b"t11"]
  for id in ids {
    ignore(
      seg.append(b"svc", b"trace_id=" + id + b" msg=ok", (1 : Int64)) catch {
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
  let decoded = @segment.decode_inv_index(raw) catch { _ => panic() }
  for id in ids {
    let field = b"trace_id=" + id
    assert_eq(decoded.fields.get(field), ix.fields.get(field))
    assert_eq(decoded.terms.get(id), ix.terms.get(id))
  }
  assert_eq(decoded.terms.get(b"msg"), ix.terms.get(b"msg"))
  assert_eq(decoded.terms.get(b"trace"), ix.terms.get(b"trace"))
  assert_eq(decoded.fields.get(b"__key__=svc"), ix.fields.get(b"__key__=svc"))
  assert_true(raw.length() > 0)
}

///|
test "tokenize emits UTF-8 character unigrams for CJK" {
  let t = @segment.tokenize(b"数据库连接", 16)
  assert_eq(t.length(), 5)
  assert_eq(t[0], b"数")
  assert_eq(t[1], b"据")
  assert_eq(t[2], b"库")
  assert_eq(t[3], b"连")
  assert_eq(t[4], b"接")
  // ASCII words are still tokenized as words alongside CJK characters.
  assert_eq(@segment.tokenize(b"数据库 error 42", 16), [
    b"数", b"据", b"库", b"error", b"42",
  ])
  // ASCII whitespace never produces a token.
  assert_eq(@segment.tokenize(b"  ", 16).length(), 0)
}

///|
test "field columns normalize aliases, JSON and value case (3.2)" {
  let store = @backend_mem.MemLog::new()
  let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
    store,
    store,
    (0 : UInt64),
  )
  // OTel JSON record: `parse_kv_pairs` sees no pairs, so before the JSON
  // flattening the field columns stayed empty and `--indexed` pushdown
  // skipped the whole segment (false negatives).
  ignore(
    seg.append(
      b"log",
      b"{\"severity_text\":\"ERROR\",\"service\":{\"name\":\"orders\"},\"message\":\"boom\"}",
      (1 : Int64),
    ) catch {
      _ => panic()
    },
  )
  // Alias-shaped KV record: names squash to the 2.2 canonical slots.
  ignore(
    seg.append(b"svc", b"severity=Warn service_name=orders", (2 : Int64)) catch {
      _ => panic()
    },
  )
  // Non-canonical fields keep their literal name/value.
  ignore(
    seg.append(b"log", b"order_id=AB-42 status=OK", (3 : Int64)) catch {
      _ => panic()
    },
  )
  seg.build_inv_index()
  // JSON values land in the columns as canonical name + lowercase value.
  assert_eq(seg.inv_field_postings(b"level", b"error"), [0])
  assert_eq(seg.inv_field_postings(b"service", b"orders"), [0, 1])
  assert_eq(seg.inv_field_postings(b"message", b"boom"), [0])
  // Alias names and mixed-case values fold into the same columns.
  assert_eq(seg.inv_field_postings(b"level", b"warn"), [1])
  // Probing the original casing misses (values are stored folded)…
  assert_eq(seg.inv_field_postings(b"level", b"ERROR").length(), 0)
  // …and non-canonical fields stay literal.
  assert_eq(seg.inv_field_postings(b"order_id", b"AB-42"), [2])
  assert_eq(seg.inv_field_postings(b"status", b"OK"), [2])
  // Keys keep their original case in the `__key__` column.
  assert_eq(seg.inv_field_postings(b"__key__", b"svc"), [1])
}
