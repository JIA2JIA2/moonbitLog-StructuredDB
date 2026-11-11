///|
/// Per-tenant quota rule (6.2), parsed from one line of the directory's QUOTA
/// policy file:
/// `role=<name> [write-bytes=<n>] [storage-bytes=<n>] [query-concurrent=<n>] [retain-days=<n>]`.
/// `write-bytes` caps the bytes a tenant may append per rolling write window
/// (usage persists across restarts), `storage-bytes` caps the segment bytes
/// the tenant may occupy on disk, `query-concurrent` caps the tenant's
/// concurrent query slots beneath the global pool (4.6), and `retain-days`
/// overrides retention for the tenant's key prefix via the TTL `prefix`
/// rule (3.4). Negative limits mean "unlimited"; `query-concurrent <= 0`
/// means "no tenant-level cap beyond the global pool". The reserved role
/// name `default` is the fallback for callers that cannot be attributed to
/// a role (anonymous HTTP push, invocations without a matching token).
pub(all) struct QuotaRule {
  role : Bytes
  write_bytes : Int64
  storage_bytes : Int64
  query_concurrent : Int32
  retain_days : Int64
}

///|
/// Length of the fixed write-quota window in milliseconds (one hour). The
/// per-role usage counter resets whenever the window ages out and persists
/// in `<dir>/QUOTA_STATE/<role>.write`, so a restart cannot refill a spent
/// budget.
pub const QUOTA_WRITE_WINDOW_MS : Int64 = 3_600_000

///|
/// Parse a decimal ASCII integer with an optional leading `-`; None on empty
/// input or any non-digit character. Hand-rolled like the HTTP header
/// numbers (http.mbt) so malformed values are rejected instead of silently
/// defaulting.
fn quota_parse_int64(data : Bytes) -> Int64? {
  let n = data.length()
  if n == 0 {
    return None
  }
  let mut neg = false
  let mut i = 0
  if data.at(0).to_int() == 45 {
    neg = true
    i = 1
    if n == 1 {
      return None
    }
  }
  let mut v : Int64 = 0
  while i < n {
    let c = data.at(i).to_int()
    if c < 48 || c > 57 {
      return None
    }
    v = v * 10 + (c - 48).to_int64()
    i = i + 1
  }
  Some(if neg { -v } else { v })
}

///|
/// Parse one QUOTA rule line. Returns None when the line has no role name or
/// any present numeric field is malformed — a typo never silently disables a
/// limit. Omitted fields keep their "unlimited" defaults.
pub fn parse_quota_line(line : Bytes) -> QuotaRule? {
  let pairs = parse_kv_pairs(line)
  let mut role : Bytes? = None
  let mut write_bytes : Int64 = -1
  let mut storage_bytes : Int64 = -1
  let mut query_concurrent : Int32 = 0
  let mut retain_days : Int64 = -1
  let mut ok = true
  for pair in pairs {
    if pair.0 == b"role" {
      role = Some(pair.1)
    } else if pair.0 == b"write-bytes" {
      match quota_parse_int64(pair.1) {
        Some(v) => write_bytes = v
        None => ok = false
      }
    } else if pair.0 == b"storage-bytes" {
      match quota_parse_int64(pair.1) {
        Some(v) => storage_bytes = v
        None => ok = false
      }
    } else if pair.0 == b"query-concurrent" {
      match quota_parse_int64(pair.1) {
        Some(v) =>
          if v >= 0 && v <= 2147483647 {
            query_concurrent = v.to_int()
          } else {
            ok = false
          }
        None => ok = false
      }
    } else if pair.0 == b"retain-days" {
      match quota_parse_int64(pair.1) {
        Some(v) => retain_days = v
        None => ok = false
      }
    }
  }
  if ok {
    match role {
      Some(name) =>
        if name.length() > 0 {
          Some({
            role: name,
            write_bytes,
            storage_bytes,
            query_concurrent,
            retain_days,
          })
        } else {
          None
        }
      None => None
    }
  } else {
    None
  }
}

///|
/// Effective quota for `role`: the exact role's rule when present, otherwise
/// no quota at all — an identified role that has no QUOTA line is unlimited,
/// so an operator's `admin` role is never throttled by the anonymous `default`
/// line. The reserved `default` rule backs only callers with no resolved role
/// (open mode without RBAC, or a token that matches no role). This keeps the
/// tenant=key semantics of the QUOTA file: a role is metered only when a line
/// names it.
pub fn quota_for_role(rules : Array[QuotaRule], role : Bytes) -> QuotaRule? {
  if role.length() > 0 {
    for r in rules {
      if r.role == role {
        return Some(r)
      }
    }
    return None
  }
  for r in rules {
    if r.role == b"default" {
      return Some(r)
    }
  }
  None
}

///|
/// Persisted per-role write-window usage, stored as a single
/// `window_start=<ms> bytes=<n>` line in `<dir>/QUOTA_STATE/<role>.write`.
pub(all) struct QuotaUsage {
  window_start : Int64
  used : Int64
}

///|
/// Decode a persisted usage file; None when either field is missing or
/// malformed (treated as "no usage yet").
pub fn parse_quota_usage(data : Bytes) -> QuotaUsage? {
  let pairs = parse_kv_pairs(data)
  let mut window_start : Int64? = None
  let mut used : Int64? = None
  for pair in pairs {
    if pair.0 == b"window_start" {
      window_start = quota_parse_int64(pair.1)
    } else if pair.0 == b"bytes" {
      used = quota_parse_int64(pair.1)
    }
  }
  match (window_start, used) {
    (Some(a), Some(b2)) => Some({ window_start: a, used: b2, })
    _ => None
  }
}

///|
/// Encode a usage record for `<dir>/QUOTA_STATE/<role>.write` (a single
/// `k=v` line without a trailing newline — parse_quota_usage consumes whole
/// file contents).
pub fn encode_quota_usage(u : QuotaUsage) -> Bytes {
  @utf8.encode(
    "window_start=" +
    u.window_start.to_string() +
    " bytes=" +
    u.used.to_string(),
  )
}

///|
/// The usage state as of `now`: a window that has aged out
/// (`window_start + QUOTA_WRITE_WINDOW_MS <= now`) resets to a fresh empty
/// budget starting at `now`; otherwise the usage passes through unchanged.
pub fn quota_window_current(u : QuotaUsage, now : Int64) -> QuotaUsage {
  if u.window_start + QUOTA_WRITE_WINDOW_MS <= now {
    { window_start: now, used: 0, }
  } else {
    u
  }
}

///|
/// Whether appending `incoming` bytes stays within the write-window `limit`.
/// A negative limit means unlimited (always allowed).
pub fn quota_write_allows(
  u : QuotaUsage,
  limit : Int64,
  incoming : Int64,
) -> Bool {
  if limit < 0 {
    true
  } else {
    u.used + incoming <= limit
  }
}

///|
/// Turn per-tenant `retain-days` overrides into TTL `prefix` rules (3.4).
/// A rule produces a `("prefix", scope, days)` triple only when it has a
/// non-negative `retain_days` and its role has a non-empty data scope (the
/// RBAC scope prefix is the tenant's key namespace); expiry takes the
/// strictest matching rule, so a quota override can only tighten — never
/// extend — file-based retention.
pub fn quota_retain_prefix_rules(
  rules : Array[QuotaRule],
  role_scopes : Array[(Bytes, Bytes)],
) -> Array[(Bytes, Bytes, Int64)] {
  let out : Array[(Bytes, Bytes, Int64)] = []
  for r in rules {
    if r.retain_days >= 0 {
      for pair in role_scopes {
        let (name, scope) = pair
        if name == r.role && scope.length() > 0 {
          out.push((b"prefix", scope, r.retain_days))
        }
      }
    }
  }
  out
}
