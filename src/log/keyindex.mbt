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
        Some(off) => {
          if off == rec.offset {
            live.push(rec)
          }
        }
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