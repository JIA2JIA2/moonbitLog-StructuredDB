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
  let mut step = 0
  while step < 400 {
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
