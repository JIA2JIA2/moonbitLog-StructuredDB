///|
/// In-memory append-only log. Serves as the reference backend for tests and
/// for wasm/js targets where the native file backend is unavailable.
pub struct MemLog {
  mut data : Bytes
  mut closed : Bool
}

///|
pub fn MemLog::new() -> MemLog {
  { data: b"", closed: false, }
}

///|
pub fn MemLog::close(self : MemLog) -> Unit {
  self.closed = true
}

///|
pub fn MemLog::is_closed(self : MemLog) -> Bool {
  self.closed
}

///|
pub impl @io.LogWriter for MemLog with fn append(self, chunk) {
  if self.closed {
    raise @io.IoError::Closed
  }
  self.data = self.data + chunk
  self.data.length().to_int64()
}

///|
pub impl @io.LogWriter for MemLog with fn flush(self) {
  ignore(self)
}

///|
pub impl @io.LogReader for MemLog with fn read_at(self, offset, len) {
  if self.closed {
    raise @io.IoError::Closed
  }
  let total = self.data.length().to_int64()
  let end = offset + len.to_int64()
  if offset < (0 : Int64) || end > total {
    raise @io.IoError::OutOfBounds(offset)
  }
  let start = offset.to_int()
  let buf = @buffer.Buffer::Buffer()
  for i = start; i < end.to_int(); i = i + 1 {
    buf.write_byte(self.data.at(i))
  }
  buf.to_bytes()
}

///|
pub impl @io.LogReader for MemLog with fn length(self) {
  self.data.length().to_int64()
}

///|
pub extend MemLog with @io.LogWriter::{append, flush}

///|
pub extend MemLog with @io.LogReader::{read_at, length}
