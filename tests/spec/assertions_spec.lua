local Assertions = require("nuntio.assertions")
local Diagnostics = require("nuntio.lsp.diagnostics")
local Document = require("nuntio.parser.document")
local Processors = require("nuntio.processors")
local Request = require("nuntio.request")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")
local View = require("nuntio.ui.view")
local Winbar = require("nuntio.ui.winbar")

local function make_response(overrides)
  local body = '{"id":42,"name":"Amorim","active":true,"score":9.5,"deleted_at":null,"tags":["bass","guitar"],"items":[{"sku":"A1"}]}'
  local resp = {
    status = 201,
    status_text = "Created",
    headers = { ["Content-Type"] = "application/json; charset=utf-8", ["content-type"] = "application/json; charset=utf-8" },
    body = body,
    raw_body = body,
    json = vim.json.decode(body),
    time = 120,
  }
  for k, v in pairs(overrides or {}) do
    resp[k] = v
  end
  return resp
end

local function check(expr, resp)
  local a, err = Assertions.parse(expr)
  assert_true(a ~= nil, "parse failed for '" .. expr .. "': " .. tostring(err))
  return (Assertions.evaluate(a, resp or make_response()))
end

describe("Assertions: parsing", function()
  it("parses each subject form", function()
    local a = Assertions.parse("status == 201")
    assert_eq(a.subject, "status")
    assert_eq(a.op, "==")
    assert_eq(a.expected, 201)

    a = Assertions.parse("header Content-Type contains json")
    assert_eq(a.subject, "header")
    assert_eq(a.arg, "Content-Type")
    assert_eq(a.expected, "json")

    a = Assertions.parse("body $.name == \"Amorim Lima\"")
    assert_eq(a.arg, "$.name")
    assert_eq(a.expected, "Amorim Lima")

    a = Assertions.parse("body contains Amorim")
    assert_nil(a.arg, "body without path compares raw body")

    a = Assertions.parse("duration < 500")
    assert_eq(a.subject, "duration")
    assert_eq(a.expected, 500)
  end)

  it("types literals", function()
    assert_eq(Assertions.parse("body $.active == true").expected, true)
    assert_eq(Assertions.parse("body $.x == null").expected, Assertions.NULL)
    assert_eq(Assertions.parse("body $.x == '42'").expected, "42")
    assert_eq(Assertions.parse("body $.x == 4.5").expected, 4.5)
  end)

  it("rejects malformed assertions with a reason", function()
    local cases = {
      [""] = "empty",
      ["foo == 1"] = "unknown subject",
      ["status"] = "missing operator",
      ["status ~= 1"] = "unknown operator",
      ["status =="] = "missing expected value",
      ["header == x"] = "missing header name",
      ["body $.id exists 1"] = "takes no value",
      ["body matches [a-"] = "invalid Lua pattern",
    }
    for expr, fragment in pairs(cases) do
      local a, err = Assertions.parse(expr)
      assert_nil(a, "should reject '" .. expr .. "'")
      assert_true(err:find(fragment, 1, true) ~= nil, string.format("'%s' -> '%s' should mention '%s'", expr, err, fragment))
    end
  end)
end)

describe("Assertions: evaluation", function()
  it("compares status and duration numerically", function()
    assert_true(check("status == 201"))
    assert_true(check("status != 200"))
    assert_true(check("status >= 200"))
    assert_true(check("status < 300"))
    assert_true(not check("status > 201"))
    assert_true(check("duration <= 120"))
    assert_true(not check("duration < 100"))
  end)

  it("looks up headers case-insensitively", function()
    local resp = make_response({ headers = { ["X-Request-Id"] = "abc-123" } })
    assert_true(check("header x-request-id == abc-123", resp))
    assert_true(check("header X-REQUEST-ID matches ^abc%-%d+$", resp))
    assert_true(check("header X-Missing !exists", resp))
    assert_true(not check("header X-Missing == foo", resp))
  end)

  it("extracts body values via JSONPath", function()
    assert_true(check("body $.id == 42"))
    assert_true(check("body $.id == \"42\""), "string literal matches number text")
    assert_true(check("body $.name == \"Amorim\""))
    assert_true(check("body $.name != Bob"))
    assert_true(check("body $.active == true"))
    assert_true(check("body $.score > 9"))
    assert_true(check("body $.items[0].sku == A1"))
    assert_true(check("body $.deleted_at == null"))
    assert_true(check("body $.deleted_at exists"), "null field still exists")
    assert_true(check("body $.nope !exists"))
    assert_true(not check("body $.nope exists"))
  end)

  it("supports contains on strings, raw body and arrays", function()
    assert_true(check("body $.name contains mor"))
    assert_true(check("body contains \"Amorim\""))
    assert_true(check("body $.tags contains bass"))
    assert_true(check("body $.tags !contains drums"))
    assert_true(not check("body $.tags contains drums"))
  end)

  it("fails numeric comparisons on non-numeric values", function()
    local a = Assertions.parse("body $.name > 3")
    local ok, _, msg = Assertions.evaluate(a, make_response())
    assert_true(not ok)
    assert_eq(msg, "operands are not numeric")
  end)

  it("summarizes results including syntax errors", function()
    local summary = Assertions.run({
      "status == 201",
      "body $.name == \"Bob\"",
      "nonsense here",
    }, make_response())
    assert_eq(summary.total, 3)
    assert_eq(summary.passed, 1)
    assert_eq(summary.failed, 2)
    assert_eq(summary.results[2].expected, "\"Bob\"")
    assert_eq(summary.results[2].actual, "\"Amorim\"")
    assert_true(summary.results[3].message:find("syntax error") ~= nil)
  end)
end)

describe("Assertions: pipeline integration", function()
  it("interpolates variables and prepends ### Shared assertions", function()
    local text = [[
@expected = 201

### Shared
# @assert status < 500

### Create
# @assert status == {{expected}}
POST https://api.example.com/users
]]
    local blocks, doc_vars = Document.parse_document(Utils.split_lines(text))
    local shared, target
    for _, b in ipairs(blocks) do
      if b.is_shared then shared = b else target = b end
    end
    local resolved = Request.resolve(target, doc_vars, vim.uv.cwd(), nil, shared)
    assert_eq(#resolved.assertions, 2)
    assert_eq(resolved.assertions[1], "status < 500")
    assert_eq(resolved.assertions[2], "status == 201")
  end)

  it("runs assertions in processors before @jq rewrites the body", function()
    local resp = make_response()
    local request = {
      metadata = vim.fn.executable("jq") == 1 and { jq = { ".name" } } or {},
      assertions = { "body $.id == 42" },
    }
    Processors.process(request, resp)
    assert_eq(resp.assertions.passed, 1, "assertion saw the original JSON body")
  end)

  it("leaves responses without assertions untouched", function()
    local resp = make_response()
    Processors.process({ metadata = {}, assertions = {} }, resp)
    assert_nil(resp.assertions)
  end)
end)

describe("Assertions: UI and diagnostics", function()
  it("shows the Tests tab and badge only when assertions exist", function()
    local resp = make_response()
    resp.assertions = Assertions.run({ "status == 201", "status == 500" }, resp)

    local bar = Winbar.render("tests", resp)
    assert_true(bar:find("NuntioWinbarClick_tests", 1, true) ~= nil, "tests tab rendered")
    assert_true(bar:find("✘ 1/2", 1, true) ~= nil, "failure badge rendered")

    local plain = Winbar.render("body", make_response())
    assert_true(plain:find("NuntioWinbarClick_tests", 1, true) == nil, "no tests tab without assertions")

    assert_true(vim.tbl_contains(View.get_available_views(resp), "tests"))
    assert_true(not vim.tbl_contains(View.get_available_views(make_response()), "tests"))
  end)

  it("renders results with expected and actual values in the Tests view", function()
    local resp = make_response({ method = "POST", url = "https://api.example.com/users" })
    resp.assertions = Assertions.run({ "status == 201", "body $.name == \"Bob\"" }, resp)
    Store.history = { resp }
    View.history_idx = 1
    View.switch_view("tests")

    local lines = vim.api.nvim_buf_get_lines(View.bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert_true(text:find("✘ 1 failed, 1/2 passed", 1, true) ~= nil, "summary line")
    assert_true(text:find("✔ status == 201", 1, true) ~= nil, "passing assertion listed")
    assert_true(text:find("expected: \"Bob\"", 1, true) ~= nil, "expected value shown")
    assert_true(text:find("actual:   \"Amorim\"", 1, true) ~= nil, "actual value shown")
    View.close()
  end)

  it("flags malformed # @assert lines as diagnostics", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# @assert status == 200",
      "# @assert body $.id exists",
      "# @assert statsu == 200",
      "GET https://api.example.com/users",
    })
    Diagnostics.check(buf)
    local diags = vim.diagnostic.get(buf)
    assert_eq(#diags, 1, "only the malformed assertion is flagged")
    assert_eq(diags[1].lnum, 2)
    assert_true(diags[1].message:find("unknown subject", 1, true) ~= nil)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
