///|
/// Inverted index over one segment (3.2): a term→record-index posting list
/// (word-level full-text over ASCII tokens, lowercased) plus a field-column
/// posting list keyed by the exact `name=value` pair (and `__key__=<key>`
/// for the record key) for high-frequency filter fields. Built lazily from
/// the segment data and persisted as the `<base>.log.inv` sidecar; the linear
/// scans remain the fallback whenever the index is absent.
pub(all) struct InvIndex {
  terms : @hashmap.HashMap[Bytes, Array[Int32]]
  fields : @hashmap.HashMap[Bytes, Array[Int32]]
}

///|
const INV_MAGIC : UInt32 = 0x4D4C4956

///|
const INV_VERSION : UInt32 = 2

///|
const INV_HEADER : Int32 = 12

///|
/// Upper bound on one posting list (per segment) so a pathological value
/// cannot blow up memory or the sidecar.
const INV_MAX_POSTINGS : Int32 = 1_000_000

///|
/// Split bytes into word tokens: maximal runs of ASCII letters/digits with
/// A-Z folded to a-z; tokens of 1..32 bytes are kept. This is a word-level
/// (not substring) index — CJK and other non-ASCII text yields no tokens and
/// should use the linear `search` instead. At most `max_terms` tokens are
/// produced.
pub fn tokenize(b : Bytes, max_terms : Int32) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let mut cur = @buffer.Buffer::Buffer()
  let n = b.length()
  let mut i = 0
  while i < n {
    let c = b.at(i).to_int()
    let is_word = (c >= 48 && c <= 57) ||
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122)
    if is_word {
      if c >= 65 && c <= 90 {
        cur.write_byte((c + 32).to_byte())
      } else {
        cur.write_byte(b.at(i))
      }
    } else {
      let tok = cur.to_bytes()
      cur = @buffer.Buffer::Buffer()
      if tok.length() >= 1 && tok.length() <= 32 && out.length() < max_terms {
        out.push(tok)
      }
    }
    i = i + 1
  }
  let tail = cur.to_bytes()
  if tail.length() >= 1 && tail.length() <= 32 && out.length() < max_terms {
    out.push(tail)
  }
  out
}

///|
fn inv_add(
  map : @hashmap.HashMap[Bytes, Array[Int32]],
  key : Bytes,
  idx : Int32,
) -> Unit {
  match map.get(key) {
    Some(arr) => if arr.length() < INV_MAX_POSTINGS { arr.push(idx) }
    None => map.set(key, [idx])
  }
}

///|
/// Build (or rebuild) the inverted + field-column index by streaming every
/// record once: the key and the value are tokenized into terms; the exact
/// `name=value` pairs of the value plus `__key__=<key>` go into the field
/// columns. Postings stay in record-index order (ascending offsets).
pub fn[W, R : @io.LogReader] Segment::build_inv_index(
  self : Segment[W, R],
) -> Unit raise @io.IoError {
  let terms : @hashmap.HashMap[Bytes, Array[Int32]] = @hashmap.HashMap::HashMap([],
  )
  let fields : @hashmap.HashMap[Bytes, Array[Int32]] = @hashmap.HashMap::HashMap([],
  )
  let mut counter : Int32 = 0
  self.for_each(self.base_offset, self.next_offset, rec => {
    let idx = counter
    counter = counter + 1
    for tok in tokenize(rec.key, 16) {
      inv_add(terms, tok, idx)
    }
    for tok in tokenize(rec.value, 64) {
      inv_add(terms, tok, idx)
    }
    for pair in @core.parse_kv_pairs(rec.value) {
      let fb = @buffer.Buffer::Buffer()
      fb.write_bytes(pair.0)
      fb.write_bytes(b"=")
      fb.write_bytes(pair.1)
      inv_add(fields, fb.to_bytes(), idx)
    }
    let kb = @buffer.Buffer::Buffer()
    kb.write_bytes(b"__key__=")
    kb.write_bytes(rec.key)
    inv_add(fields, kb.to_bytes(), idx)
  })
  self.inv_index = Some({ terms, fields, })
}

///|
/// Lazily build the index when absent.
pub fn[W, R : @io.LogReader] Segment::ensure_inv_index(
  self : Segment[W, R],
) -> Unit raise @io.IoError {
  match self.inv_index {
    Some(_) => ()
    None => self.build_inv_index()
  }
}

///|
/// Posting list of a term (record indices within the segment); empty when
/// the index is not built or the term is absent.
pub fn[W, R] Segment::inv_term_postings(
  self : Segment[W, R],
  term : Bytes,
) -> Array[Int32] {
  match self.inv_index {
    Some(ix) =>
      match ix.terms.get(term) {
        Some(arr) => arr
        None => []
      }
    None => []
  }
}

///|
/// Posting list of an exact `name=value` (or `__key__=<key>`) column; empty
/// when the index is not built or the pair is absent.
pub fn[W, R] Segment::inv_field_postings(
  self : Segment[W, R],
  name : Bytes,
  value : Bytes,
) -> Array[Int32] {
  match self.inv_index {
    Some(ix) => {
      let fb = @buffer.Buffer::Buffer()
      fb.write_bytes(name)
      fb.write_bytes(b"=")
      fb.write_bytes(value)
      match ix.fields.get(fb.to_bytes()) {
        Some(arr) => arr
        None => []
      }
    }
    None => []
  }
}

///|
/// Write a LEB128 varint (3.3 columnar compression): postings are stored as
/// deltas of the strictly increasing record indices, so most deltas fit in
/// one byte instead of a fixed 4-byte word.
fn inv_write_varint(buf : @buffer.Buffer, v : Int32) -> Unit {
  let mut x = v.reinterpret_as_uint()
  while x >= (0x80 : UInt32) {
    buf.write_byte(
      ((x & (0x7F : UInt32)) | (0x80 : UInt32)).reinterpret_as_int().to_byte(),
    )
    x = x >> 7
  }
  buf.write_byte(x.reinterpret_as_int().to_byte())
}

///|
/// Read a LEB128 varint written by `inv_write_varint`; `Truncated` when the
/// bytes run past `end` or the value exceeds 5 bytes.
fn inv_read_varint(
  data : Bytes,
  pos : Int32,
  end : Int32,
) -> (Int32, Int32) raise @core.MetaError {
  let mut x : UInt32 = 0
  let mut shift : Int32 = 0
  let mut p = pos
  let mut go = true
  while go {
    if p >= end {
      raise @core.MetaError::Truncated(p)
    }
    let b = data.at(p).to_int()
    x = x | ((b & 0x7F).reinterpret_as_uint() << shift)
    p = p + 1
    if b < 0x80 {
      go = false
    } else {
      shift = shift + 7
      if shift > 28 {
        raise @core.MetaError::Truncated(p)
      }
    }
  }
  (x.reinterpret_as_int(), p)
}

///|
fn inv_encode_table(
  body : @buffer.Buffer,
  map : @hashmap.HashMap[Bytes, Array[Int32]],
) -> Unit {
  body.write_uint_le(map.length().reinterpret_as_uint())
  map.each(fn(k, arr) {
    body.write_uint_le(k.length().reinterpret_as_uint())
    body.write_bytes(k)
    body.write_uint_le(arr.length().reinterpret_as_uint())
    // Columnar compression (3.3): postings are strictly increasing record
    // indices — store the deltas as varints (1-2 bytes vs a fixed 4-byte
    // word), shrinking the sidecar and the IO it costs on load.
    let mut prev : Int32 = 0
    for idx in arr {
      inv_write_varint(body, idx - prev)
      prev = idx
    }
  })
}

///|
/// Serialize for the `<base>.log.inv` sidecar: magic, version, the term
/// table, the field table, then a CRC32 over everything before it.
pub fn InvIndex::encode(self : InvIndex) -> Bytes {
  let body = @buffer.Buffer::Buffer()
  body.write_uint_le(INV_MAGIC)
  body.write_uint_le(INV_VERSION)
  inv_encode_table(body, self.terms)
  inv_encode_table(body, self.fields)
  let bytes = body.to_bytes()
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(bytes)
  out.write_uint_le(@core.crc32(bytes))
  out.to_bytes()
}

///|
fn inv_decode_table(
  data : Bytes,
  pos : Int32,
  body_end : Int32,
) -> (Int32, @hashmap.HashMap[Bytes, Array[Int32]]) raise @core.MetaError {
  let map : @hashmap.HashMap[Bytes, Array[Int32]] = @hashmap.HashMap::HashMap([])
  let count = meta_u32(data, pos).reinterpret_as_int()
  let mut p = pos + 4
  let mut i = 0
  while i < count {
    if p + 8 > body_end {
      raise @core.MetaError::Truncated(p)
    }
    // Entry layout (matching inv_encode_table): klen, key bytes, posting
    // count, then the postings as varint deltas of the strictly increasing
    // record indices (3.3 columnar compression, sidecar format version 2).
    let klen = meta_u32(data, p).reinterpret_as_int()
    if klen < 0 {
      raise @core.MetaError::Truncated(p)
    }
    let pcount_at = p + 4 + klen
    if pcount_at + 4 > body_end {
      raise @core.MetaError::Truncated(p)
    }
    let n = meta_u32(data, pcount_at).reinterpret_as_int()
    if n < 0 || n > INV_MAX_POSTINGS {
      raise @core.MetaError::Truncated(p)
    }
    let kstart = p + 4
    if kstart + klen > body_end {
      raise @core.MetaError::Truncated(p)
    }
    let key = @core.slice(data, kstart, kstart + klen)
    let arr : Array[Int32] = []
    let mut cur : Int32 = 0
    let mut dp = pcount_at + 4
    let mut j = 0
    while j < n {
      let (d, np) = inv_read_varint(data, dp, body_end)
      cur = cur + d
      arr.push(cur)
      dp = np
      j = j + 1
    }
    map.set(key, arr)
    p = dp
    i = i + 1
  }
  (p, map)
}

///|
/// Parse a sidecar produced by `encode`, validating magic, version and CRC.
pub fn decode_inv_index(data : Bytes) -> InvIndex raise @core.MetaError {
  let total = data.length()
  if total < INV_HEADER + 4 {
    raise @core.MetaError::Truncated(total)
  }
  if meta_u32(data, 0) != INV_MAGIC {
    raise @core.MetaError::BadMagic
  }
  let version = meta_u32(data, 4)
  // Exact version: v1 had uncompressed postings, silently reading it as v2
  // would yield garbage — reject and let the caller rebuild instead.
  if version != INV_VERSION {
    raise @core.MetaError::BadVersion(version)
  }
  let body_end = total - 4
  let expected = meta_u32(data, body_end)
  let actual = @core.crc32_range(data, 0, body_end)
  if expected != actual {
    raise @core.MetaError::BadCrc(expected, actual)
  }
  let (p1, terms) = inv_decode_table(data, 8, body_end)
  let (p2, fields) = inv_decode_table(data, p1, body_end)
  if p2 != body_end {
    raise @core.MetaError::Truncated(p2)
  }
  { terms, fields, }
}
