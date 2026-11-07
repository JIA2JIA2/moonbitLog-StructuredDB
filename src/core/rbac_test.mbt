///|
test "parse_rbac_line extracts role token and allow list" {
  let parsed = @core.parse_rbac_line(b"role=admin token=s3cret allow=*")
  match parsed {
    Some(role) => {
      assert_eq(role.name, b"admin")
      assert_eq(role.token, b"s3cret")
      assert_eq(role.allow.length(), 1)
      assert_eq(role.allow[0], b"*")
    }
    None => panic()
  }
}

///|
test "parse_rbac_line rejects incomplete rules" {
  match @core.parse_rbac_line(b"role=reader allow=get") {
    Some(_) => panic()
    None => ()
  }
  match @core.parse_rbac_line(b"token=t allow=get") {
    Some(_) => panic()
    None => ()
  }
  match @core.parse_rbac_line(b"role=r token=t allow=") {
    Some(_) => panic()
    None => ()
  }
}

///|
test "rbac_allows honors exact commands and wildcard" {
  match @core.parse_rbac_line(b"role=r1 token=t1 allow=get,scan,stats") {
    Some(role) => {
      assert_true(@core.rbac_allows(role, b"get"))
      assert_true(@core.rbac_allows(role, b"scan"))
      assert_true(!@core.rbac_allows(role, b"put"))
    }
    None => panic()
  }
  match @core.parse_rbac_line(b"role=admin token=t allow=*") {
    Some(role) => assert_true(@core.rbac_allows(role, b"put"))
    None => panic()
  }
}

///|
test "rbac_find matches tokens and never matches an empty token" {
  let rules : Array[@core.RbacRole] = []
  match @core.parse_rbac_line(b"role=admin token=abc allow=*") {
    Some(r) => rules.push(r)
    None => panic()
  }
  match @core.rbac_find(rules, b"abc") {
    Some(r) => assert_eq(r.name, b"admin")
    None => panic()
  }
  match @core.rbac_find(rules, b"") {
    Some(_) => panic()
    None => ()
  }
  match @core.rbac_find(rules, b"wrong") {
    Some(_) => panic()
    None => ()
  }
}

///|
test "rbac scope restricts data access by key prefix (6.1)" {
  let role = @core.parse_rbac_line(
    b"role=tenant-a token=ta allow=* scope=app1/",
  )
  match role {
    Some(r) => {
      // In-scope keys (exact prefix boundary).
      assert_true(@core.rbac_scope_allows(r, b"app1/x"))
      assert_true(@core.rbac_scope_allows(r, b"app1/"))
      // Out-of-scope keys, including prefix-adjacent ones.
      assert_true(!@core.rbac_scope_allows(r, b"app2/x"))
      assert_true(!@core.rbac_scope_allows(r, b"app1x"))
      assert_true(!@core.rbac_scope_allows(r, b""))
    }
    None => panic()
  }
  // A missing scope (M109 legacy lines) means unrestricted access.
  let legacy = @core.parse_rbac_line(b"role=admin token=tok allow=*")
  match legacy {
    Some(r) => {
      assert_true(r.scope is None)
      assert_true(@core.rbac_scope_allows(r, b"anything"))
    }
    None => panic()
  }
  // `scope=*` also means unrestricted.
  let wild = @core.parse_rbac_line(b"role=admin token=tok allow=* scope=*")
  match wild {
    Some(r) => assert_true(@core.rbac_scope_allows(r, b"any/key"))
    None => panic()
  }
}
