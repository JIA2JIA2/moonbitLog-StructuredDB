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
/// Write only the first `len` bytes of `data` at `offset`. Used by the append
/// buffer: `data` is a full-capacity view whose live prefix is `len` bytes,
/// so a write avoids slicing/copying the buffer.
#borrow(data)
extern "C" fn moonlog_pwrite_len(
  fd : Int32,
  offset : Int64,
  data : Bytes,
  len : Int32,
) -> Int32 = "moonlog_pwrite_len"

///|
extern "C" fn moonlog_size(fd : Int32) -> Int64 = "moonlog_size"

///|
extern "C" fn moonlog_fsync(fd : Int32) -> Int32 = "moonlog_fsync"

///|
extern "C" fn moonlog_fdatasync(fd : Int32) -> Int32 = "moonlog_fdatasync"

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
#borrow(path)
extern "C" fn moonlog_mtime_ns(path : Bytes) -> Int64 = "moonlog_mtime_ns"

///|
#borrow(target, link_path)
extern "C" fn moonlog_symlink(target : Bytes, link_path : Bytes) -> Int32 = "moonlog_symlink"

///|
#borrow(path)
extern "C" fn moonlog_is_symlink(path : Bytes) -> Int32 = "moonlog_is_symlink"

///|
#borrow(path)
extern "C" fn moonlog_remove_with_link(path : Bytes) -> Int32 = "moonlog_remove_with_link"

///|
#borrow(cmd)
extern "C" fn moonlog_run_command(cmd : Bytes) -> Int32 = "moonlog_run_command"

///|
extern "C" fn moonlog_fflush_stdout() -> Int32 = "moonlog_fflush_stdout"

///|
/// Flush C stdout — live tail prints through the C runtime, which buffers
/// when stdout is a pipe or file; `follow --flush` calls this per record so
/// pipelines and redirect targets see records in real time.
pub fn flush_stdout() -> Unit {
  ignore(moonlog_fflush_stdout())
}

///|
/// Try to acquire one query-concurrency slot (4.6): non-blocking exclusive
/// flock on `<dir>/QLOCK.<i>` (the base `moonlog_flock` is already
/// LOCK_NB). Returns the held fd, or -1 when the slot is busy; the caller
/// releases by closing the fd (CLI processes release all slots on exit).
pub fn try_query_slot(dir : String, idx : Int32) -> Int32 {
  try_named_lock(dir, "QLOCK." + idx.to_string())
}

///|
/// Try to acquire a non-blocking exclusive flock on `<dir>/<name>` (6.2:
/// per-tenant query slots live in `QLOCK.<role>.<i>` files beside the global
/// pool). Returns the held fd, or -1 when the lock is busy or cannot be
/// opened; the caller releases by closing the fd.
pub fn try_named_lock(dir : String, name : String) -> Int32 {
  let path = dir + "/" + name
  let fd = moonlog_open_rw(@utf8.encode(path))
  if fd < 0 {
    return -1
  }
  let r = moonlog_flock(fd, 1)
  if r < 0 {
    ignore(moonlog_close(fd))
    return -1
  }
  fd
}

///|
extern "C" fn moonlog_tcp_listen(port : Int32) -> Int32 = "moonlog_tcp_listen"

///|
extern "C" fn moonlog_tcp_accept(listen_fd : Int32) -> Int32 = "moonlog_tcp_accept"

///|
extern "C" fn moonlog_tcp_accept_timeout(
  listen_fd : Int32,
  ms : Int32,
) -> Int32 = "moonlog_tcp_accept_timeout"

///|
extern "C" fn moonlog_install_shutdown_handler() -> Int32 = "moonlog_install_shutdown_handler"

///|
extern "C" fn moonlog_shutdown_requested() -> Int32 = "moonlog_shutdown_requested"

///|
extern "C" fn moonlog_conn_read(fd : Int32, max : Int32) -> Bytes = "moonlog_conn_read"

///|
#borrow(data)
extern "C" fn moonlog_conn_write(fd : Int32, data : Bytes) -> Int32 = "moonlog_conn_write"

///|
extern "C" fn moonlog_conn_set_timeouts(
  fd : Int32,
  recv_ms : Int32,
  send_ms : Int32,
) -> Int32 = "moonlog_conn_set_timeouts"

///|
extern "C" fn moonlog_conn_close_graceful(fd : Int32) -> Int32 = "moonlog_conn_close_graceful"

///|
#borrow(path)
extern "C" fn moonlog_mkfifo(path : Bytes, mode : Int32) -> Int32 = "moonlog_mkfifo"

///|
#borrow(path)
extern "C" fn moonlog_open_read_blocking(path : Bytes) -> Int32 = "moonlog_open_read_blocking"

///|
extern "C" fn moonlog_read_blocking(fd : Int32, max : Int32) -> Bytes = "moonlog_read_blocking"

///|
/// Number of buffered bytes at which an append is flushed to the descriptor.
const WRITE_BUFFER_LIMIT : Int32 = 65536

///|
/// Native file-backed append-only log. A single open file descriptor serves
/// both writing (append) and random-access reading. Appends accumulate in a
/// small in-memory buffer coalesced into fewer `pwrite` calls; the buffer is
/// drained before any read, `flush`, `truncate` or `close`.
pub(all) struct NativeFileLog {
  fd : Int32
  path : Bytes
  mut size : Int64
  mut flushed : Int64
  // Append buffer: a fixed-capacity byte array plus a used length, so adding
  // a record is a memcpy into the tail instead of reallocating and copying
  // the whole buffer on every append (the old `pending = pending + chunk`
  // was O(n^2) per 64KB window).
  mut pending : FixedArray[Byte]
  mut pending_len : Int32
  mut closed : Bool
  mut raw : Bytes?
  // M181: after the first full fsync (which persists the file's directory
  // entry), appends only extend the file — later flushes can use fdatasync
  // and skip the inode metadata writeback per batch.
  mut data_synced : Bool
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
  {
    fd,
    path: bytes,
    size,
    flushed: size,
    pending: FixedArray::make(0, b'\x00'),
    pending_len: 0,
    closed: false,
    data_synced: false,
    raw: None,
  }
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
  {
    fd,
    path: bytes,
    size,
    flushed: size,
    pending: FixedArray::make(0, b'\x00'),
    pending_len: 0,
    closed: false,
    data_synced: false,
    raw: None,
  }
}

///|
/// Open a compressed segment file into an in-memory read-only view: the whole
/// file is decompressed eagerly and served from memory. `raw_size` is the
/// uncompressed length recorded in the segment's index.
pub fn NativeFileLog::open_compressed(
  path : String,
  raw_size : Int64,
  algo : Int32,
) -> NativeFileLog raise @io.IoError {
  let bytes = @utf8.encode(path)
  let compressed = read_file(path)
  let raw = try {
    if algo == 2 {
      @core.lz_decompress(compressed, raw_size)
    } else {
      @core.rle_decompress(compressed, raw_size)
    }
  } catch {
    _ => raise @io.IoError::Corrupt((0 : Int64))
  }
  let len = raw.length().to_int64()
  {
    fd: (-1 : Int32),
    path: bytes,
    size: len,
    flushed: len,
    pending: FixedArray::make(0, b'\x00'),
    pending_len: 0,
    closed: false,
    data_synced: false,
    raw: Some(raw),
  }
}

///|
/// Close the underlying file descriptor. Idempotent.
pub fn NativeFileLog::close(self : NativeFileLog) -> Unit {
  if !self.closed {
    ignore(self.write_pending() catch { _ => () })
    if self.fd >= 0 {
      ignore(moonlog_close(self.fd))
    }
    self.closed = true
  }
}

///|
/// Write any buffered bytes to the descriptor (no fsync). Idempotent.
fn NativeFileLog::write_pending(self : NativeFileLog) -> Unit raise @io.IoError {
  match self.raw {
    Some(_) => return
    None => ()
  }
  if self.pending_len == 0 {
    return
  }
  let data = self.pending.unsafe_reinterpret_as_bytes()
  let n = moonlog_pwrite_len(self.fd, self.flushed, data, self.pending_len)
  if n < 0 {
    raise @io.IoError::Syscall(n)
  }
  self.flushed = self.flushed + n.to_int64()
  if n < self.pending_len {
    // Short write: keep the unwritten tail at the head of the buffer.
    let remain = self.pending_len - n
    self.pending.blit_from_bytes(0, data, n, remain)
    self.pending_len = remain
  } else {
    self.pending_len = 0
  }
}

///|
/// Flush buffered bytes to the file (without fsync) so the on-disk size matches
/// the logical size; used before writing metadata sidecars.
pub fn NativeFileLog::drain(self : NativeFileLog) -> Unit raise @io.IoError {
  self.write_pending()
}

///|
pub fn NativeFileLog::is_closed(self : NativeFileLog) -> Bool {
  self.closed
}

///|
/// Create a directory (parent of log files). Returns true if created or it
/// already existed.

///|
/// Create `path` and any missing parent directories ("a/b/c" creates "a" and
/// "a/b" first). Returns true when the directory exists afterwards.
pub fn ensure_dir(path : String) -> Bool {
  if path.length() == 0 {
    return false
  }
  let bytes = @utf8.encode(path)
  if moonlog_exists(bytes) == 1 {
    return true
  }
  let mut i = 1
  while i <= path.length() {
    if i == path.length() || path[i].to_int() == 47 {
      let sub = path[0:i].to_owned()
      if sub.length() > 0 {
        let sb = @utf8.encode(sub)
        if moonlog_exists(sb) == 0 {
          ignore(moonlog_mkdir(sb))
        }
      }
    }
    i = i + 1
  }
  moonlog_exists(bytes) == 1
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
  match self.raw {
    Some(_) => raise @io.IoError::Closed
    None => ()
  }
  if chunk.length() >= WRITE_BUFFER_LIMIT {
    // Large chunks bypass the buffer: draining first keeps ordering, then a
    // single pwrite lands the whole chunk without a copy.
    self.write_pending()
    let n = moonlog_pwrite(self.fd, self.flushed, chunk)
    if n < 0 {
      raise @io.IoError::Syscall(n)
    }
    self.flushed = self.flushed + n.to_int64()
  } else {
    if self.pending.length() == 0 {
      self.pending = FixedArray::make(WRITE_BUFFER_LIMIT, b'\x00')
    }
    if self.pending_len + chunk.length() > WRITE_BUFFER_LIMIT {
      self.write_pending()
    }
    self.pending.blit_from_bytes(self.pending_len, chunk, 0, chunk.length())
    self.pending_len = self.pending_len + chunk.length()
    if self.pending_len >= WRITE_BUFFER_LIMIT {
      self.write_pending()
    }
  }
  self.size = self.size + chunk.length().to_int64()
  self.size
}

///|
pub impl @io.LogWriter for NativeFileLog with fn flush(self) {
  if self.closed {
    raise @io.IoError::Closed
  }
  match self.raw {
    Some(_) => return
    None => ()
  }
  self.write_pending()
  // M181: the first sync of a segment file must be a full fsync (it persists
  // the file's directory entry); appends only extend the file, so later
  // flushes use fdatasync and skip the inode metadata writeback per batch.
  let r = if self.data_synced {
    moonlog_fdatasync(self.fd)
  } else {
    moonlog_fsync(self.fd)
  }
  if r < 0 {
    raise @io.IoError::Syscall(r)
  }
  self.data_synced = true
}

///|
pub impl @io.LogReader for NativeFileLog with fn read_at(self, offset, len) {
  if self.closed {
    raise @io.IoError::Closed
  }
  if offset < (0 : Int64) || offset + len.to_int64() > self.size {
    raise @io.IoError::OutOfBounds(offset)
  }
  match self.raw {
    Some(r) =>
      @core.slice(r, offset.to_int(), (offset + len.to_int64()).to_int())
    None => {
      self.write_pending()
      moonlog_pread(self.fd, offset, len)
    }
  }
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
  match self.raw {
    Some(_) => return
    None => ()
  }
  self.pending_len = 0
  let r = moonlog_truncate(self.fd, size)
  if r < 0 {
    raise @io.IoError::Syscall(r)
  }
  self.size = size
  self.flushed = size
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
  partition_ms~ : Int64 = 0,
) -> @log.Log[NativeFileLog, NativeFileLog] raise @io.IoError {
  let names = list_dir(dir)
  let mut segs : Array[@segment.Segment[NativeFileLog, NativeFileLog]] = []
  for name in names {
    // Only canonical segment names (`<digits>.log`) are recovered. Anything
    // else ending in `.log` — a stray user file, an audit log — must never
    // be opened as a segment: its content would be truncated as a "corrupt
    // tail" (6.3 regression smoke caught exactly that with AUDIT.log).
    if name.has_suffix(".log") && parse_base_from_log_name(name) is Some(_) {
      let path = dir + "/" + name
      match load_compressed_segment(dir, name, path) {
        Some(seg) => segs = insert_segment_sorted(segs, seg)
        None => {
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
    }
  }
  @log.Log::recover(
    roll_size,
    base => {
      open_segment_in_dir(dir, base, interval=index_interval_for(roll_size))
    },
    segs,
    sync~,
    partition_ms~,
  )
}

///|
/// If the segment named by `<digits>.log` is stored compressed (its index says
/// so), load it into a read-only decompressing view; otherwise return `None`.
fn load_compressed_segment(
  dir : String,
  name : String,
  path : String,
) -> @segment.Segment[NativeFileLog, NativeFileLog]? raise @io.IoError {
  match parse_base_from_log_name(name) {
    None => None
    Some(base) => {
      let ip = segment_index_path(dir, base)
      if !file_exists(ip) {
        return None
      }
      let decoded = Some(@segment.decode_segment_meta(read_file(ip))) catch {
        _ => None
      }
      match decoded {
        Some(m) =>
          if m.base_offset == base && m.compressed {
            let f = NativeFileLog::open_compressed(
              path,
              m.raw_size,
              m.comp_algo,
            )
            let seg : @segment.Segment[NativeFileLog, NativeFileLog] = @segment.Segment::new(
              f, f, base,
            )
            seg.apply_meta(m)
            load_segment_keys(dir, base, seg)
            seg.mark_fsync_clean()
            Some(seg)
          } else {
            None
          }
        None => None
      }
    }
  }
}

///|
/// Parse the base offset out of a `<digits>.log` segment file name.
fn parse_base_from_log_name(name : String) -> UInt64? {
  if !name.has_suffix(".log") {
    return None
  }
  let digits = name[0:name.length() - 4].to_owned()
  let v = @string.parse_uint64(digits) catch { _ => return None }
  Some(v)
}

///|
#borrow(path)
extern "C" fn moonlog_read_file(path : Bytes) -> Bytes = "moonlog_read_file"

///|
#borrow(path, data)
extern "C" fn moonlog_write_file(path : Bytes, data : Bytes) -> Int32 = "moonlog_write_file"

///|
#borrow(path, data)
extern "C" fn moonlog_append_file(path : Bytes, data : Bytes) -> Int32 = "moonlog_append_file"

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
/// Atomically append `data` to `path` (O_APPEND + fsync, creating the file
/// when absent): concurrent processes appending audit events never
/// overwrite each other's bytes.
pub fn append_file(path : String, data : Bytes) -> Unit raise @io.IoError {
  let r = moonlog_append_file(@utf8.encode(path), data)
  if r < 0 {
    raise @io.IoError::Syscall(r)
  }
}

///|
#borrow(path)
extern "C" fn moonlog_statvfs_avail(path : Bytes) -> Int64 = "moonlog_statvfs_avail"

///|
#borrow(path)
extern "C" fn moonlog_statvfs_total(path : Bytes) -> Int64 = "moonlog_statvfs_total"

///|
/// Free bytes on the filesystem holding `path` (6.4 disk watermark), or -1
/// when the filesystem cannot be queried.
pub fn fs_bytes_available(path : String) -> Int64 {
  moonlog_statvfs_avail(@utf8.encode(path))
}

///|
/// Total bytes of the filesystem holding `path` (6.4), or -1.
pub fn fs_bytes_total(path : String) -> Int64 {
  moonlog_statvfs_total(@utf8.encode(path))
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
/// File name of a segment's persisted key index.
fn segment_keys_name(base : UInt64) -> String {
  @segment.segment_file_name(base) + ".keys"
}

///|
/// Path of a segment's persisted key index.
fn segment_keys_path(dir : String, base : UInt64) -> String {
  dir + "/" + segment_keys_name(base)
}

///|
/// Load a segment's persisted key index into memory, falling back to a full
/// rebuild scan when the sidecar is missing or invalid.
fn load_segment_keys(
  dir : String,
  base : UInt64,
  seg : @segment.Segment[NativeFileLog, NativeFileLog],
) -> Unit {
  let kp = segment_keys_path(dir, base)
  let loaded = if file_exists(kp) {
    Some(seg.load_keys(read_file(kp))) catch {
      _ => None
    }
  } else {
    None
  }
  match loaded {
    Some(_) => seg.mark_meta_clean()
    None => ignore(seg.rebuild_index() catch { _ => 0 })
  }
  // The inverted/field-column sidecar is optional: absence just means the
  // index is rebuilt lazily on the first indexed query (and rewritten on the
  // next flush).
  load_segment_inv(dir, base, seg)
}

///|
/// File name of a segment's persisted inverted/field-column index sidecar.
fn segment_inv_name(base : UInt64) -> String {
  @segment.segment_file_name(base) + ".inv"
}

///|
/// Path of a segment's persisted inverted/field-column index sidecar.
fn segment_inv_path(dir : String, base : UInt64) -> String {
  dir + "/" + segment_inv_name(base)
}

///|
/// Persist a segment's inverted/field-column index sidecar atomically. Queries
/// build it lazily under a shared lock; an atomic replace keeps concurrent
/// readers from observing a torn file, and the next process can load it
/// instead of rebuilding.
pub fn save_segment_inv(
  dir : String,
  base : UInt64,
  data : Bytes,
) -> Unit raise @io.IoError {
  write_file_atomic(dir, segment_inv_name(base), data)
}

///|
pub fn has_segment_inv(dir : String, base : UInt64) -> Bool {
  file_exists(segment_inv_path(dir, base))
}

///|
/// Load a segment's persisted inverted/field-column index into memory. A
/// missing or invalid sidecar is fine — the index is rebuilt lazily on the
/// first indexed query.
fn load_segment_inv(
  dir : String,
  base : UInt64,
  seg : @segment.Segment[NativeFileLog, NativeFileLog],
) -> Unit {
  let ip = segment_inv_path(dir, base)
  if file_exists(ip) {
    let decoded = Some(@segment.decode_inv_index(read_file(ip))) catch {
      _ => None
    }
    match decoded {
      Some(ix) => seg.inv_index = Some(ix)
      // A sidecar written by an older sidecar version (v2 before 3.3's front
      // coding) or one failing CRC cannot be used. Drop it so the next
      // indexed query rebuilds and persists the current format instead of
      // rebuilding on every run.
      None => ignore(remove_file(ip))
    }
  }
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
/// Remove a segment's data and sidecars (retention): the data file (following
/// a cold-tier symlink), the sparse index, the key index and the inverted/
/// field-column index. The `.inv` sidecar must go too (review of 6.6): a
/// later segment reusing the same base offset would otherwise load the stale
/// index and answer indexed/inverted queries with ghost records.
pub fn remove_segment_files(dir : String, base : UInt64) -> Unit {
  ignore(
    moonlog_remove_with_link(
      @utf8.encode(dir + "/" + @segment.segment_file_name(base)),
    ),
  )
  ignore(remove_file(segment_index_path(dir, base)))
  ignore(remove_file(segment_keys_path(dir, base)))
  ignore(remove_file(segment_inv_path(dir, base)))
  ignore(fsync_dir(dir) catch { _ => () })
}

///|
/// Load one segment, preferring its persisted index; falls back to a full
/// recover scan when the index is missing or invalid.
fn load_segment(
  dir : String,
  base : UInt64,
) -> @segment.Segment[NativeFileLog, NativeFileLog] raise @io.IoError {
  let ip = segment_index_path(dir, base)
  let decoded : @segment.SegmentMeta? = if file_exists(ip) {
    Some(@segment.decode_segment_meta(read_file(ip))) catch {
      _ => None
    }
  } else {
    None
  }
  let valid : @segment.SegmentMeta? = match decoded {
    Some(m) => if m.base_offset == base { Some(m) } else { None }
    None => None
  }
  let path = dir + "/" + @segment.segment_file_name(base)
  let f = match valid {
    Some(m) =>
      if m.compressed {
        NativeFileLog::open_compressed(path, m.raw_size, m.comp_algo)
      } else {
        NativeFileLog::open(path)
      }
    None => NativeFileLog::open(path)
  }
  let seg : @segment.Segment[NativeFileLog, NativeFileLog] = @segment.Segment::new(
    f, f, base,
  )
  match valid {
    Some(m) => {
      seg.apply_meta(m)
      load_segment_keys(dir, base, seg)
      // The data already lives on disk; only writes made in this process need
      // an fsync, so a freshly loaded segment starts clean.
      seg.mark_fsync_clean()
    }
    None => ignore(seg.recover())
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
  partition_ms~ : Int64 = 0,
) -> @log.Log[NativeFileLog, NativeFileLog] raise @io.IoError {
  let mpath = dir + "/" + MANIFEST_NAME
  if !file_exists(mpath) {
    return recover_log_dir(dir, roll_size, sync~, partition_ms~)
  }
  let manifest = Some(@log.decode_manifest(read_file(mpath))) catch {
    _ => None
  }
  match manifest {
    Some(m) =>
      if m.roll_size != roll_size {
        recover_log_dir(dir, roll_size, sync~, partition_ms~)
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
            partition_ms~,
          )
        } else {
          for seg in segs {
            seg.writer.close()
          }
          recover_log_dir(dir, roll_size, sync~, partition_ms~)
        }
      }
    None => recover_log_dir(dir, roll_size, sync~, partition_ms~)
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
  let n = log.segments.length()
  let mut i = 0
  for seg in log.segments {
    seg.writer.drain()
    let is_active = i == n - 1
    if !is_active && !seg.has_checksum() {
      seg.set_checksum(seg.compute_checksum())
    }
    if seg.needs_meta_write() {
      write_file_atomic(
        dir,
        segment_index_name(seg.base_offset),
        seg.to_meta().encode(),
      )
      write_file_atomic(
        dir,
        segment_keys_name(seg.base_offset),
        seg.encode_keys(),
      )
      seg.mark_meta_clean()
    }
    // Persist the inverted/field-column index whenever it has been built
    // (lazily, by an indexed query); rewritten idempotently per flush.
    match seg.inv_index {
      Some(ix) =>
        write_file_atomic(dir, segment_inv_name(seg.base_offset), ix.encode())
      None => ()
    }
    bases.push(seg.base_offset)
    let stored = if seg.is_compressed() {
      segment_file_size(dir, seg.base_offset)
    } else {
      seg.byte_size()
    }
    sizes.push(stored)
    i = i + 1
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
/// Compress every rolled-over (non-active) segment of an already-open log in
/// place with `algo` (1 = RLE, 2 = LZSS), rewriting each segment's data file
/// atomically and recording its checksum, raw size and algorithm for the next
/// metadata flush. Returns the number of segments compressed.
pub fn compress_rolled_segments(
  dir : String,
  log : @log.Log[NativeFileLog, NativeFileLog],
  algo~ : Int32 = 2,
) -> Int32 raise @io.IoError {
  let n = log.segment_count()
  let mut packed = 0
  let mut i = 0
  while i < n {
    if i < n - 1 {
      let seg = log.segments[i]
      if !seg.is_compressed() {
        let raw_size = seg.byte_size()
        let raw = seg.reader.read_at((0 : Int64), raw_size.to_int())
        seg.set_checksum(@core.crc32(raw))
        let packed_bytes = if algo == 1 {
          @core.rle_compress(raw)
        } else {
          @core.lz_compress(raw)
        }
        // Only replace the raw segment when the candidate is actually smaller:
        // tiny or incompressible segments would otherwise grow on disk.
        if packed_bytes.length() < raw.length() {
          write_file_atomic(
            dir,
            @segment.segment_file_name(seg.base_offset),
            packed_bytes,
          )
          seg.mark_compressed(raw_size, algo)
          seg.mark_fsync_clean()
          // Persist the compressed segment meta before reopening: without
          // this the on-disk .index still says `compressed=false` and the
          // reopen below would fall back to a plain (now-compressed) file.
          write_file_atomic(
            dir,
            segment_index_name(seg.base_offset),
            seg.to_meta().encode(),
          )
          packed = packed + 1
          // The segment's fd still points at the orphaned raw inode, so the
          // live log object must switch to the decompressing view of the new
          // file — otherwise a verify in the same maintenance pass reads raw
          // bytes against the compressed checksum and flags corruption
          // (3.6 third round). Per-segment reopen, not a whole-log reopen:
          // the latter re-reads the manifest and was observed dropping every
          // compressed segment.
          seg.writer.close()
          let name = @segment.segment_file_name(seg.base_offset)
          match load_compressed_segment(dir, name, dir + "/" + name) {
            Some(reopened) => log.segments[i] = reopened
            None => ()
          }
        }
      }
    }
    i = i + 1
  }
  packed
}

///|
/// Compress every rolled-over (non-active) segment of `dir` in place with `algo`
/// (1 = RLE, 2 = LZSS). Each compressed segment records its uncompressed size,
/// algorithm and a checksum of the raw data in its index, and the manifest is
/// refreshed. Returns the number of segments compressed.
pub fn compress_log_dir(
  dir : String,
  roll_size : Int64,
  algo~ : Int32 = 2,
) -> Int32 raise @io.IoError {
  let log = open_log_dir(dir, roll_size)
  let packed = compress_rolled_segments(dir, log, algo~)
  flush_meta(dir, log)
  for seg in log.segments {
    seg.writer.close()
  }
  packed
}

///|
/// Number of rolled-over (non-active) segments that `compress_log_dir` would
/// compress, without modifying anything.
pub fn count_compressible_segments(
  dir : String,
  roll_size : Int64,
) -> Int32 raise @io.IoError {
  let log = open_log_dir(dir, roll_size)
  let n = log.segment_count()
  let mut count = 0
  let mut i = 0
  while i < n {
    if i < n - 1 && !log.segments[i].is_compressed() {
      count = count + 1
    }
    i = i + 1
  }
  for seg in log.segments {
    seg.writer.close()
  }
  count
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
/// All persisted consumer positions in `dir`: the default cursor (name "")
/// plus every named cursor. A corrupt cursor file reads back as position 0,
/// which conservatively protects every segment.
pub fn list_cursor_positions(
  dir : String,
) -> Array[(String, UInt64)] raise @io.IoError {
  let out : Array[(String, UInt64)] = []
  if file_exists(cursor_path(dir)) {
    out.push(("", load_cursor(dir)))
  }
  for name in list_named_cursors(dir) {
    out.push((name, load_named_cursor(dir, name)))
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
extern "C" fn moonlog_sleep_ms(ms : Int32) -> Int32 = "moonlog_sleep_ms"

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

///|
/// Like `acquire`, but retries a busy lock in small steps for up to `timeout_ms`
/// milliseconds before failing. This lets concurrent writers queue instead of
/// failing fast.
pub fn DirLock::acquire_timeout(
  dir : String,
  exclusive : Bool,
  timeout_ms : Int32,
) -> DirLock raise @io.IoError {
  let path = dir + "/LOCK"
  let fd = moonlog_open_rw(@utf8.encode(path))
  if fd < 0 {
    raise @io.IoError::Syscall(fd)
  }
  let flag = if exclusive { 1 } else { 0 }
  let step = 5
  let mut waited = 0
  let mut ok = false
  while !ok {
    if moonlog_flock(fd, flag) >= 0 {
      ok = true
    } else if waited >= timeout_ms {
      ignore(moonlog_close(fd))
      raise @io.IoError::Syscall(-1)
    } else {
      ignore(moonlog_sleep_ms(step))
      waited = waited + step
    }
  }
  { fd, held: true, }
}

///|
/// Sleep for `ms` milliseconds. Used by long-running CLI commands (`follow`,
/// `serve`) that poll the directory between iterations.
pub fn sleep_ms(ms : Int32) -> Unit {
  ignore(moonlog_sleep_ms(ms))
}

///|
/// Rename `from` to `to`. Returns true on success; false when the source is
/// missing or the rename fails.
pub fn rename_file(from : String, to : String) -> Bool {
  moonlog_rename(@utf8.encode(from), @utf8.encode(to)) >= 0
}

///|
/// Whether `name` belongs to a log directory's durable state and is carried by
/// a backup (6.5): segment data files, their `.index`/`.keys`/`.inv` sidecars,
/// the manifest, and the operator policy files (RBAC/TTL/QUOTA) — a restored
/// copy must come back with its configuration so a recovery drill succeeds
/// end to end. `LOCK`, consumer-cursor files and operational trails
/// (AUDIT/TTL_AUDIT/SELFMON) are deliberately excluded: a backup snapshots
/// data, configuration and indexes, not consumer progress, process state or
/// audit history.
fn is_backup_file(name : String) -> Bool {
  name == MANIFEST_NAME ||
  name.has_suffix(".log") ||
  name.has_suffix(".log.index") ||
  name.has_suffix(".log.keys") ||
  name.has_suffix(".log.inv") ||
  name == "RBAC" ||
  name == "TTL" ||
  name == "QUOTA" ||
  name == "PARTITION" ||
  name == "TIER" ||
  name == "SCHEMA" ||
  // The operation-audit trail travels with the backup (6.6 "deletion is
  // verifiable" relies on it surviving a disaster recovery); the live AUDIT
  // file and its rotated AUDIT.N siblings are copied as-is, so a restored
  // copy keeps the accountability history of the source. TTL_AUDIT (automatic
  // maintenance records) and SELFMON runtime state stay excluded.
  name == "AUDIT" ||
  name.has_prefix("AUDIT.") ||
  name == "BATCHES"
}

///|
/// Number of segment data files among the entries of `dir`.
fn count_segment_files(dir : String) -> Int32 raise @io.IoError {
  let mut n = 0
  for name in list_dir(dir) {
    if name.has_suffix(".log") {
      n = n + 1
    }
  }
  n
}

///|
/// The byte size of a file, or -1 when it cannot be opened.
pub fn file_size(path : String) -> Int64 {
  let fd = moonlog_open_ro(@utf8.encode(path))
  if fd < 0 {
    return (-1 : Int64)
  }
  let s = moonlog_size(fd)
  ignore(moonlog_close(fd))
  s
}

///|
fn contains_u64(arr : Array[UInt64], v : UInt64) -> Bool {
  for x in arr {
    if x == v {
      return true
    }
  }
  false
}

///|
/// Last-modification time of a file in nanoseconds since the epoch, or -1
/// when the file cannot be stat'ed.
pub fn file_mtime_ns(path : String) -> Int64 {
  moonlog_mtime_ns(@utf8.encode(path))
}

///|
/// Whether `path` itself is a symbolic link (does not follow it).
pub fn is_symlink(path : String) -> Bool {
  moonlog_is_symlink(@utf8.encode(path)) > 0
}

///|
/// Create a symbolic link at `link_path` pointing at `target`. Returns true on
/// success.
pub fn symlink(target : String, link_path : String) -> Bool {
  moonlog_symlink(@utf8.encode(target), @utf8.encode(link_path)) >= 0
}

///|
/// Atomically point `link_path` at `target`: create `link_path.tmp`, rename it
/// over the existing link. A reader resolving the link sees either the old or
/// the new target, never a missing link (used by `ha-failover --active`).
pub fn replace_symlink(
  target : String,
  link_path : String,
) -> Unit raise @io.IoError {
  let tmp = link_path + ".tmp"
  ignore(remove_file(tmp))
  if !symlink(target, tmp) {
    raise @io.IoError::Syscall(-1)
  }
  if !rename_file(tmp, link_path) {
    raise @io.IoError::Syscall(-1)
  }
}

///|
/// Run a shell command and return its exit status (0 on success). The caller
/// must shell-quote any user-provided arguments (see `@core.shell_quote`);
/// used for webhook-style notification delivery.
pub fn run_command(cmd : String) -> Int32 {
  moonlog_run_command(@utf8.encode(cmd))
}

///|
/// Listen on 127.0.0.1:`port` for HTTP pushes. Returns the socket fd, or a
/// negative value when the port cannot be bound.
pub fn tcp_listen(port : Int32) -> Int32 {
  moonlog_tcp_listen(port)
}

///|
/// Accept one pending connection (blocking). Returns the connection fd, or a
/// negative value on error.
pub fn tcp_accept(listen_fd : Int32) -> Int32 {
  moonlog_tcp_accept(listen_fd)
}

///|
/// Accept one pending connection, waiting at most `ms` milliseconds. Returns
/// the connection fd, or a negative value on timeout/error.
pub fn tcp_accept_timeout(listen_fd : Int32, ms : Int32) -> Int32 {
  moonlog_tcp_accept_timeout(listen_fd, ms)
}

///|
/// Install SIGTERM/SIGINT handlers that only set an in-process flag (no work
/// runs in the handler). Long-running commands poll `shutdown_requested` and
/// finish in-flight work before exiting.
pub fn install_shutdown_handler() -> Unit {
  ignore(moonlog_install_shutdown_handler())
}

///|
/// Whether a shutdown was requested via SIGTERM/SIGINT.
pub fn shutdown_requested() -> Bool {
  moonlog_shutdown_requested() > 0
}

///|
/// Read up to `max` bytes from a connection; empty means EOF or error.
pub fn conn_read(fd : Int32, max : Int32) -> Bytes {
  moonlog_conn_read(fd, max)
}

///|
/// Write `data` to a connection; returns the number of bytes written. The
/// native side loops over short writes, so the return equals `data.length()`
/// unless the peer fails or the send timeout expires.
pub fn conn_write(fd : Int32, data : Bytes) -> Int32 {
  moonlog_conn_write(fd, data)
}

///|
/// Set receive/send timeouts (milliseconds) on a connection. A stalled client
/// then fails the read after `recv_ms` instead of blocking the serial accept
/// loop forever; zero disables that timeout.
pub fn conn_set_timeouts(fd : Int32, recv_ms : Int32, send_ms : Int32) -> Unit {
  ignore(moonlog_conn_set_timeouts(fd, recv_ms, send_ms))
}

///|
/// Half-close then close a connection so a fully written response is not
/// truncated by a reset (see the native stub).
pub fn conn_close_graceful(fd : Int32) -> Unit {
  ignore(moonlog_conn_close_graceful(fd))
}

///|
/// Close a raw descriptor (connection, listen socket, FIFO).
pub fn close_fd(fd : Int32) -> Unit {
  ignore(moonlog_close(fd))
}

///|
/// Create a FIFO (named pipe) at `path`. Returns true on success.
pub fn mkfifo(path : String, mode : Int32) -> Bool {
  moonlog_mkfifo(@utf8.encode(path), mode) >= 0
}

///|
/// Open `path` for reading, blocking until a writer appears (FIFO semantics);
/// for regular files this opens immediately. Returns the fd or -1.
pub fn open_read_blocking(path : String) -> Int32 {
  moonlog_open_read_blocking(@utf8.encode(path))
}

///|
/// Read one chunk from a blocking descriptor; empty means EOF (writer closed).
pub fn read_blocking(fd : Int32, max : Int32) -> Bytes {
  moonlog_read_blocking(fd, max)
}

///|
/// Tier a log directory into hot/warm/cold storage: rolled segments are
/// compressed in place (warm), and segments older than the last
/// `warm_segments` rolled ones are copied into `cold_dir` with the main path
/// atomically replaced by a symbolic link to the cold copy (cold). The active
/// segment always stays hot. Because only the link changes, every reader,
/// verifier and backup keeps working unchanged; pruning a cold segment removes
/// its cold copy too. Returns the number of segments moved cold this run
/// (already-migrated segments are skipped, so the command is idempotent).
pub fn tier_log_dir(
  dir : String,
  cold_dir : String,
  roll_size : Int64,
  warm_segments : Int32,
) -> Int32 raise @io.IoError {
  // Refuse relative cold paths: the per-segment symlink resolves relative to
  // the main directory, so a relative target would silently dangle and make
  // migrated segments unreadable.
  if cold_dir.length() == 0 || cold_dir.at(0).to_int() != 47 {
    raise @io.IoError::Invalid("cold-dir must be an absolute path: " + cold_dir)
  }
  ignore(ensure_dir(cold_dir))
  let log = open_log_dir(dir, roll_size)
  let n = log.segment_count()
  ignore(compress_rolled_segments(dir, log))
  let cut = n - 1 - warm_segments
  let mut moved = 0
  let mut i = 0
  while i < n {
    if i < cut {
      let base = log.segments[i].base_offset
      let name = @segment.segment_file_name(base)
      let main_path = dir + "/" + name
      if !is_symlink(main_path) {
        let cold_path = cold_dir + "/" + name
        write_file(cold_path, read_file(main_path))
        ignore(fsync_dir(cold_dir) catch { _ => () })
        let tmp_link = dir + "/" + name + ".tmplink"
        if symlink(cold_path, tmp_link) {
          let rc = moonlog_rename(
            @utf8.encode(tmp_link),
            @utf8.encode(main_path),
          )
          if rc >= 0 {
            moved = moved + 1
          } else {
            ignore(remove_file(tmp_link))
          }
        }
      }
    }
    i = i + 1
  }
  flush_meta(dir, log)
  for seg in log.segments {
    seg.writer.close()
  }
  moved
}

///|
/// Copy every durable-state file from `src` into directory `dst`, returning
/// the number of segment data files copied this run. The caller must hold the
/// exclusive directory lock on `src` and have flushed both data (`Log::flush`)
/// and metadata (`flush_meta`) beforehand, so the copied files form a
/// consistent snapshot.
///
/// Backing up over an earlier backup makes an incremental pass: a segment
/// already present in `dst` whose copy is newer than the source's last
/// modification is skipped — appends only grow the source, and compaction or
/// merge rewrite segments under the same file name, so any change makes the
/// source's mtime newer than the copy. Backups of segments that no longer
/// exist at the source (merged, compacted or pruned away) are deleted. The
/// small manifest and per-segment sidecars may change in place, so they are
/// always recopied. The first run into an empty (or not yet existing) `dst`
/// is a full backup.
pub fn backup_log_dir(src : String, dst : String) -> Int32 raise @io.IoError {
  ignore(ensure_dir(dst))
  let src_names = list_dir(src)
  let src_segments : Array[UInt64] = []
  for name in src_names {
    match parse_base_from_log_name(name) {
      Some(base) => src_segments.push(base)
      None => ()
    }
  }
  for name in list_dir(dst) {
    match parse_base_from_log_name(name) {
      Some(base) =>
        if !contains_u64(src_segments, base) {
          remove_segment_files(dst, base)
        }
      None => ()
    }
  }
  let mut copied = 0
  for name in src_names {
    if !is_backup_file(name) {
      continue
    }
    let dst_path = dst + "/" + name
    let src_path = src + "/" + name
    let existing = file_size(dst_path)
    // A backed-up copy is trustworthy while it is newer than the source's
    // last modification: appends only grow the source (newer mtime), and
    // compaction or merge rewrite segments under the same file name (also
    // newer mtime) — either way the source then wins and is recopied. When
    // the source has not been touched since the last pass its mtime stays
    // older than the copy, and the copy is skipped. The manifest and
    // sidecars are rewritten in place, so recopy them.
    let skip = name.has_suffix(".log") &&
      existing >= (0 : Int64) &&
      existing == file_size(src_path) &&
      file_mtime_ns(dst_path) > file_mtime_ns(src_path)
    if !skip {
      write_file(dst_path, read_file(src_path))
      if name.has_suffix(".log") {
        copied = copied + 1
      }
    }
  }
  // SELFMON/thresholds is configuration (like RBAC/TTL/QUOTA), while the
  // sibling http.json is runtime state; carry only the thresholds file.
  if file_exists(src + "/SELFMON/thresholds") {
    ignore(ensure_dir(dst + "/SELFMON"))
    write_file(
      dst + "/SELFMON/thresholds",
      read_file(src + "/SELFMON/thresholds"),
    )
  }
  fsync_dir(dst)
  copied
}

///|
/// Materialize a backup made by `backup_log_dir`: copy its files into the
/// empty (or not yet existing) directory `dst`. The backup must contain a
/// decodable `MANIFEST`. Files are copied verbatim, so offsets are preserved
/// exactly — the restored copy continues where the source stopped. Returns
/// the number of segment data files restored.
pub fn restore_log_dir(src : String, dst : String) -> Int32 raise @io.IoError {
  let mpath = src + "/" + MANIFEST_NAME
  if !file_exists(mpath) {
    raise @io.IoError::Invalid("not a backup (missing MANIFEST): " + src)
  }
  let manifest_ok = try {
    let m = @log.decode_manifest(read_file(mpath))
    ignore(m.encode())
    true
  } catch {
    _ => false
  }
  if !manifest_ok {
    raise @io.IoError::Invalid("corrupt MANIFEST in backup: " + src)
  }
  ignore(ensure_dir(dst))
  if list_dir(dst).length() > 0 {
    raise @io.IoError::Invalid("restore target not empty: " + dst)
  }
  for name in list_dir(src) {
    if is_backup_file(name) {
      write_file(dst + "/" + name, read_file(src + "/" + name))
    }
  }
  // SELFMON/thresholds is configuration (like RBAC/TTL/QUOTA), while the
  // sibling http.json is runtime state; carry only the thresholds file.
  if file_exists(src + "/SELFMON/thresholds") {
    ignore(ensure_dir(dst + "/SELFMON"))
    write_file(
      dst + "/SELFMON/thresholds",
      read_file(src + "/SELFMON/thresholds"),
    )
  }
  fsync_dir(dst)
  count_segment_files(dst)
}

///|
/// Rename a corrupt segment and its sidecars out of the way (suffix
/// `.corrupt`) so a repair can rebuild without them while preserving the
/// evidence for later inspection.
fn quarantine_segment(dir : String, base : UInt64) -> Unit {
  let data = dir + "/" + @segment.segment_file_name(base)
  ignore(rename_file(data, data + ".corrupt"))
  ignore(
    rename_file(
      segment_index_path(dir, base),
      segment_index_path(dir, base) + ".corrupt",
    ),
  )
  ignore(
    rename_file(
      segment_keys_path(dir, base),
      segment_keys_path(dir, base) + ".corrupt",
    ),
  )
  ignore(
    rename_file(
      segment_inv_path(dir, base),
      segment_inv_path(dir, base) + ".corrupt",
    ),
  )
  ignore(fsync_dir(dir) catch { _ => () })
}

///|
/// Outcome of `repair_log_dir`.
pub(all) struct RepairReport {
  segments : Int32
  records : Int32
  /// Segments whose torn or corrupt tail was cut back to the last good record.
  truncated : Int32
  /// Segments quarantined as `<name>.corrupt` (unreadable, or failing their
  /// whole-segment checksum), together with their sidecars.
  isolated : Int32
  /// Empty segment files removed during the pass.
  removed_empty : Int32
  /// Whether the manifest and per-segment sidecars were rewritten. Always
  /// false in a dry run.
  rebuilt_meta : Bool
  /// First problem a fast verification still reports after the repair, if any.
  /// Always empty in a dry run (no repaired state exists to re-check).
  still_bad : UInt64?
}

///|
/// Walk an already-read segment buffer, counting records that decode cleanly,
/// and return `(record_count, valid_bytes)`. Pure probe: no I/O and no
/// mutation — used by dry-run repair.
fn probe_records(data : Bytes) -> (Int32, Int32) {
  let total = data.length()
  let mut pos : Int32 = 0
  let mut n : Int32 = 0
  let mut go = true
  while go {
    let body_len : Int32? = if pos + 4 > total {
      None
    } else {
      Some(@core.body_len_at(data, pos) catch { _ => -1 })
    }
    match body_len {
      None => go = false
      Some(body) =>
        if body < 0 || pos + 4 + body + 4 > total {
          go = false
        } else {
          let decoded : (@core.Record, Int32)? = Some(
            @core.decode_record(data, pos),
          ) catch {
            _ => None
          }
          match decoded {
            None => go = false
            Some((_rec, next)) => {
              n = n + 1
              pos = next
            }
          }
        }
    }
  }
  (n, pos)
}

///|
/// Inspect every segment file in `dir`, repair what can be repaired, and
/// rebuild the manifest and sidecars:
///
/// - a segment failing its stored whole-segment checksum, or unreadable
///   through its sidecar (e.g. a compressed segment with a broken index), is
///   quarantined as `<name>.corrupt` and excluded from the rebuilt log;
/// - a non-compressed segment with a torn or corrupt tail is truncated to the
///   last good record boundary;
/// - empty segment files are removed;
/// - `MANIFEST` and every surviving segment's sidecars are rewritten
///   atomically, whatever their previous state (missing, corrupt, stale).
///
/// With `dry_run`, nothing is written, renamed or truncated: the pass only
/// reports what a real repair would do — `truncated`/`isolated`/
/// `removed_empty` become "would ..." counts, `rebuilt_meta` is false and
/// `still_bad` stays empty since no repaired state exists to re-check.
///
/// Offsets of surviving segments are preserved, so the repaired log may have
/// holes where segments were quarantined — the same state retention leaves
/// behind, and reads of `verify` treat holes as legal. Returns a report
/// including a fast re-verification of the result. The caller must hold the
/// exclusive directory lock.
pub fn repair_log_dir(
  dir : String,
  roll_size : Int64,
  dry_run~ : Bool = false,
) -> RepairReport raise @io.IoError {
  ignore(ensure_dir(dir))
  let bases : Array[UInt64] = []
  for name in list_dir(dir) {
    match parse_base_from_log_name(name) {
      Some(base) => bases.push(base)
      None => ()
    }
  }
  bases.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
  let segs : Array[@segment.Segment[NativeFileLog, NativeFileLog]] = []
  let mut kept_records : Int32 = 0
  let mut truncated = 0
  let mut isolated = 0
  let mut removed_empty = 0
  for base in bases {
    let data_path = dir + "/" + @segment.segment_file_name(base)
    let ip = segment_index_path(dir, base)
    let meta : @segment.SegmentMeta? = if file_exists(ip) {
      Some(@segment.decode_segment_meta(read_file(ip))) catch {
        _ => None
      }
    } else {
      None
    }
    let valid : @segment.SegmentMeta? = match meta {
      Some(m) => if m.base_offset == base { Some(m) } else { None }
      None => None
    }
    // A compressed segment can only be read through its sidecar; verify it
    // through the decompressing view and quarantine on any failure.
    let compressed_check : Bool? = match valid {
      Some(m) =>
        if m.compressed {
          Some(
            try {
              let f = NativeFileLog::open_compressed(
                data_path,
                m.raw_size,
                m.comp_algo,
              )
              let seg : @segment.Segment[NativeFileLog, NativeFileLog] = @segment.Segment::new(
                f, f, base,
              )
              seg.apply_meta(m)
              let ok = !m.crc_known || seg.compute_checksum() == m.data_crc
              f.close()
              ok
            } catch {
              _ => false
            },
          )
        } else {
          None
        }
      None => None
    }
    match compressed_check {
      Some(ok) => {
        if ok {
          let loaded = Some(load_segment(dir, base)) catch { _ => None }
          match loaded {
            Some(seg) =>
              if dry_run {
                kept_records = kept_records + seg.count()
              } else {
                segs.push(seg)
              }
            None => {
              isolated = isolated + 1
              if !dry_run {
                quarantine_segment(dir, base)
              }
            }
          }
        } else {
          isolated = isolated + 1
          if !dry_run {
            quarantine_segment(dir, base)
          }
        }
        continue
      }
      None => ()
    }
    // Uncompressed (or sidecar-less): open raw and recover, cutting any torn
    // tail back to the last good record.
    let opened = Some(NativeFileLog::open(data_path)) catch { _ => None }
    match opened {
      None => {
        isolated = isolated + 1
        if !dry_run {
          quarantine_segment(dir, base)
        }
      }
      Some(w) => {
        let seg : @segment.Segment[NativeFileLog, NativeFileLog] = @segment.Segment::new(
          w, w, base,
        )
        match valid {
          Some(m) => seg.apply_meta(m)
          None => ()
        }
        // A stored whole-segment checksum that no longer matches quarantines
        // the segment: recovery only understands damage at the tail, and
        // letting it run over a segment corrupted in the middle would drop
        // data without a trace.
        let checksum_bad = if seg.has_checksum() {
          let actual = Some(seg.compute_checksum()) catch { _ => None }
          actual != Some(seg.stored_checksum())
        } else {
          false
        }
        if checksum_bad {
          w.close()
          isolated = isolated + 1
          if !dry_run {
            quarantine_segment(dir, base)
          }
        } else if dry_run {
          // Probe only: report what a recover would cut away, change nothing.
          let data = w.read_at((0 : Int64), w.size.to_int())
          let (n_probe, valid_bytes) = probe_records(data)
          if n_probe <= 0 {
            removed_empty = removed_empty + 1
          } else {
            if valid_bytes.to_int64() < w.size {
              truncated = truncated + 1
            }
            kept_records = kept_records + n_probe
          }
          w.close()
        } else {
          let before = w.size
          let n = seg.recover() catch { _ => 0 }
          if n <= 0 {
            w.close()
            remove_segment_files(dir, base)
            removed_empty = removed_empty + 1
          } else {
            if seg.size < before {
              truncated = truncated + 1
              // The inverted sidecar indexed the pre-truncation records; drop
              // it so the next indexed query rebuilds from the recovered
              // segment instead of loading stale postings every time.
              ignore(remove_file(segment_inv_path(dir, base)))
            }
            segs.push(seg)
          }
        }
      }
    }
  }
  if dry_run {
    return {
      segments: bases.length() - isolated - removed_empty,
      records: kept_records,
      truncated,
      isolated,
      removed_empty,
      rebuilt_meta: false,
      still_bad: (None : UInt64?),
    }
  }
  let log = @log.Log::recover(
    roll_size,
    base => {
      open_segment_in_dir(dir, base, interval=index_interval_for(roll_size))
    },
    segs,
  )
  flush_meta(dir, log)
  let segments = log.segment_count()
  let records = log.count()
  let check = log.verify_fast()
  for seg in log.segments {
    seg.writer.close()
  }
  let still_bad : UInt64? = match check.first_bad_offset {
    Some(off) => Some(off)
    None => check.first_bad_checksum
  }
  {
    segments,
    records,
    truncated,
    isolated,
    removed_empty,
    rebuilt_meta: true,
    still_bad,
  }
}
