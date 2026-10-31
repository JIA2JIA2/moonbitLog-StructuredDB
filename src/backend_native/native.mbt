///|
/// Native runtime bindings (see `stub.c`). Paths are UTF-8 `Bytes`.
#borrow(path)
extern "C" fn moonlog_open_rw(path : Bytes) -> Int32 = "moonlog_open_rw"

///|
#borrow(path)
extern "C" fn moonlog_open_ro(path : Bytes) -> Int32 = "moonlog_open_ro"

///|
extern "C" fn moonlog_pread(fd : Int32, offset : Int64, len : Int32) -> Bytes = "moonlog_pread"

///|
#borrow(data)
extern "C" fn moonlog_pwrite(fd : Int32, offset : Int64, data : Bytes) -> Int32 = "moonlog_pwrite"

///|
extern "C" fn moonlog_size(fd : Int32) -> Int64 = "moonlog_size"

///|
extern "C" fn moonlog_fsync(fd : Int32) -> Int32 = "moonlog_fsync"

///|
extern "C" fn moonlog_close(fd : Int32) -> Int32 = "moonlog_close"

///|
#borrow(path)
extern "C" fn moonlog_remove(path : Bytes) -> Int32 = "moonlog_remove"

///|
#borrow(path)
extern "C" fn moonlog_mkdir(path : Bytes) -> Int32 = "moonlog_mkdir"

///|
#borrow(path)
extern "C" fn moonlog_exists(path : Bytes) -> Int32 = "moonlog_exists"

///|
extern "C" fn moonlog_truncate(fd : Int32, size : Int64) -> Int32 = "moonlog_truncate"

///|
#borrow(path)
extern "C" fn moonlog_opendir(path : Bytes) -> Int64 = "moonlog_opendir"

///|
extern "C" fn moonlog_readdir(handle : Int64) -> Bytes = "moonlog_readdir"

///|
extern "C" fn moonlog_closedir(handle : Int64) -> Int32 = "moonlog_closedir"

///|
/// Native file-backed append-only log. A single open file descriptor serves
/// both writing (append) and random-access reading.
pub(all) struct NativeFileLog {
  fd : Int32
  path : Bytes
  mut size : Int64
  mut closed : Bool
}

///|
/// Open (creating if needed) a file-backed log.
pub fn NativeFileLog::open(path : String) -> NativeFileLog raise @io.IoError {
  let bytes = @utf8.encode(path)
  let fd = moonlog_open_rw(bytes)
  if fd < 0 {
    raise @io.IoError::Syscall(fd)
  }
  let size = moonlog_size(fd)
  { fd, path: bytes, size, closed: false, }
}

///|
/// Open an existing file read-only for recovery / read-only consumers.
pub fn NativeFileLog::open_readonly(
  path : String,
) -> NativeFileLog raise @io.IoError {
  let bytes = @utf8.encode(path)
  let fd = moonlog_open_ro(bytes)
  if fd < 0 {
    raise @io.IoError::Syscall(fd)
  }
  let size = moonlog_size(fd)
  { fd, path: bytes, size, closed: false, }
}

///|
/// Close the underlying file descriptor. Idempotent.
pub fn NativeFileLog::close(self : NativeFileLog) -> Unit {
  if !self.closed {
    ignore(moonlog_close(self.fd))
    self.closed = true
  }
}

///|
pub fn NativeFileLog::is_closed(self : NativeFileLog) -> Bool {
  self.closed
}

///|
/// Create a directory (parent of log files). Returns true if created or it
/// already existed.
pub fn ensure_dir(path : String) -> Bool {
  let bytes = @utf8.encode(path)
  if moonlog_exists(bytes) == 1 {
    return true
  }
  moonlog_mkdir(bytes) == 0
}

///|
/// Remove a file. Returns true if it no longer exists afterward.
pub fn remove_file(path : String) -> Bool {
  let bytes = @utf8.encode(path)
  let _ = moonlog_remove(bytes)
  moonlog_exists(bytes) == 0
}

///|
/// File exists?
pub fn file_exists(path : String) -> Bool {
  moonlog_exists(@utf8.encode(path)) == 1
}

///|
/// List directory entry names, excluding `.` and `..`.
pub fn list_dir(path : String) -> Array[String] raise @io.IoError {
  let handle = moonlog_opendir(@utf8.encode(path))
  if handle < (0 : Int64) {
    raise @io.IoError::Syscall(-1)
  }
  let out : Array[String] = []
  let mut go = true
  while go {
    let raw = moonlog_readdir(handle)
    if raw.length() == 0 {
      go = false
    } else {
      let name = @utf8.decode(raw) catch { _ => "" }
      if name.length() > 0 {
        out.push(name)
      }
    }
  }
  ignore(moonlog_closedir(handle))
  out
}

///|
pub impl @io.LogWriter for NativeFileLog with fn append(self, chunk) {
  if self.closed {
    raise @io.IoError::Closed
  }
  let n = moonlog_pwrite(self.fd, self.size, chunk)
  if n < 0 {
    raise @io.IoError::Syscall(n)
  }
  self.size = self.size + n.to_int64()
  self.size
}

///|
pub impl @io.LogWriter for NativeFileLog with fn flush(self) {
  if self.closed {
    raise @io.IoError::Closed
  }
  let r = moonlog_fsync(self.fd)
  if r < 0 {
    raise @io.IoError::Syscall(r)
  }
}

///|
pub impl @io.LogReader for NativeFileLog with fn read_at(self, offset, len) {
  if self.closed {
    raise @io.IoError::Closed
  }
  if offset < (0 : Int64) || offset + len.to_int64() > self.size {
    raise @io.IoError::OutOfBounds(offset)
  }
  moonlog_pread(self.fd, offset, len)
}

///|
pub impl @io.LogReader for NativeFileLog with fn length(self) {
  self.size
}

///|
pub impl @io.LogTruncate for NativeFileLog with fn truncate(self, size) {
  if self.closed {
    raise @io.IoError::Closed
  }
  let r = moonlog_truncate(self.fd, size)
  if r < 0 {
    raise @io.IoError::Syscall(r)
  }
  self.size = size
}

///|
pub extend NativeFileLog with @io.LogWriter::{append, flush}

///|
pub extend NativeFileLog with @io.LogReader::{read_at, length}

///|
pub extend NativeFileLog with @io.LogTruncate::{truncate}

///|
/// Insert `seg` into `segs` (kept sorted by ascending `base_offset`), returning
/// a new array.
fn insert_segment_sorted(
  segs : Array[@segment.Segment[NativeFileLog, NativeFileLog]],
  seg : @segment.Segment[NativeFileLog, NativeFileLog],
) -> Array[@segment.Segment[NativeFileLog, NativeFileLog]] {
  let out : Array[@segment.Segment[NativeFileLog, NativeFileLog]] = []
  let mut placed = false
  for s in segs {
    if !placed && seg.base_offset < s.base_offset {
      out.push(seg)
      placed = true
    }
    out.push(s)
  }
  if !placed {
    out.push(seg)
  }
  out
}

///|
/// Open (creating if needed) the segment file for a freshly rolled segment in
/// `dir`.
pub fn open_segment_in_dir(
  dir : String,
  base : UInt64,
) -> @segment.Segment[NativeFileLog, NativeFileLog] raise @io.IoError {
  let path = dir + "/" + @segment.segment_file_name(base)
  let f = NativeFileLog::open(path)
  @segment.Segment::new(f, f, base)
}

///|
/// Open an existing log directory, recovering every `*.log` segment: each
/// segment is scanned, its torn or corrupt tail (if any) is truncated, and its
/// sparse index, record count and offsets are rebuilt. Empty segments are
/// skipped. The returned log can be appended to immediately.
pub fn recover_log_dir(
  dir : String,
  roll_size : Int64,
) -> @log.Log[NativeFileLog, NativeFileLog] raise @io.IoError {
  let names = list_dir(dir)
  let mut segs : Array[@segment.Segment[NativeFileLog, NativeFileLog]] = []
  for name in names {
    if name.has_suffix(".log") {
      let path = dir + "/" + name
      let f = NativeFileLog::open(path)
      let seg : @segment.Segment[NativeFileLog, NativeFileLog] = @segment.Segment::new(
        f,
        f,
        (0 : UInt64),
      )
      let n = seg.recover()
      if n > 0 {
        segs = insert_segment_sorted(segs, seg)
      } else {
        f.close()
      }
    }
  }
  @log.Log::recover(roll_size, base => open_segment_in_dir(dir, base), segs)
}