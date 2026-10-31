///|
test "memlog append and read" {
  let log = @backend_mem.MemLog::new()
  let n = log.append(b"hello") catch { _ => panic() }
  assert_eq(n, (5 : Int64))
  let n2 = log.append(b" world") catch { _ => panic() }
  assert_eq(n2, (11 : Int64))
  assert_eq(log.length(), (11 : Int64))
  let chunk = log.read_at((6 : Int64), 5) catch { _ => panic() }
  assert_eq(chunk, b"world")
}

///|
test "memlog read out of bounds raises" {
  let log = @backend_mem.MemLog::new()
  let _ = log.append(b"abc") catch { _ => panic() }
  let mut raised = false
  try {
    let _ = log.read_at((5 : Int64), 2)
  } catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "memlog append after close raises" {
  let log = @backend_mem.MemLog::new()
  log.close()
  assert_true(log.is_closed())
  let mut raised = false
  try {
    let _ = log.append(b"x")
  } catch {
    _ => raised = true
  }
  assert_true(raised)
}
