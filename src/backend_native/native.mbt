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
/// Assumed average encoded record size, used to scale the sparse-index
/// interval from `roll_size`.
const ASSUMED_RECORD_BYTES : Int64 = 96

///|
/// Target number of sparse-index entries per segment.
const INDEX_ENTRY_TARGET : Int64 = 1024

///|
/// Pick a sparse-index interval for a segment of `roll_size` bytes so that the
/// per-segment index holds roughly `INDEX_ENTRY_TARGET` entries no matter how
/// large the segment grows.
pub fn index_interval_for(roll_size : Int64) -> Int32 {
  let records = roll_size / ASSUMED_RECORD_BYTES
  let iv = records / INDEX_ENTRY_TARGET
  if iv < 1 {
    1
  } else if iv > 4096 {
    4096
  } else {
    iv.to_int()
  }
}

///|
/// Open (creating if needed) the segment file for a freshly rolled segment in
/// `dir`, using the given sparse-index interval.
pub fn open_segment_in_dir(
  dir : String,
  base : UInt64,
  interval~ : Int32 = 32,
) -> @segment.Segment[NativeFileLog, NativeFileLog] raise @io.IoError {
  let path = dir + "/" + @segment.segment_file_name(base)
  let existed = file_exists(path)
  let f = NativeFileLog::open(path)
  if !existed {
    fsync_dir(dir)
  }
  @segment.Segment::new_with_index_interval(f, f, base, interval)
}

///|
/// Open an existing log directory, recovering every `*.log` segment: each
/// segment is scanned, its torn or corrupt tail (if any) is truncated, and its
/// sparse index, record count and offsets are rebuilt. Empty segments are
/// skipped. The returned log can be appended to immediately.
pub fn recover_log_dir(
  dir : String,
  roll_size : Int64,
  sync~ : @log.SyncPolicy = @log.SyncPolicy::Never,
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
  @log.Log::recover(
    roll_size,
    base => {
      open_segment_in_dir(dir, base, interval=index_interval_for(roll_size))
    },
    segs,
    sync~,
  )
}

///|
#borrow(path)
extern "C" fn moonlog_read_file(path : Bytes) -> Bytes = "moonlog_read_file"

///|
#borrow(path, data)
extern "C" fn moonlog_write_file(path : Bytes, data : Bytes) -> Int32 = "moonlog_write_file"

///|
#borrow(from, to)
extern "C" fn moonlog_rename(from : Bytes, to : Bytes) -> Int32 = "moonlog_rename"

///|
/// Name of the directory-level manifest file.
pub const MANIFEST_NAME : String = "MANIFEST"

///|
/// Read an entire file into `Bytes`. A missing or empty file yields empty bytes.
pub fn read_file(path : String) -> Bytes {
  moonlog_read_file(@utf8.encode(path))
}

///|
/// Replace a file's contents (truncate + write + fsync).
pub fn write_file(path : String, data : Bytes) -> Unit raise @io.IoError {
  let r = moonlog_write_file(@utf8.encode(path), data)
  if r < 0 {
    raise @io.IoError::Syscall(r)
  }
}

///|
/// File name of a segment's persisted index sidecar.
fn segment_index_name(base : UInt64) -> String {
  @segment.segment_file_name(base) + ".index"
}

///|
/// Path of a segment's persisted index sidecar.
pub fn segment_index_path(dir : String, base : UInt64) -> String {
  dir + "/" + segment_index_name(base)
}

///|
/// fsync a directory so that a preceding create/rename within it is durable.
fn fsync_dir(path : String) -> Unit raise @io.IoError {
  let fd = moonlog_open_ro(@utf8.encode(path))
  if fd < 0 {
    raise @io.IoError::Syscall(fd)
  }
  ignore(moonlog_fsync(fd))
  ignore(moonlog_close(fd))
}

///|
/// Durably replace `dir/name` with `data` without ever exposing a half-written
/// file: write to `dir/name.tmp`, fsync it, rename it over the target, then
/// fsync the directory. A crash at any step leaves either the previous file or
/// the new one — never a torn mixture.
fn write_file_atomic(
  dir : String,
  name : String,
  data : Bytes,
) -> Unit raise @io.IoError {
  let tmp = dir + "/" + name + ".tmp"
  write_file(tmp, data)
  let rc = moonlog_rename(@utf8.encode(tmp), @utf8.encode(dir + "/" + name))
  if rc < 0 {
    raise @io.IoError::Syscall(rc)
  }
  fsync_dir(dir)
}

///|
/// Remove a segment's data and index files (retention).
pub fn remove_segment_files(dir : String, base : UInt64) -> Unit {
  ignore(remove_file(dir + "/" + @segment.segment_file_name(base)))
  ignore(remove_file(segment_index_path(dir, base)))
  ignore(fsync_dir(dir) catch { _ => () })
}

///|
/// Load one segment, preferring its persisted index; falls back to a full
/// recover scan when the index is missing or invalid.
fn load_segment(
  dir : String,
  base : UInt64,
) -> @segment.Segment[NativeFileLog, NativeFileLog] raise @io.IoError {
  let f = NativeFileLog::open(dir + "/" + @segment.segment_file_name(base))
  let seg : @segment.Segment[NativeFileLog, NativeFileLog] = @segment.Segment::new(
    f, f, base,
  )
  let ip = segment_index_path(dir, base)
  let restored = if file_exists(ip) {
    let meta = Some(@segment.decode_segment_meta(read_file(ip))) catch {
      _ => None
    }
    match meta {
      Some(m) =>
        if m.base_offset == base {
          seg.apply_meta(m)
          true
        } else {
          false
        }
      None => false
    }
  } else {
    false
  }
  if !restored {
    ignore(seg.recover())
  }
  seg
}

///|
/// The on-disk byte size of a segment's data file, or -1 when it is missing.
/// Used to cross-check a segment against the size recorded in the manifest,
/// which catches a truncated or otherwise tampered data file that a valid
/// sidecar index would otherwise mask.
fn segment_file_size(dir : String, base : UInt64) -> Int64 {
  let path = dir + "/" + @segment.segment_file_name(base)
  let opened = Some(NativeFileLog::open(path)) catch { _ => None }
  match opened {
    Some(f) => {
      let s = f.size
      f.close()
      s
    }
    None => (-1 : Int64)
  }
}

///|
/// Open a log directory using the manifest + per-segment indexes for a fast
/// path, falling back to full recovery when they are missing or stale. This is
/// the preferred entry point for reopening an existing log.
pub fn open_log_dir(
  dir : String,
  roll_size : Int64,
  sync~ : @log.SyncPolicy = @log.SyncPolicy::Never,
) -> @log.Log[NativeFileLog, NativeFileLog] raise @io.IoError {
  let mpath = dir + "/" + MANIFEST_NAME
  if !file_exists(mpath) {
    return recover_log_dir(dir, roll_size, sync~)
  }
  let manifest = Some(@log.decode_manifest(read_file(mpath))) catch {
    _ => None
  }
  match manifest {
    Some(m) =>
      if m.roll_size != roll_size {
        recover_log_dir(dir, roll_size, sync~)
      } else {
        let segs : Array[@segment.Segment[NativeFileLog, NativeFileLog]] = []
        let mut consistent = true
        let mut i = 0
        while i < m.segment_bases.length() {
          let seg = load_segment(dir, m.segment_bases[i])
          let actual = segment_file_size(dir, m.segment_bases[i])
          if i >= m.segment_sizes.length() || actual != m.segment_sizes[i] {
            consistent = false
          }
          if seg.record_count > 0 {
            segs.push(seg)
          }
          i = i + 1
        }
        if consistent {
          @log.Log::recover(
            roll_size,
            base => {
              open_segment_in_dir(
                dir,
                base,
                interval=index_interval_for(roll_size),
              )
            },
            segs,
            sync~,
          )
        } else {
          for seg in segs {
            seg.writer.close()
          }
          recover_log_dir(dir, roll_size, sync~)
        }
      }
    None => recover_log_dir(dir, roll_size, sync~)
  }
}

///|
/// Persist the manifest and every segment's index so the next `open_log_dir`
/// can skip the data scan.
pub fn flush_meta(
  dir : String,
  log : @log.Log[NativeFileLog, NativeFileLog],
) -> Unit raise @io.IoError {
  let bases : Array[UInt64] = []
  let sizes : Array[Int64] = []
  for seg in log.segments {
    write_file_atomic(
      dir,
      segment_index_name(seg.base_offset),
      seg.to_meta().encode(),
    )
    bases.push(seg.base_offset)
    sizes.push(seg.byte_size())
  }
  let manifest : @log.Manifest = {
    roll_size: log.roll_size,
    next_offset: log.next_offset(),
    segment_bases: bases,
    segment_sizes: sizes,
  }
  write_file_atomic(dir, MANIFEST_NAME, manifest.encode())
}

///|
/// Name of the default consumer-cursor position file.
pub const CURSOR_NAME : String = "CURSOR"

///|
/// File-name prefix shared by named consumer cursors (`CURSOR.<name>`).
pub const CURSOR_PREFIX : String = "CURSOR."

///|
/// File under a log directory holding the CLI's committed consumer position.
pub fn cursor_path(dir : String) -> String {
  dir + "/" + CURSOR_NAME
}

///|
/// Read the persisted consumer position, defaulting to 0 when the file is
/// missing or fails its checksum.
pub fn load_cursor(dir : String) -> UInt64 {
  let data = read_file(cursor_path(dir))
  if data.length() == 0 {
    (0 : UInt64)
  } else {
    @log.decode_cursor(data) catch {
      _ => (0 : UInt64)
    }
  }
}

///|
/// Persist a consumer position (atomic replace, so a crash leaves either the
/// previous position or the new one).
pub fn save_cursor(dir : String, position : UInt64) -> Unit raise @io.IoError {
  write_file_atomic(dir, CURSOR_NAME, @log.encode_cursor(position))
}

///|
/// File name of a named consumer cursor's position file (`CURSOR.<name>`).
fn named_cursor_name(name : String) -> String {
  CURSOR_PREFIX + name
}

///|
/// Path of a named consumer cursor's position file (`CURSOR.<name>`), letting
/// several independent consumers track their own committed positions.
pub fn named_cursor_path(dir : String, name : String) -> String {
  dir + "/" + named_cursor_name(name)
}

///|
/// Read a named consumer position, defaulting to 0 when absent or corrupt.
pub fn load_named_cursor(dir : String, name : String) -> UInt64 {
  let data = read_file(named_cursor_path(dir, name))
  if data.length() == 0 {
    (0 : UInt64)
  } else {
    @log.decode_cursor(data) catch {
      _ => (0 : UInt64)
    }
  }
}

///|
/// Persist a named consumer position (atomic replace).
pub fn save_named_cursor(
  dir : String,
  name : String,
  position : UInt64,
) -> Unit raise @io.IoError {
  write_file_atomic(dir, named_cursor_name(name), @log.encode_cursor(position))
}

///|
/// Names of all persisted named consumer cursors in `dir`, without the
/// `CURSOR.` prefix.
pub fn list_named_cursors(dir : String) -> Array[String] raise @io.IoError {
  let out : Array[String] = []
  for name in list_dir(dir) {
    if name.has_prefix(CURSOR_PREFIX) {
      match name.strip_prefix(CURSOR_PREFIX) {
        Some(suffix) => out.push(suffix.to_owned())
        None => ()
      }
    }
  }
  out
}

///|
/// Delete a named consumer cursor's position file.
pub fn remove_named_cursor(dir : String, name : String) -> Unit {
  ignore(remove_file(named_cursor_path(dir, name)))
  ignore(fsync_dir(dir) catch { _ => () })
}

///|
extern "C" fn moonlog_flock(fd : Int32, exclusive : Int32) -> Int32 = "moonlog_flock"

///|
/// A directory-level advisory lock (via `flock`) used to serialize writers.
/// Acquisition is non-blocking, so a conflicting holder fails fast instead of
/// dead-locking.
pub(all) struct DirLock {
  fd : Int32
  mut held : Bool
}

///|
/// Acquire the `LOCK` file in `dir`. `exclusive` selects a writer lock;
/// otherwise a shared reader lock is taken.
pub fn DirLock::acquire(
  dir : String,
  exclusive : Bool,
) -> DirLock raise @io.IoError {
  let path = dir + "/LOCK"
  let fd = moonlog_open_rw(@utf8.encode(path))
  if fd < 0 {
    raise @io.IoError::Syscall(fd)
  }
  let flag = if exclusive { 1 } else { 0 }
  let r = moonlog_flock(fd, flag)
  if r < 0 {
    ignore(moonlog_close(fd))
    raise @io.IoError::Syscall(r)
  }
  { fd, held: true, }
}

///|
pub fn DirLock::release(self : DirLock) -> Unit {
  if self.held {
    ignore(moonlog_close(self.fd))
    self.held = false
  }
}
