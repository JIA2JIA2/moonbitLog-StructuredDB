///|
/// One entry of a sparse index: the byte `position` at which the record with
/// segment-local ordinal `record_index` (0-based) starts.
pub(all) struct IndexEntry {
  record_index : UInt64
  position : Int64
}

///|
/// A sparse index samples one entry every `interval` records rather than one
/// per record, trading a tiny amount of scan work (at most `interval` records)
/// for far less memory. Entries are appended in increasing `record_index`
/// order, so `floor` can binary-search them.
pub(all) struct SparseIndex {
  interval : Int32
  mut entries : Array[IndexEntry]
}

///|
pub fn SparseIndex::new(interval : Int32) -> SparseIndex {
  let iv = if interval < 1 { 1 } else { interval }
  { interval: iv, entries: [], }
}

///|
/// Whether the record at ordinal `record_index` should start a new index entry.
pub fn SparseIndex::should_index(
  self : SparseIndex,
  record_index : Int32,
) -> Bool {
  record_index % self.interval == 0
}

///|
pub fn SparseIndex::push(
  self : SparseIndex,
  record_index : UInt64,
  position : Int64,
) -> Unit {
  self.entries.push({ record_index, position, })
}

///|
pub fn SparseIndex::length(self : SparseIndex) -> Int32 {
  self.entries.length()
}

///|
pub fn SparseIndex::entry(self : SparseIndex, i : Int32) -> IndexEntry {
  self.entries[i]
}

///|
pub fn SparseIndex::reset(self : SparseIndex) -> Unit {
  self.entries = []
}

///|
/// The latest entry whose `record_index` is <= `record_index`, i.e. the
/// greatest lower bound to start scanning from. Returns `None` only when the
/// index is empty.
pub fn SparseIndex::floor(
  self : SparseIndex,
  record_index : UInt64,
) -> IndexEntry? {
  let n = self.entries.length()
  if n == 0 {
    return None
  }
  let mut lo = 0
  let mut hi = n
  while lo < hi {
    let mid = (lo + hi) / 2
    if self.entries[mid].record_index <= record_index {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo == 0 {
    None
  } else {
    Some(self.entries[lo - 1])
  }
}