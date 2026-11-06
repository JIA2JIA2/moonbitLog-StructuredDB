///|
/// One RBAC role rule, parsed from a line of the form
/// `role=<name> token=<token> allow=<cmd1,cmd2,...|*>` (space-separated
/// key=value pairs, the same shape as `parse_kv_pairs`).
pub(all) struct RbacRole {
  name : Bytes
  token : Bytes
  allow : Array[Bytes]
}

///|
/// Parse one RBAC rule line; returns None when the line lacks a role name, a
/// token, or an allow list.
pub fn parse_rbac_line(line : Bytes) -> RbacRole? {
  let pairs = parse_kv_pairs(line)
  let mut name : Bytes? = None
  let mut token : Bytes? = None
  let mut allow : Array[Bytes] = []
  for pair in pairs {
    if pair.0 == b"role" {
      name = Some(pair.1)
    } else if pair.0 == b"token" {
      token = Some(pair.1)
    } else if pair.0 == b"allow" {
      allow = split_commas(pair.1)
    }
  }
  match (name, token) {
    (Some(n), Some(t)) =>
      if allow.length() == 0 {
        None
      } else {
        Some({ name: n, token: t, allow, })
      }
    _ => None
  }
}

///|
fn split_commas(data : Bytes) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let mut start = 0
  let mut i = 0
  while i <= data.length() {
    if i == data.length() || data.at(i).to_int() == 44 {
      if i > start {
        out.push(slice(data, start, i))
      }
      start = i + 1
    }
    i = i + 1
  }
  out
}

///|
/// Whether the role permits `command`: an exact match in its allow list, or
/// the `*` wildcard.
pub fn rbac_allows(role : RbacRole, command : Bytes) -> Bool {
  for allowed in role.allow {
    if allowed == b"*" || allowed == command {
      return true
    }
  }
  false
}

///|
/// Find the role whose token equals `token`. An empty token never matches, so
/// a missing credential cannot claim a role.
pub fn rbac_find(rules : Array[RbacRole], token : Bytes) -> RbacRole? {
  if token.length() == 0 {
    return None
  }
  for rule in rules {
    if rule.token == token {
      return Some(rule)
    }
  }
  None
}
