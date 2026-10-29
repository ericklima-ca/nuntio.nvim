local RequestVars = require("nuntio.parser.request_vars")
local Store = require("nuntio.store")
local Vars = require("nuntio.parser.vars")

describe("Variable Interpolation", function()
  it("interpolates dynamic variables", function()
    local text = "UUID: {{$uuid}}, Timestamp: {{$timestamp}}, Date: {{$date}}"
    local res = Vars.interpolate(text)
    assert_true(res:match("UUID: %x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x") ~= nil, "uuid match")
    assert_true(res:match("Timestamp: %d+") ~= nil, "timestamp match")
    assert_true(res:match("Date: %d%d%d%d%-%d%d%-%d%d") ~= nil, "date match")

    -- Test $randomInt with min max arguments
    local rand_text = "ID: {{$randomInt 1000 9999}}"
    local rand_res = Vars.interpolate(rand_text)
    local num = tonumber(rand_res:match("ID: (%d+)"))
    assert_true(num ~= nil, "randomInt evaluated to number")
    assert_true(num >= 1000 and num <= 9999, "randomInt within bounds")
  end)

  it("interpolates document and environment variables", function()
    local doc_vars = { host = "api.com", port = "8080" }
    local env_vars = { token = "abc-123", db = { user = "postgres" } }

    local text = "http://{{host}}:{{port}}?token={{token}}&db={{db.user}}"
    local res = Vars.interpolate(text, doc_vars, env_vars)
    assert_eq(res, "http://api.com:8080?token=abc-123&db=postgres")
  end)

  it("supports recursive variable expansion", function()
    local doc_vars = {
      base = "http://localhost",
      endpoint = "{{base}}/v1/users",
    }
    local text = "GET {{endpoint}}"
    local res = Vars.interpolate(text, doc_vars, {})
    assert_eq(res, "GET http://localhost/v1/users")
  end)

  it("resolves chained request variables from Store", function()
    Store.add_response({
      id = "1",
      name = "login",
      method = "POST",
      url = "https://auth.com/login",
      status = 200,
      headers = { authorization = "Bearer old", ["set-cookie"] = "session=xyz123" },
      raw_headers = "HTTP/1.1 200 OK\nSet-Cookie: session=xyz123\n\n",
      cookies = { session = { value = "xyz123" } },
      body = '{"access_token": "token_abc_456", "user": {"id": 42}}',
      raw_body = "",
      json = { access_token = "token_abc_456", user = { id = 42 } },
      time = 100,
      timestamp = os.time(),
    }, {
      url = "https://auth.com/login",
      method = "POST",
      headers = {},
      body = "",
    })

    local text = "Bearer {{login.response.body.$.access_token}} (User: {{login.response.body.$.user.id}} Cookie: {{login.response.cookies.session.value}})"
    local res = Vars.interpolate(text)
    assert_eq(res, "Bearer token_abc_456 (User: 42 Cookie: xyz123)")
  end)

  it("leaves unresolved variables untouched", function()
    local text = "Hello {{unknown_variable}}"
    local res = Vars.interpolate(text, {}, {})
    assert_eq(res, "Hello {{unknown_variable}}")
  end)

  it("extracts request dependencies and resolves execution order", function()
    local text = "Auth: {{auth_req.response.body.$.token}} Host: {{init_req.request.url}}"
    local deps = RequestVars.extract_dependencies(text)
    table.sort(deps)
    assert_eq(#deps, 2)
    assert_eq(deps[1], "auth_req")
    assert_eq(deps[2], "init_req")

    -- Test dependency resolution ordering: A -> B -> C
    local block_a = { name = "req_a", url = "http://api.com/a", headers = {}, body = "", start_line = 1 }
    local block_b = { name = "req_b", url = "http://api.com/b", headers = {}, body = "{{req_a.response.body.$.id}}", start_line = 10 }
    local block_c = { name = "req_c", url = "http://api.com/c/{{req_b.response.body.$.id}}", headers = {}, body = "", start_line = 20 }

    local all_blocks = { block_a, block_b, block_c }

    local prereqs, err = RequestVars.resolve_dependency_order(block_c, all_blocks)
    assert_true(err == nil, "no error")
    assert_eq(#prereqs, 2)
    assert_eq(prereqs[1].name, "req_a")
    assert_eq(prereqs[2].name, "req_b")

    -- Detect circular dependency: X -> Y -> X
    local block_x = { name = "req_x", url = "http://api.com/x", headers = {}, body = "{{req_y.response.body.$.token}}", start_line = 30 }
    local block_y = { name = "req_y", url = "http://api.com/y", headers = {}, body = "{{req_x.response.body.$.token}}", start_line = 40 }
    local circ_blocks = { block_x, block_y }

    local _, circ_err = RequestVars.resolve_dependency_order(block_x, circ_blocks)
    assert_true(circ_err ~= nil, "detected circular dependency")
    assert_true(circ_err:match("circular dependency") ~= nil)
  end)
end)
