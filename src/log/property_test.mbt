///|
/// Deterministic property test: drive a pseudo-random sequence of puts,
/// deletes and reads against an in-memory model while rolling segments along
/// the way, then verify the log's integrity and final live view. The PRNG is a
/// fixed-seed xorshift64, so failures are reproducible.
test "property: randomized ops match an in-memory model" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (200 : Int64),
    base => mem_segment(base),
  )
  let keys : Array[Bytes] = [
    b"k0", b"k1", b"k2", b"k3", b"k4", b"k5", b"k6", b"k7", b"k8", b"k9", b"ka",
    b"kb", b"kc", b"kd", b"ke", b"kf",
  ]
  let values : Array[Bytes] = [
    b"v0", b"v1", b"v2", b"v3", b"v4", b"v5", b"v6", b"v7", b"v8", b"v9", b"va",
    b"vb", b"vc", b"vd", b"ve", b"vf",
  ]
  let model : Array[Bytes?] = Array::make(16, (None : Bytes?))
  let mut x : UInt64 = 0x9E3779B97F4A7C15
  let count_live = fn() -> Int32 {
    let mut n = 0
    for i = 0; i < 16; i = i + 1 {
      match model[i] {
        Some(_) => n = n + 1
        None => ()
      }
    }
    n
  }
  let check_views = fn() -> Unit raise {
    let expect = count_live()
    let snaps = log.snapshot() catch { _ => panic() }
    assert_eq(snaps.length(), expect)
    for rec in snaps {
      let mut matched = false
      for i = 0; i < 16; i = i + 1 {
        if keys[i] == rec.key {
          matched = true
          match model[i] {
            Some(v) => assert_eq(rec.value, v)
            None => panic()
          }
        }
      }
      assert_true(matched)
    }
    let live = log.scan_live((1_000_000 : Int64), (1_000_000_000_000 : Int64)) catch {
      _ => panic()
    }
    assert_eq(live.length(), expect)
    let pref = log.scan_prefix(b"k") catch { _ => panic() }
    assert_eq(pref.length(), expect)
    let rng = log.scan_key_range(b"", b"") catch { _ => panic() }
    assert_eq(rng.length(), expect)
  }
  let mut step = 0
  while step < 400 {
    if step % 40 == 39 {
      check_views() catch {
        _ => panic()
      }
    }
    x = x ^ (x << 13)
    x = x ^ (x >> 7)
    x = x ^ (x << 17)
    let roll = ((x >> 32) & 0x7FFFFFFF).to_int() % 100
    let ki = ((x >> 40) & 0xF).to_int()
    let k = keys[ki]
    if roll < 60 {
      let v = values[step % 16]
      ignore(log.append(k, v, step.to_int64()) catch { _ => panic() })
      model[ki] = Some(v)
    } else if roll < 85 {
      ignore(log.delete(k, step.to_int64()) catch { _ => panic() })
      model[ki] = None
    } else {
      let idx = log.build_key_index()
      let got = log.get_latest(idx, k) catch { _ => panic() }
      match model[ki] {
        Some(expected) =>
          match got {
            Some(rec) => assert_eq(rec.value, expected)
            None => panic()
          }
        None =>
          match got {
            Some(_) => panic()
            None => ()
          }
      }
    }
    step = step + 1
  }
  check_views() catch {
    _ => panic()
  }
  let idx = log.build_key_index()
  for i = 0; i < 16; i = i + 1 {
    let got = log.get_latest(idx, keys[i]) catch { _ => panic() }
    match model[i] {
      Some(expected) =>
        match got {
          Some(rec) => assert_eq(rec.value, expected)
          None => panic()
        }
      None =>
        match got {
          Some(_) => panic()
          None => ()
        }
    }
  }
  let report = log.verify()
  match report.first_bad_offset {
    Some(_) => panic()
    None => ()
  }
  match report.first_bad_checksum {
    Some(_) => panic()
    None => ()
  }
}

///|
/// Property test for maintenance operations: randomized maintenance (merge,
/// prune-superseded with a cursor guard, compact) interleaved with regular ops
/// must preserve the consumed/live contract — the (offset, key, value, ts)
/// stream never changes across a merge, records at or after the cursor are
/// never touched by a guarded prune, and the live view always matches the
/// model after a compact (whose cursor is reset, as documented).
test "property: maintenance ops preserve consumed data and the live view" {
  let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
    (200 : Int64),
    base => mem_segment(base),
  )
  let keys : Array[Bytes] = [
    b"k0", b"k1", b"k2", b"k3", b"k4", b"k5", b"k6", b"k7", b"k8", b"k9", b"ka",
    b"kb", b"kc", b"kd", b"ke", b"kf",
  ]
  let values : Array[Bytes] = [
    b"v0", b"v1", b"v2", b"v3", b"v4", b"v5", b"v6", b"v7", b"v8", b"v9", b"va",
    b"vb", b"vc", b"vd", b"ve", b"vf",
  ]
  let model : Array[Bytes?] = Array::make(16, (None : Bytes?))
  let mut x : UInt64 = 0xC0FFEE123456789
  let mut g : UInt64 = 0
  let check_live = fn() -> Unit raise {
    let idx = log.build_key_index()
    for i = 0; i < 16; i = i + 1 {
      let got = log.get_latest(idx, keys[i]) catch { _ => panic() }
      match model[i] {
        Some(expected) =>
          match got {
            Some(rec) =>
              if rec.value != expected {
                println("LIVE-MISMATCH ki=" + i.to_string())
                assert_eq(rec.value, expected)
              }
            None => {
              println("LIVE-MISSING ki=" + i.to_string())
              panic()
            }
          }
        None =>
          match got {
            Some(rec) => {
              println(
                "LIVE-EXTRA ki=" +
                i.to_string() +
                " off=" +
                rec.offset.to_string(),
              )
              let all = log.scan() catch { _ => panic() }
              for r in all {
                let mut keyi = -1
                for j = 0; j < 16; j = j + 1 {
                  if keys[j] == r.key {
                    keyi = j
                  }
                }
                println(
                  "  rec off=" +
                  r.offset.to_string() +
                  " keyi=" +
                  keyi.to_string() +
                  " del=" +
                  r.is_delete().to_string(),
                )
              }
              panic()
            }
            None => ()
          }
      }
    }
  }
  let mut round = 0
  while round < 40 {
    let mut s = 0
    while s < 4 {
      x = x ^ (x << 13)
      x = x ^ (x >> 7)
      x = x ^ (x << 17)
      let ki = ((x >> 40) & 0xF).to_int()
      let roll = ((x >> 32) & 0x7FFFFFFF).to_int() % 100
      if roll < 65 {
        let v = values[(round * 4 + s) % 16]
        ignore(
          log.append(keys[ki], v, (round * 100 + s).to_int64()) catch {
            _ => panic()
          },
        )
        model[ki] = Some(v)
      } else {
        ignore(
          log.delete(keys[ki], (round * 100 + s).to_int64()) catch {
            _ => panic()
          },
        )
        model[ki] = None
      }
      s = s + 1
    }
    x = x ^ (x << 13)
    x = x ^ (x >> 7)
    x = x ^ (x << 17)
    let kind = ((x >> 32) & 0x7FFFFFFF).to_int() % 3
    if kind == 0 {
      let before = log.scan() catch { _ => panic() }
      let merged = log.merge_segments(1, _seg => ()) catch { _ => panic() }
      if merged >= 1 {
        let after = log.scan() catch { _ => panic() }
        assert_eq(after.length(), before.length())
        let mut i = 0
        while i < before.length() {
          assert_eq(after[i].offset, before[i].offset)
          assert_eq(after[i].key, before[i].key)
          assert_eq(after[i].value, before[i].value)
          assert_eq(after[i].timestamp, before[i].timestamp)
          i = i + 1
        }
      }
    } else if kind == 1 {
      let window_to = log.next_offset()
      let before = log.scan_range(g, window_to) catch { _ => panic() }
      let idx = log.build_key_index()
      log.set_cursor_guard(Some(g))
      let dropped = log.prune_superseded(idx, _seg => ()) catch { _ => panic() }
      log.set_cursor_guard((None : UInt64?))
      let after = log.scan_range(g, window_to) catch { _ => panic() }
      assert_eq(after.length(), before.length())
      let mut i = 0
      while i < before.length() {
        assert_eq(after[i].offset, before[i].offset)
        assert_eq(after[i].key, before[i].key)
        assert_eq(after[i].value, before[i].value)
        i = i + 1
      }
      let _ = dropped
    } else {
      ignore(log.compact(on_drop=_seg => ()) catch { _ => panic() })
      assert_eq(log.next_offset(), log.count().to_uint64())
      g = (0 : UInt64)
    }
    x = x ^ (x << 13)
    x = x ^ (x >> 7)
    x = x ^ (x << 17)
    g = (x >> 33) % (log.next_offset() + (1 : UInt64))
    check_live() catch {
      _ => {
        println("check_live failed round=" + round.to_string())
        panic()
      }
    }
    let report = log.verify()
    match report.first_bad_offset {
      Some(_) => panic()
      None => ()
    }
    round = round + 1
  }
  check_live() catch {
    _ => panic()
  }
}
