///|
/// Deterministic 64-bit LCG so the property loops below are reproducible:
/// a failing seed can be replayed by hand.
fn prop_lcg(state : UInt64) -> UInt64 {
  state * 6364136223846793005 + 1442695040888963407
}

///|
fn prop_bytes(n : Int) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  for i = 0; i < n; i = i + 1 {
    buf.write_byte((i % 251).to_byte())
  }
  buf.to_bytes()
}

///|
/// A tail truncation at an arbitrary byte must recover exactly the records
/// that ended at or before the cut — never a partial record, never one lost.
test "random tail truncation always recovers an exact prefix" {
  let mut s : UInt64 = 0x2545F4914F6CDD1D
  let mut round = 0
  while round < 300 {
    s = prop_lcg(s)
    let n = (s % (25 : UInt64)).to_int() + 1
    let store = @backend_mem.MemLog::new()
    let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
      store,
      store,
      (0 : UInt64),
    )
    let ends : Array[Int64] = []
    let vals : Array[Bytes] = []
    for i = 0; i < n; i = i + 1 {
      s = prop_lcg(s)
      let v = prop_bytes((s % (40 : UInt64)).to_int())
      ignore(seg.append(b"k", v, i.to_int64()) catch { _ => panic() })
      ends.push(seg.byte_size())
      vals.push(v)
    }
    let total = seg.byte_size()
    s = prop_lcg(s)
    let cut = (s % (total.reinterpret_as_uint64() + 1)).reinterpret_as_int64()
    store.truncate(cut) catch { _ => panic() }
    let seg2 : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
      store,
      store,
      (0 : UInt64),
    )
    let cnt = seg2.recover() catch { _ => panic() }
    let mut expect = 0
    while expect < n && ends[expect] <= cut {
      expect = expect + 1
    }
    assert_eq(cnt, expect)
    assert_eq(seg2.count(), expect)
    let recs = seg2.scan() catch { _ => panic() }
    assert_eq(recs.length(), expect)
    let mut i = 0
    while i < expect {
      assert_eq(recs[i].offset, i.to_uint64())
      assert_eq(recs[i].value, vals[i])
      i = i + 1
    }
    round = round + 1
  }
}

///|
/// Corrupting a body/CRC byte (not the length prefix) of a record must make
/// recovery stop just before that record, keeping every earlier record intact.
test "random in-body corruption truncates to the damaged record" {
  let mut s : UInt64 = 0x9E3779B97F4A7C15
  let mut round = 0
  while round < 300 {
    s = prop_lcg(s)
    let n = (s % (20 : UInt64)).to_int() + 2
    let store = @backend_mem.MemLog::new()
    let seg : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
      store,
      store,
      (0 : UInt64),
    )
    let ends : Array[Int64] = []
    for i = 0; i < n; i = i + 1 {
      s = prop_lcg(s)
      let v = prop_bytes((s % (30 : UInt64)).to_int() + 1)
      ignore(seg.append(b"k", v, i.to_int64()) catch { _ => panic() })
      ends.push(seg.byte_size())
    }
    let total = seg.byte_size()
    let raw = seg.read_raw((0 : Int64), total.to_int()) catch { _ => panic() }
    s = prop_lcg(s)
    let victim = (s % n.to_uint64()).to_int()
    let start = if victim == 0 { (0 : Int64) } else { ends[victim - 1] }
    let span = ends[victim] - start - (4 : Int64)
    s = prop_lcg(s)
    let flip = (start + (4 : Int64)).to_int() + (s % span.reinterpret_as_uint64()).to_int()
    let buf = @buffer.Buffer::Buffer()
    for i = 0; i < raw.length(); i = i + 1 {
      if i == flip {
        buf.write_byte(raw.at(i) ^ (0xFF : Byte))
      } else {
        buf.write_byte(raw.at(i))
      }
    }
    let bad = @backend_mem.MemLog::new()
    ignore(bad.append(buf.to_bytes()) catch { _ => panic() })
    let seg2 : @segment.Segment[@backend_mem.MemLog, @backend_mem.MemLog] = @segment.Segment::new(
      bad,
      bad,
      (0 : UInt64),
    )
    let cnt = seg2.recover() catch { _ => panic() }
    assert_eq(cnt, victim)
    assert_eq(seg2.count(), victim)
    let recs = seg2.scan() catch { _ => panic() }
    assert_eq(recs.length(), victim)
    round = round + 1
  }
}