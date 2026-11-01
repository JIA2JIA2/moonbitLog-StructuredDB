///|
/// A point-in-time key -> latest-offset index built from a log scan. Keys are
/// interpreted as UTF-8; tombstones remove keys, so only live puts remain.
pub(all) struct KeyIndex {
  entries : @hashmap.HashMap[String, UInt64]
}

///|
pub fn KeyIndex::new() -> KeyIndex {
  { entries: @hashmap.HashMap::HashMap([]), }
}

///|
/// Offset of the latest live record for `key`, if any.
pub fn KeyIndex::latest(self : KeyIndex, key : Bytes) -> UInt64? {
  self.entries.get(@utf8.decode_lossy(key))
}

///|
/// Number of live keys.
pub fn KeyIndex::size(self : KeyIndex) -> Int32 {
  self.entries.length()
}

///|
fn KeyIndex::put(self : KeyIndex, key : Bytes, offset : UInt64) -> Unit {
  self.entries.set(@utf8.decode_lossy(key), offset)
}

///|
fn KeyIndex::drop(self : KeyIndex, key : Bytes) -> Unit {
  self.entries.remove(@utf8.decode_lossy(key))
}

///|
/// Build the live key index by scanning the whole log (tombstones remove keys).
pub fn[W, R : @io.LogReader] Log::build_key_index(
  self : Log[W, R],
) -> KeyIndex raise @io.IoError {
  let index = KeyIndex::new()
  self.for_each((0 : UInt64), self.next_offset, rec => {
    if rec.is_delete() {
      index.drop(rec.key)
    } else {
      index.put(rec.key, rec.offset)
    }
  })
  index
}

///|
/// Latest live record for `key`, via a prebuilt index.
pub fn[W, R : @io.LogReader] Log::get_latest(
  self : Log[W, R],
  index : KeyIndex,
  key : Bytes,
) -> @core.Record? raise @io.IoError {
  match index.latest(key) {
    Some(off) => self.get(off)
    None => None
  }
}

///|
/// Compacted logical view: for each live key, its latest put, with offsets
/// renumbered from 0. Writing these records to a fresh log yields an
/// equivalent but smaller log.
pub fn[W, R : @io.LogReader] Log::snapshot(
  self : Log[W, R],
) -> Array[@core.Record] raise @io.IoError {
  let index = self.build_key_index()
  let live : Array[@core.Record] = []
  self.for_each((0 : UInt64), self.next_offset, rec => {
    if !rec.is_delete() {
      match index.latest(rec.key) {
        Some(off) => if off == rec.offset { live.push(rec) }
        None => ()
      }
    }
  })
  let out : Array[@core.Record] = []
  let mut i = 0
  for rec in live {
    out.push({
      offset: i.to_uint64(),
      timestamp: rec.timestamp,
      kind: @core.RecordKind::Put,
      key: rec.key,
      value: rec.value,
    })
    i = i + 1
  }
  out
}

///|
/// Fold the log down to its live view in place: snapshot the current live
/// records, hand every existing segment to `on_drop` (so the caller can
/// reclaim its files), reset the offset space, and replay the live records
/// into freshly created segments. Returns the number of records written.
///
/// `on_drop` runs *before* the fresh segments are created, so a caller that
/// deletes the dropped segment files by `base_offset` will not accidentally
/// remove the rewritten ones.
pub fn[W : @io.LogWriter, R : @io.LogReader] Log::compact(
  self : Log[W, R],
  on_drop~ : (@segment.Segment[W, R]) -> Unit,
) -> Int32 raise @io.IoError {
  let live = self.snapshot()
  for seg in self.segments {
    on_drop(seg)
  }
  self.segments = []
  self.next_offset = (0 : UInt64)
  for rec in live {
    ignore(self.append(rec.key, rec.value, rec.timestamp))
  }
  live.length()
}

///|
/// Latest live record for `key` that has not outlived `ttl` at `now`: a record
/// with `now - timestamp > ttl` is treated as expired and reported as absent.
pub fn[W, R : @io.LogReader] Log::get_latest_at(
  self : Log[W, R],
  index : KeyIndex,
  key : Bytes,
  now : Int64,
  ttl : Int64,
) -> @core.Record? raise @io.IoError {
  match self.get_latest(index, key) {
    Some(rec) =>
      if now - rec.timestamp > ttl {
        (None : @core.Record?)
      } else {
        Some(rec)
      }
    None => (None : @core.Record?)
  }
}

///|
/// Live records (latest put per key) that have not outlived `ttl` at `now`, in
/// log order.
pub fn[W, R : @io.LogReader] Log::scan_live(
  self : Log[W, R],
  now : Int64,
  ttl : Int64,
) -> Array[@core.Record] raise @io.IoError {
  let index = self.build_key_index()
  let out : Array[@core.Record] = []
  self.for_each((0 : UInt64), self.next_offset, rec => {
    if !rec.is_delete() {
      match index.latest(rec.key) {
        Some(off) =>
          if off == rec.offset && now - rec.timestamp <= ttl {
            out.push(rec)
          }
        None => ()
      }
    }
  })
  out
}

///|
/// Lexicographic byte comparison, used to order keys by their raw bytes.
fn bytes_cmp(a : Bytes, b : Bytes) -> Int32 {
  let an = a.length()
  let bn = b.length()
  let n = if an < bn { an } else { bn }
  let mut i = 0
  while i < n {
    let x = a.at(i).to_int()
    let y = b.at(i).to_int()
    if x < y {
      return -1
    }
    if x > y {
      return 1
    }
    i = i + 1
  }
  if an < bn {
    -1
  } else if an > bn {
    1
  } else {
    0
  }
}

///|
/// The latest live record for every key that begins with `prefix`, sorted
/// ascending by key bytes. Tombstoned keys are excluded; superseded puts lose
/// to the newest one.
pub fn[W, R : @io.LogReader] Log::scan_prefix(
  self : Log[W, R],
  prefix : Bytes,
) -> Array[@core.Record] raise @io.IoError {
  let index = self.build_key_index()
  let p = @utf8.decode_lossy(prefix)
  let out : Array[@core.Record] = []
  self.for_each((0 : UInt64), self.next_offset, rec => {
    if !rec.is_delete() && @utf8.decode_lossy(rec.key).has_prefix(p) {
      match index.latest(rec.key) {
        Some(off) => if off == rec.offset { out.push(rec) }
        None => ()
      }
    }
  })
  out.sort_by(fn(a, b) { bytes_cmp(a.key, b.key) })
  out
}
