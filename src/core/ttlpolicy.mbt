///|
/// Differentiated retention policy (3.4): a global default in days plus
/// per-service (`service <name> <days>`) and per-level (`level <level>
/// <days>`) overrides. `default_days < 0` means "no default expiry" —
/// records matching no rule are kept forever.
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
/// `service <name> <days>` or `level <level> <days>` (whitespace separated;
/// `#` comments and blank lines are ignored). Returns None on any malformed
/// line, so a typo never silently changes retention.
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
      } else if head == b"service" || head == b"level" {
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
/// Effective retention days for a record: the service scope matches the
/// record key and the level scope matches the parsed `level` field; when
/// both match, the stricter (smaller) one wins; when none match, the default
/// applies. Days < 0 mean "no matching rule and no default" — the record
/// never expires.
pub fn ttl_days_of(policy : TtlPolicy, key : Bytes, level : Bytes?) -> Int64 {
  let mut days : Int64 = -1
  let mut hit_any = false
  for rule in policy.rules {
    let (scope, name, d) = rule
    let hit = if scope == b"service" {
      key == name
    } else if scope == b"level" {
      match level {
        Some(l) => l == name
        None => false
      }
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
/// The parsed `level` field of a record value (kv pairs), if present.
pub fn ttl_record_level(value : Bytes) -> Bytes? {
  let mut found : Bytes? = None
  for pair in parse_kv_pairs(value) {
    if pair.0 == b"level" {
      found = Some(pair.1)
    }
  }
  found
}
