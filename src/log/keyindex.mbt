///|
/// A point-in-time key -> latest-offset index built from a log scan. Keys are
/// raw bytes (binary-safe); tombstones remove keys, so only live puts remain.
pub(all) struct KeyIndex {
  entries : @hashmap.HashMap[Bytes, UInt64]
  mut sorted_keys : Array[Bytes]
}

///|
pub fn KeyIndex::new() -> KeyIndex {
  { entries: @hashmap.HashMap::HashMap([]), sorted_keys: [], }
}

///|
/// The live keys in ascending byte order. Populated by `build_key_index`.
pub fn KeyIndex::sorted_keys(self : KeyIndex) -> Array[Bytes] {
  self.sorted_keys
}

///|
/// Offset of the latest live record for `key`, if any.
pub fn KeyIndex::latest(self : KeyIndex, key : Bytes) -> UInt64? {
  self.entries.get(key)
}

///|
/// Number of live keys.
pub fn KeyIndex::size(self : KeyIndex) -> Int32 {
  self.entries.length()
}

///|
fn KeyIndex::put(self : KeyIndex, key : Bytes, offset : UInt64) -> Unit {
  self.entries.set(key, offset)
}

///|
fn KeyIndex::drop(self : KeyIndex, key : Bytes) -> Unit {
  self.entries.remove(key)
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
  let keys : Array[Bytes] = []
  for k in index.entries.keys() {
    keys.push(k)
  }
  keys.sort_by(fn(a, b) { bytes_cmp(a, b) })
  index.sorted_keys = keys
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
/// Whether `a` begins with the byte prefix `b` (binary-safe; an empty `b`
/// matches everything).
fn bytes_starts_with(a : Bytes, b : Bytes) -> Bool {
  let bn = b.length()
  if bn > a.length() {
    return false
  }
  let mut i = 0
  while i < bn {
    if a.at(i).to_int() != b.at(i).to_int() {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// The first index `i` in the ascending `keys` where `keys[i] >= target`.
fn lower_bound(keys : Array[Bytes], target : Bytes) -> Int32 {
  let mut lo = 0
  let mut hi = keys.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if bytes_cmp(keys[mid], target) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo
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
  let keys = index.sorted_keys()
  let out : Array[@core.Record] = []
  let mut i = lower_bound(keys, prefix)
  while i < keys.length() {
    let k = keys[i]
    if !bytes_starts_with(k, prefix) {
      break
    }
    match index.latest(k) {
      Some(off) =>
        match self.get(off) {
          Some(rec) => out.push(rec)
          None => ()
        }
      None => ()
    }
    i = i + 1
  }
  out
}

///|
/// The latest live record for every key in the half-open key range `[lo, hi)`,
/// sorted ascending by key bytes. An empty `hi` leaves the range unbounded
/// above; an empty `lo` starts from the smallest key. Tombstoned keys are
/// excluded; superseded puts lose to the newest one.
pub fn[W, R : @io.LogReader] Log::scan_key_range(
  self : Log[W, R],
  lo : Bytes,
  hi : Bytes,
) -> Array[@core.Record] raise @io.IoError {
  let index = self.build_key_index()
  let keys = index.sorted_keys()
  let has_hi = hi.length() > 0
  let out : Array[@core.Record] = []
  let mut i = lower_bound(keys, lo)
  while i < keys.length() {
    let k = keys[i]
    if has_hi && bytes_cmp(k, hi) >= 0 {
      break
    }
    match index.latest(k) {
      Some(off) =>
        match self.get(off) {
          Some(rec) => out.push(rec)
          None => ()
        }
      None => ()
    }
    i = i + 1
  }
  out
}

///|
/// The last record for `key` within a single segment (latest offset wins),
/// whether a put or a tombstone.
fn[W, R : @io.LogReader] latest_key_in_segment(
  seg : @segment.Segment[W, R],
  key : Bytes,
) -> @core.Record? raise @io.IoError {
  let recs = seg.scan()
  let mut found : @core.Record? = None
  for rec in recs {
    if rec.key == key {
      match found {
        Some(prev) => if rec.offset > prev.offset { found = Some(rec) }
        None => found = Some(rec)
      }
    }
  }
  found
}

///|
/// Latest live record for `key`, using each segment's Bloom filter to skip
/// segments that cannot contain it. Scans newest segment first; a tombstone in
/// the admitting segment means the key is gone. Correct regardless of filter
/// false positives (which merely cause an extra scan).
pub fn[W, R : @io.LogReader] Log::get_latest_bloom(
  self : Log[W, R],
  key : Bytes,
) -> @core.Record? raise @io.IoError {
  let mut i = self.segments.length() - 1
  while i >= 0 {
    let seg = self.segments[i]
    if seg.may_contain(key) {
      match latest_key_in_segment(seg, key) {
        Some(rec) =>
          if rec.is_delete() {
            return (None : @core.Record?)
          } else {
            return Some(rec)
          }
        None => ()
      }
    }
    i = i - 1
  }
  (None : @core.Record?)
}
