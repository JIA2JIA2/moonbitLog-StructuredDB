///|
/// Errors produced by storage backends.
pub(all) suberror IoError {
  Closed
  OutOfBounds(Int64)
  Corrupt(Int64)
  Syscall(Int32)
  Invalid(String)
}

///|
/// Append-only writer: data is only ever added at the end.
pub(open) trait LogWriter {
  fn append(Self, Bytes) -> Int64 raise IoError
  fn flush(Self) -> Unit raise IoError
}

///|
/// Random-access reader over previously appended bytes.
pub(open) trait LogReader {
  fn read_at(Self, Int64, Int32) -> Bytes raise IoError
  fn length(Self) -> Int64
}

///|
/// Truncate a log to `size` bytes, discarding any partial tail left behind by
/// a crash. Implemented by backends whose storage can shrink.
pub(open) trait LogTruncate {
  fn truncate(Self, Int64) -> Unit raise IoError
}