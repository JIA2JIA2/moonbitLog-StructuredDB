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
const INV_VERSION : UInt32 = 5

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
      if c >= 128 {
        // Non-ASCII (CJK etc.): index each UTF-8 character as a unigram token
        // so Chinese queries hit the inverted index without a dictionary.
        let mut clen = 1
        if c >= 240 {
          clen = 4
        } else if c >= 224 {
          clen = 3
        } else if c >= 192 {
          clen = 2
        }
        let end = if i + clen <= n { i + clen } else { n }
        let mut ok = true
        let mut k = i + 1
        while k < end {
          let cc = b.at(k).to_int()
          if cc < 128 || cc > 191 {
            ok = false
            break
          }
          k = k + 1
        }
        if ok && end - i <= 32 && out.length() < max_terms {
          out.push(@core.slice(b, i, end))
        }
        i = end - 1
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
/// ASCII lowercase copy (field-column values are probed case-insensitively
/// by the pushdown, so alias-shaped records must be stored folded).
fn inv_lower_bytes(b : Bytes) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  let n = b.length()
  let mut i = 0
  while i < n {
    let c = b.at(i).to_int()
    if c >= 65 && c <= 90 {
      out.write_byte((c + 32).to_byte())
    } else {
      out.write_byte(b.at(i))
    }
    i = i + 1
  }
  out.to_bytes()
}

///|
/// Add one `name=value` field-column entry, normalizing through the unified
/// schema (2.2): the field name is squashed to its canonical slot name
/// (`severity_text` → `level`, `service.name` → `service`) and the value is
/// ASCII-lowercased for the five non-ts slots. Query-side pushdown probes
/// exactly those canonical names with lowercase values — without this,
/// alias-shaped KV records and SDK-style JSON records miss the columns and
/// `query --indexed` would skip whole segments containing matches (false
/// negatives). Non-canonical fields keep their literal name/value.
fn inv_add_field(
  fields : @hashmap.HashMap[Bytes, Array[Int32]],
  name : Bytes,
  value : Bytes,
  idx : Int32,
) -> Unit {
  let slot = @core.canonical_field(name)
  let (nb, vb) = if slot == 1 {
    (b"level", inv_lower_bytes(value))
  } else if slot == 2 {
    (b"service", inv_lower_bytes(value))
  } else if slot == 3 {
    (b"host", inv_lower_bytes(value))
  } else if slot == 4 {
    (b"trace_id", inv_lower_bytes(value))
  } else if slot == 5 {
    (b"message", inv_lower_bytes(value))
  } else {
    (name, value)
  }
  let fb = @buffer.Buffer::Buffer()
  fb.write_bytes(nb)
  fb.write_bytes(b"=")
  fb.write_bytes(vb)
  inv_add(fields, fb.to_bytes(), idx)
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
      inv_add_field(fields, pair.0, pair.1, idx)
    }
    if rec.value.length() > 0 && rec.value.at(0).to_int() == 123 {
      // JSON/OTel records (2.1): the exact `name=value` columns are built
      // from the flattened fields too — `parse_kv_pairs` sees no pairs in a
      // JSON object, so without this SDK-style values have empty columns and
      // `query --indexed` pushdown would skip the whole segment even when it
      // holds matches.
      let flat : Array[(Bytes, Bytes)]? = Some(
        @core.json_object_fields(rec.value),
      ) catch {
        _ => None
      }
      match flat {
        Some(pairs) =>
          for pair in pairs {
            inv_add_field(fields, pair.0, pair.1, idx)
          }
        None => ()
      }
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
/// Lexicographic byte compare for front-coded key ordering.
fn inv_bytes_compare(a : Bytes, b : Bytes) -> Int32 {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  let mut i = 0
  while i < n {
    let ca = a.at(i).to_int()
    let cb = b.at(i).to_int()
    if ca < cb {
      return -1
    }
    if ca > cb {
      return 1
    }
    i = i + 1
  }
  if a.length() < b.length() {
    -1
  } else if a.length() > b.length() {
    1
  } else {
    0
  }
}

///|
fn inv_shared_prefix(a : Bytes, b : Bytes) -> Int32 {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  let mut i = 0
  while i < n && a.at(i).to_int() == b.at(i).to_int() {
    i = i + 1
  }
  i
}

///|
fn inv_encode_table(
  body : @buffer.Buffer,
  map : @hashmap.HashMap[Bytes, Array[Int32]],
) -> Unit {
  // Front coding (3.3 v3): entries are written in lexicographic key order and
  // each key stores only its shared-prefix length plus the remaining suffix.
  // Field columns like `trace_id=t12345` share long prefixes across entries,
  // and terms like `evt-123` / `t123` share one as well, so this shrinks the
  // sidecar noticeably versus repeating every key in full.
  let entries : Array[(Bytes, Array[Int32])] = []
  map.each(fn(k, arr) { entries.push((k, arr)) })
  entries.mut_view().sort_by(fn(a, b) { inv_bytes_compare(a.0, b.0) })
  body.write_uint_le(entries.length().reinterpret_as_uint())
  let mut prev : Bytes = b""
  for entry in entries {
    let k = entry.0
    let shared = inv_shared_prefix(prev, k)
    inv_write_varint(body, shared)
    let suffix = @core.slice(k, shared, k.length())
    inv_write_varint(body, suffix.length())
    body.write_bytes(suffix)
    let arr = entry.1
    inv_write_varint(body, arr.length())
    let mut last : Int32 = 0
    for idx in arr {
      inv_write_varint(body, idx - last)
      last = idx
    }
    prev = k
  }
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
  if count < 0 {
    raise @core.MetaError::Truncated(pos)
  }
  let mut p = pos + 4
  let mut prev : Bytes = b""
  let mut i = 0
  while i < count {
    // Entry layout (matching inv_encode_table v3): shared prefix length,
    // suffix length, suffix bytes, posting count, postings as varint deltas.
    let (shared, p1) = inv_read_varint(data, p, body_end)
    if shared < 0 || shared > prev.length() {
      raise @core.MetaError::Truncated(p1)
    }
    let (slen, p2) = inv_read_varint(data, p1, body_end)
    if p2 > body_end || slen < 0 || slen > body_end - p2 {
      raise @core.MetaError::Truncated(p2)
    }
    let suffix = @core.slice(data, p2, p2 + slen)
    // Rebuild the front-coded key in one exactly-sized array (no Buffer
    // growth); the zero-copy Bytes view becomes the hashmap key.
    let key_bytes = FixedArray::make(shared + slen, b'\x00')
    if shared > 0 {
      key_bytes.blit_from_bytes(0, prev, 0, shared)
    }
    key_bytes.blit_from_bytes(shared, suffix, 0, slen)
    let key = key_bytes.unsafe_reinterpret_as_bytes()
    let p3 = p2 + slen
    let (n, p4) = inv_read_varint(data, p3, body_end)
    if n < 0 || n > INV_MAX_POSTINGS {
      raise @core.MetaError::Truncated(p4)
    }
    let arr : Array[Int32] = []
    let mut cur : Int32 = 0
    let mut dp = p4
    let mut j = 0
    while j < n {
      let (d, np) = inv_read_varint(data, dp, body_end)
      cur = cur + d
      arr.push(cur)
      dp = np
      j = j + 1
    }
    map.set(key, arr)
    prev = key
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
