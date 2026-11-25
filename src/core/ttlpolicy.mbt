///|
/// Differentiated retention policy (3.4): a global default in days plus
/// per-service (`service <name> <days>`), per-level (`level <level> <days>`)
/// and per-key-prefix (`prefix <p> <days>`, the tenant dimension of 6.2)
/// overrides. `default_days < 0` means "no default expiry" — records
/// matching no rule are kept forever.
pub(all) struct TtlPolicy {
  default_days : Int64
  rules : Array[(Bytes, Bytes, Int64)]
}

///|
/// Split a line on ASCII spaces/tabs, dropping empty tokens.
fn ttl_tokens(line : Bytes) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let n = line.length()
  let mut i = 0
  while i < n {
    let c = line.at(i).to_int()
    if c == 32 || c == 9 {
      i = i + 1
    } else {
      let start = i
      while i < n {
        let c2 = line.at(i).to_int()
        if c2 == 32 || c2 == 9 {
          break
        }
        i = i + 1
      }
      out.push(slice(line, start, i))
    }
  }
  out
}

///|
/// Parse a `<dir>/TTL` policy file: lines are `default <days>`,
/// `service <name> <days>`, `level <level> <days>` or `prefix <p> <days>`
/// (whitespace separated; `#` comments and blank lines are ignored). Returns
/// None on any malformed line, so a typo never silently changes retention.
pub fn parse_ttl_policy(text : Bytes) -> TtlPolicy? {
  let mut default_days : Int64 = -1
  let rules : Array[(Bytes, Bytes, Int64)] = []
  let n = text.length()
  let mut i = 0
  let mut ok = true
  while i < n && ok {
    let mut e = i
    while e < n && text.at(e).to_int() != 10 {
      e = e + 1
    }
    let mut le = e
    if le > i && text.at(le - 1).to_int() == 13 {
      le = le - 1
    }
    let line = slice(text, i, le)
    i = e + 1
    let toks = ttl_tokens(line)
    if toks.length() > 0 && toks[0].at(0).to_int() != 35 {
      let head = toks[0]
      if head == b"default" {
        if toks.length() != 2 {
          ok = false
        } else {
          let d = @string.parse_int64(@utf8.decode_lossy(toks[1])) catch {
            _ => -2
          }
          if d < 0 {
            ok = false
          } else {
            default_days = d
          }
        }
      } else if head == b"service" || head == b"level" || head == b"prefix" {
        if toks.length() != 3 {
          ok = false
        } else {
          let d = @string.parse_int64(@utf8.decode_lossy(toks[2])) catch {
            _ => -2
          }
          if d < 0 {
            ok = false
          } else {
            rules.push((head, toks[1], d))
          }
        }
      } else {
        ok = false
      }
    }
  }
  if ok {
    Some({ default_days, rules, })
  } else {
    None
  }
}

///|
/// Whether `data` starts with `prefix` byte for byte.
fn bytes_has_prefix(data : Bytes, prefix : Bytes) -> Bool {
  if data.length() < prefix.length() {
    return false
  }
  let mut i = 0
  while i < prefix.length() {
    if data.at(i) != prefix.at(i) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// ASCII case-insensitive byte equality for TTL scope matching: service and
/// level identifiers are case-insensitive so `Service=Orders` / `Level=ERROR`
/// still hit the configured rules; prefix scopes stay byte-exact.
fn ttl_bytes_eq_ci(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    let ca = a.at(i).to_int()
    let cb = b.at(i).to_int()
    let la = if ca >= 65 && ca <= 90 { ca + 32 } else { ca }
    let lb = if cb >= 65 && cb <= 90 { cb + 32 } else { cb }
    if la != lb {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Effective retention days for a record: the service scope matches the
/// record key, the level scope matches the parsed `level` field and the
/// prefix scope matches the key's leading bytes (tenant namespaces, 6.2);
/// when several match, the stricter (smaller) one wins; when none match, the
/// default applies. Days < 0 mean "no matching rule and no default" — the
/// record never expires.
pub fn ttl_days_of(
  policy : TtlPolicy,
  key : Bytes,
  level : Bytes?,
  service : Bytes?,
) -> Int64 {
  let mut days : Int64 = -1
  let mut hit_any = false
  for rule in policy.rules {
    let (scope, name, d) = rule
    let hit = if scope == b"service" {
      // A record matches the per-service rule through its service field OR
      // its key (the pre-4th-round shape, where the schema promotion put the
      // service name in the key). With an explicit --key-field (M229) the
      // key is the caller's own id and the service lives in the value —
      // matching the key alone made the per-project retention rule silently
      // fall back to default.
      ttl_bytes_eq_ci(key, name) ||
      (match service {
        Some(s) => ttl_bytes_eq_ci(s, name)
        None => false
      })
    } else if scope == b"level" {
      match level {
        Some(l) => ttl_bytes_eq_ci(l, name)
        None => false
      }
    } else if scope == b"prefix" {
      bytes_has_prefix(key, name)
    } else {
      false
    }
    if hit {
      hit_any = true
      if days < 0 || d < days {
        days = d
      }
    }
  }
  if hit_any {
    days
  } else {
    policy.default_days
  }
}

///|
/// The parsed `level` field of a record value, if present. Extraction goes
/// through the shared `value_fields` contract (3.2 fifth round) — JSON
/// bodies, container-wrapped records (`2026-... stdout F {...}`) and
/// trailing meta kv pairs all resolve exactly like the query filter and the
/// inverted field columns do; the pre-4th-round copy flattened only a
/// leading `{`, so wrapped records missed the per-level retention rule and
/// silently fell back to default. The level slot is identified through the
/// unified schema (2.2), so `severity_text` and friends resolve exactly like
/// `level=` does; value matching stays case-insensitive in `ttl_days_of`.
pub fn ttl_record_level(value : Bytes) -> Bytes? {
  ttl_field_of(value, 1)
}

///|
/// The parsed `service` field of a record value, if present — same contract
/// as `ttl_record_level` (3.4 fourth round): per-service retention rules must
/// hit records whose key is the caller's own id (`--key-field`) and whose
/// service lives in the value.
pub fn ttl_record_service(value : Bytes) -> Bytes? {
  ttl_field_of(value, 2)
}

///|
/// Level and service slots in one pass over the shared `value_fields`
/// contract (3.4 fourth round): `expire_by_policy` needs both for every
/// record, and two separate walks doubled the extraction cost of the
/// maintenance scan. Individual slots keep resolving through
/// `ttl_record_level` / `ttl_record_service`.
pub fn ttl_record_slots(value : Bytes) -> (Bytes?, Bytes?) {
  let mut level : Bytes? = None
  let mut service : Bytes? = None
  for pair in value_fields(value) {
    let slot = canonical_field(pair.0)
    if slot == 1 {
      level = Some(pair.1)
    } else if slot == 2 {
      service = Some(pair.1)
    }
  }
  (level, service)
}

///|
/// Slot-resolving field extraction shared by the TTL rules: `slot` 1 is the
/// level, 2 the service (the unified-schema map). Last match wins, matching
/// the query filter's `--field` behavior.
fn ttl_field_of(value : Bytes, slot : Int32) -> Bytes? {
  let mut found : Bytes? = None
  for pair in value_fields(value) {
    if canonical_field(pair.0) == slot {
      found = Some(pair.1)
    }
  }
  found
}
