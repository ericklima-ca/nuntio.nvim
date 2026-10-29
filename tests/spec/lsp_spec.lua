local CodeActions = require("nuntio.lsp.code_actions")
local Completion = require("nuntio.lsp.completion")
local Diagnostics = require("nuntio.lsp.diagnostics")
local Hover = require("nuntio.lsp.hover")
local Lsp = require("nuntio.lsp")
local Symbols = require("nuntio.lsp.symbols")

describe("In-Process LSP Server & Completion", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "http", { buf = buf })

  local sample_lines = {
    "@baseUrl = https://httpbin.org",
    "@apiVersion = v1",
    "",
    "### Shared",
    "User-Agent: nuntio-test",
    "",
    "### 1. Create User",
    "# @name create_user",
    "# @curl-location",
    "POST {{baseUrl}}/post",
    "Content-Type: application/json",
    "Authorization: Bearer my_token",
    "",
    "{",
    '  "id": "{{$uuid}}",',
    '  "version": "{{apiVersion}}"',
    "}",
    "",
    "### 2. Follow-up Request",
    "GET {{baseUrl}}/user/{{create_user.response.body.$.id}}",
    "Accept: ",
    "",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample_lines)

  it("completes HTTP methods on blank line", function()
    local res = Completion.get_completions(buf, 2, 0)
    assert_true(#res.items > 0, "should return completion items")
    local methods = {}
    for _, item in ipairs(res.items) do
      if item.kind == 2 then -- Method
        methods[item.label] = true
      end
    end
    assert_true(methods["GET"], "should suggest GET")
    assert_true(methods["POST"], "should suggest POST")
    assert_true(methods["PUT"], "should suggest PUT")
    assert_true(methods["DELETE"], "should suggest DELETE")
  end)

  it("completes directives when typing # @", function()
    local temp_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, { "# @" })
    local res = Completion.get_completions(temp_buf, 0, 3)
    assert_true(#res.items > 0, "should return directive completions")
    local dirs = {}
    for _, item in ipairs(res.items) do
      dirs[item.label] = true
    end
    assert_true(dirs["name"], "should suggest name")
    assert_true(dirs["prompt"], "should suggest prompt")
    assert_true(dirs["secret"], "should suggest secret")
    assert_true(dirs["curl-location"], "should suggest curl-location")
    assert_true(dirs["env-json-key"], "should suggest env-json-key")
    vim.api.nvim_buf_delete(temp_buf, { force = true })
  end)

  it("completes dynamic variables when typing {{$", function()
    local temp_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, { '  "id": "{{$' })
    local res = Completion.get_completions(temp_buf, 0, 12)
    assert_true(#res.items > 0, "should return dynamic variable completions")
    local dyns = {}
    for _, item in ipairs(res.items) do
      dyns[item.label] = true
    end
    assert_true(dyns["$uuid"], "should suggest $uuid")
    assert_true(dyns["$timestamp"], "should suggest $timestamp")
    assert_true(dyns["$isoTimestamp"], "should suggest $isoTimestamp")
    assert_true(dyns["$date"], "should suggest $date")
    assert_true(dyns["$randomInt"], "should suggest $randomInt")
    vim.api.nvim_buf_delete(temp_buf, { force = true })
  end)

  it("completes document variables and chained responses when typing {{", function()
    local temp_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, {
      "@myVar = hello",
      "",
      "### Login Request",
      "# @name login",
      "POST https://api.com/login",
      "",
      "### Profile Request",
      "GET https://api.com/profile?v={{",
    })
    local res = Completion.get_completions(temp_buf, 7, 33)
    assert_true(#res.items > 0, "should return variables")
    local labels = {}
    for _, item in ipairs(res.items) do
      labels[item.label] = true
    end
    assert_true(labels["myVar"], "should suggest in-file variable myVar")
    assert_true(labels["login.response.body.$."], "should suggest login response body")
    assert_true(labels["login.response.headers."], "should suggest login response headers")
    vim.api.nvim_buf_delete(temp_buf, { force = true })
  end)

  it("completes standard HTTP headers in header block", function()
    local temp_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, {
      "POST https://api.com/users",
      "Con",
    })
    local res = Completion.get_completions(temp_buf, 1, 3)
    assert_true(#res.items > 0, "should return header completions")
    local headers = {}
    for _, item in ipairs(res.items) do
      headers[item.label] = true
    end
    assert_true(headers["Content-Type"], "should suggest Content-Type")
    assert_true(headers["Authorization"], "should suggest Authorization")
    assert_true(headers["Accept"], "should suggest Accept")
    vim.api.nvim_buf_delete(temp_buf, { force = true })
  end)

  it("completes MIME types after Content-Type: or Accept:", function()
    local temp_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, {
      "POST https://api.com/users",
      "Content-Type: ",
    })
    local res = Completion.get_completions(temp_buf, 1, 14)
    assert_true(#res.items > 0, "should return MIME types")
    local mimes = {}
    for _, item in ipairs(res.items) do
      mimes[item.label] = true
    end
    assert_true(mimes["application/json"], "should suggest application/json")
    assert_true(mimes["multipart/form-data"], "should suggest multipart/form-data")
    assert_true(mimes["application/x-www-form-urlencoded"], "should suggest form urlencoded")
    vim.api.nvim_buf_delete(temp_buf, { force = true })
  end)

  it("completes Auth schemes after Authorization:", function()
    local temp_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, {
      "POST https://api.com/users",
      "Authorization: ",
    })
    local res = Completion.get_completions(temp_buf, 1, 15)
    assert_true(#res.items > 0, "should return auth schemes")
    local auths = {}
    for _, item in ipairs(res.items) do
      auths[item.label] = true
    end
    assert_true(auths["Bearer "], "should suggest Bearer")
    assert_true(auths["Basic "], "should suggest Basic")
    vim.api.nvim_buf_delete(temp_buf, { force = true })
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

describe("In-Process LSP Hover Provider", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "http", { buf = buf })

  local sample_lines = {
    "@testKey = sample_val_123",
    "",
    "### Shared",
    "User-Agent: my-agent",
    "",
    "### Test Request",
    "# @curl-location",
    "POST https://api.com/items",
    "Content-Type: application/json",
    "",
    '{"uuid": "{{$uuid}}", "key": "{{testKey}}", "missing": "{{unknownKey}}"}',
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample_lines)

  it("provides hover documentation for dynamic variables", function()
    local hover = Hover.get_hover(buf, 10, 14)
    assert_not_nil(hover, "hover should not be nil")
    assert_true(hover.contents.value:find("$uuid") ~= nil, "should contain $uuid")
    assert_true(hover.contents.value:find("Evaluated now") ~= nil, "should show evaluated preview")
  end)

  it("provides hover documentation for document variables", function()
    local hover = Hover.get_hover(buf, 10, 36)
    assert_not_nil(hover, "hover should not be nil")
    assert_true(hover.contents.value:find("testKey") ~= nil, "should mention testKey")
    assert_true(hover.contents.value:find("sample_val_123") ~= nil, "should display resolved value")
  end)

  it("warns on undefined variables in hover tooltip", function()
    local hover = Hover.get_hover(buf, 10, 60)
    assert_not_nil(hover, "hover should not be nil")
    assert_true(hover.contents.value:find("Undefined Variable") ~= nil, "should warn undefined")
  end)

  it("provides hover documentation for HTTP methods", function()
    local hover = Hover.get_hover(buf, 7, 2)
    assert_not_nil(hover, "hover should not be nil")
    assert_true(hover.contents.value:find("HTTP Method: `POST`") ~= nil, "should describe POST")
    assert_true(hover.contents.value:find("Idempotent") ~= nil, "should mention idempotency")
  end)

  it("provides hover documentation for HTTP headers", function()
    local hover = Hover.get_hover(buf, 8, 4)
    assert_not_nil(hover, "hover should not be nil")
    assert_true(hover.contents.value:find("HTTP Header: `Content-Type`", 1, true) ~= nil, "should describe Content-Type")
    assert_true(hover.contents.value:find("RFC 9110", 1, true) ~= nil, "should reference RFC")
  end)

  it("provides hover documentation for ### Shared blocks", function()
    local hover = Hover.get_hover(buf, 2, 4)
    assert_not_nil(hover, "hover should not be nil")
    assert_true(hover.contents.value:find("Shared Configuration Block", 1, true) ~= nil, "should explain shared block")
  end)

  it("provides hover documentation for directives", function()
    local hover = Hover.get_hover(buf, 6, 6)
    assert_not_nil(hover, "hover should not be nil")
    assert_true(hover.contents.value:find("@curl-location", 1, true) ~= nil, "should explain directive")
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

describe("In-Process LSP Document Symbols", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "http", { buf = buf })

  local sample_lines = {
    "@var1 = val1",
    "@var2 = val2",
    "",
    "### Shared",
    "Authorization: Bearer my_shared_token",
    "",
    "### Login User",
    "# @name auth",
    "POST https://api.com/login",
    "Content-Type: application/json",
    "",
    "### Get User Profile",
    "GET https://api.com/profile",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample_lines)

  it("generates structured symbol tree for document variables and requests", function()
    local symbols = Symbols.get_symbols(buf)
    assert_true(#symbols >= 3, "should produce symbols for variables, shared, and requests")

    -- Document Variables module
    assert_equal(symbols[1].name, "Document Variables")
    assert_equal(#symbols[1].children, 2)
    assert_equal(symbols[1].children[1].name, "@var1")

    -- Shared block
    assert_equal(symbols[2].name, "󰒘 Shared Defaults")

    -- Request block
    assert_true(symbols[3].name:find("POST auth") ~= nil, "should symbol POST auth")
    assert_true(#symbols[3].children > 0, "should have children (method, url, headers)")

    -- Second request block
    assert_true(symbols[4].name:find("Get User Profile", 1, true) ~= nil, "should symbol Get User Profile")
    assert_true(symbols[4].detail:find("https://api.com/profile", 1, true) ~= nil, "should contain url in detail")
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

describe("In-Process LSP Diagnostics", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "http", { buf = buf })

  local sample_lines = {
    "@knownVar = exists",
    "",
    "### 1. Valid Request",
    "GET https://api.com/ok?val={{knownVar}}",
    "",
    "### 2. Request with missing external file and undefined variable",
    "POST https://api.com/upload",
    "Content-Type: application/json",
    "",
    "< ./this_file_does_not_exist_at_all.json",
    "Header-Val: {{totally_undefined_variable_xyz}}",
    "",
    "### 3. Missing URL Request",
    "POST ",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample_lines)

  it("flags missing external file, undefined variable, and empty URL", function()
    Diagnostics.check(buf)
    local diags = vim.diagnostic.get(buf)
    assert_true(#diags >= 3, "should report diagnostics for all 3 issues")

    local messages = {}
    for _, d in ipairs(diags) do
      table.insert(messages, d.message)
    end
    local all_msg = table.concat(messages, "\n")

    assert_true(all_msg:find("External file not found") ~= nil, "should flag missing file")
    assert_true(all_msg:find("Undefined variable") ~= nil, "should flag undefined variable")
    assert_true(all_msg:find("Missing target URL") ~= nil, "should flag empty URL")
  end)

  it("clears diagnostics when cleared", function()
    Diagnostics.clear(buf)
    local diags = vim.diagnostic.get(buf)
    assert_equal(#diags, 0)
  end)

  it("ignores comments containing <tags> or {{variables}} and recognizes metadata variables", function()
    local temp_buf = vim.api.nvim_create_buf(false, true)
    local test_lines = {
      "# <leader>Rs : Keymap comment that is not a file include",
      "# Comment describing {{variables}} syntax",
      "",
      "### Step 1",
      "# @prompt userName Enter username",
      "# @secret userPass Enter password",
      "# @env-json-key author = $.author",
      "# @env-header-key server = Server",
      "GET https://api.com/meta",
      "",
      "### Step 2",
      "POST https://api.com/login",
      "Content-Type: application/json",
      "",
      "{",
      '  "user": "{{userName}}",',
      '  "pass": "{{userPass}}",',
      '  "author": "{{author}}",',
      '  "server": "{{server}}"',
      "}",
    }
    vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, test_lines)

    Diagnostics.check(temp_buf)
    local diags = vim.diagnostic.get(temp_buf)
    assert_equal(#diags, 0, "should have 0 diagnostics on comments and metadata-declared variables")
    vim.api.nvim_buf_delete(temp_buf, { force = true })
  end)

  it("evaluates examples/demo.http with 0 diagnostics", function()
    local demo_buf = vim.fn.bufadd("examples/demo.http")
    vim.fn.bufload(demo_buf)
    Diagnostics.check(demo_buf)
    local diags = vim.diagnostic.get(demo_buf)
    assert_equal(#diags, 0, "demo.http should be completely free of diagnostics")
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

describe("In-Process LSP Code Actions & Client Lifecycle", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "http", { buf = buf })

  local sample_lines = {
    "### Simple Request",
    "GET https://api.com/test",
    "Accept: application/json",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample_lines)

  it("returns relevant code actions on request block", function()
    local actions = CodeActions.get_code_actions(buf, 1)
    assert_true(#actions > 0, "should return code actions")
    local titles = {}
    for _, a in ipairs(actions) do
      table.insert(titles, a.title)
    end
    local all_titles = table.concat(titles, " | ")
    assert_true(all_titles:find("Run") ~= nil, "should offer Run action")
    assert_true(all_titles:find("Copy as cURL") ~= nil, "should offer Copy cURL action")
    assert_true(all_titles:find("Switch environment") ~= nil, "should offer Switch environment")
  end)

  it("attaches client to buffer via vim.lsp.start", function()
    pcall(vim.api.nvim_buf_set_name, buf, "/tmp/nuntio_lsp_lifecycle_test.http")
    local client_id = Lsp.attach(buf)
    assert_not_nil(client_id, "LSP client should attach and return ID")
    local client = vim.lsp.get_client_by_id(client_id)
    assert_not_nil(client, "client should exist")
    assert_equal(client.name, "nuntio-lsp")

    -- Verify capabilities
    assert_true(client.server_capabilities.completionProvider ~= nil, "should have completion capability")
    assert_true(client.server_capabilities.hoverProvider == true, "should have hover capability")
    assert_true(client.server_capabilities.documentSymbolProvider == true, "should have symbol capability")
    assert_true(client.server_capabilities.codeActionProvider == true, "should have codeAction capability")
    assert_true(client.server_capabilities.documentFormattingProvider == true, "should have formatting capability")

    -- Test request dispatch over in-process RPC
    local hover_params = {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = 1, character = 2 },
    }

    local hover_received = false
    client:request("textDocument/hover", hover_params, function(err, result)
      assert_nil(err)
      assert_not_nil(result)
      hover_received = true
    end, buf)

    vim.wait(300, function() return hover_received end)
    assert_true(hover_received, "hover request should complete asynchronously")
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

describe("In-Process LSP Document Formatter", function()
  local Formatter = require("nuntio.lsp.formatter")
  local Nuntio = require("nuntio")

  it("formats methods, headers, and spacing in .http document", function()
    local unformatted = {
      "@baseUrl=https://api.com",
      "###unnamed",
      "get   {{baseUrl}}/users",
      "accept:application/json",
      "cache-control:  no-cache",
      "",
      "###Second",
      "post https://api.com/items",
      "content-type:application/json",
      "",
      '{"name":"item1","price":10}',
    }

    local formatted = Formatter.format_lines(unformatted, 2)
    local text = table.concat(formatted, "\n")

    assert_true(text:find("@baseUrl = https://api.com") ~= nil, "should format variable definition")
    assert_true(text:find("### unnamed") ~= nil, "should space ### delimiter")
    assert_true(text:find("GET {{baseUrl}}/users") ~= nil, "should uppercase GET and normalize space")
    assert_true(text:find("accept: application/json") ~= nil, "should format header spacing")
    assert_true(text:find("### Second") ~= nil, "should space second section")
    assert_true(text:find("POST https://api.com/items") ~= nil, "should uppercase POST")
    assert_true(text:find('"name": "item1"') ~= nil, "should format JSON body with space after colon")
  end)

  it("formats JSON bodies while preserving template variables", function()
    local raw_json = '{"user":"{{userName}}","id":{{$uuid}},"details":{"active":true}}'
    local formatted = Formatter.format_json(raw_json, "  ")

    assert_true(formatted:find('"user": "{{userName}}"') ~= nil, "should preserve string variable")
    assert_true(formatted:find('"id": {{$uuid}}') ~= nil, "should preserve dynamic variable value")
    assert_true(formatted:find('  "details": {\n    "active": true\n  }') ~= nil, "should indent nested object")
  end)

  it("formats buffer directly via Nuntio.format()", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "post https://api.com/create",
      "content-type:application/json",
      "",
      '{"key":"val"}',
    })

    Nuntio.format(buf)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert_equal(lines[1], "POST https://api.com/create")
    assert_equal(lines[2], "content-type: application/json")
    assert_equal(lines[3], "")
    assert_equal(lines[4], "{")
    assert_equal(lines[5], '  "key": "val"')
    assert_equal(lines[6], "}")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
