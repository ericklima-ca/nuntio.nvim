local Highlights = require("nuntio.ui.highlights")
local History = require("nuntio.ui.history")
local Pickers = require("nuntio.ui.pickers")
local Store = require("nuntio.store")
local View = require("nuntio.ui.view")
local Winbar = require("nuntio.ui.winbar")

describe("Modern UI and Chain View", function()
  it("initializes highlights without error", function()
    Highlights.setup()
    local ns = Highlights.get_namespace()
    assert_true(ns ~= nil and ns > 0, "namespace created")
    assert_eq(Highlights.get_method_hl("GET"), "NuntioMethodGet")
    assert_eq(Highlights.get_method_hl("POST"), "NuntioMethodPost")
    assert_eq(Highlights.get_method_hl("DELETE"), "NuntioMethodDelete")
    assert_eq(Highlights.get_status_hl(200), "NuntioStatus2xx")
    assert_eq(Highlights.get_status_hl(404), "NuntioStatus4xx")
    assert_eq(Highlights.get_status_hl(500), "NuntioStatus5xx")
  end)

  it("renders modern winbar with glyphs and mouse handlers", function()
    local bar = Winbar.render("body")
    assert_true(bar:match("󰖟") ~= nil, "contains body icon")
    assert_true(bar:match("NuntioWinbarActive") ~= nil, "has active tab highlight")
    assert_true(bar:match("NuntioWinbarClick_body") ~= nil, "has click callback")

    -- Test winbar with chain indicator and response metrics
    local fake_chain_resp = { status = 200, time = 100, chain = { step = 2, total = 2 } }
    local bar_chain = Winbar.render("chain", fake_chain_resp)
    assert_true(bar_chain:match("󰌷") ~= nil, "contains chain icon")
    assert_true(bar_chain:match("2%/2") ~= nil, "contains chain count")
    assert_true(bar_chain:match("200") ~= nil, "contains status 200")
  end)

  it("cycles through available tabs with next_view and prev_view", function()
    local fake_chain_resp = { status = 200, time = 100, chain = { step = 2, total = 2 } }
    Store.history = { fake_chain_resp }
    View.history_idx = 1
    View.active_view = "body"

    View.next_view()
    assert_eq(View.active_view, "headers")

    View.next_view()
    assert_eq(View.active_view, "headers_body")

    View.next_view()
    assert_eq(View.active_view, "chain")

    View.next_view()
    assert_eq(View.active_view, "stats")

    View.next_view()
    assert_eq(View.active_view, "verbose")

    View.next_view()
    assert_eq(View.active_view, "body")

    -- Test previous (left)
    View.prev_view()
    assert_eq(View.active_view, "verbose")

    View.prev_view()
    assert_eq(View.active_view, "stats")
  end)

  it("renders pure clean body at line 1 in body view", function()
    View.active_view = "body"
    View.display({
      id = "test_body",
      method = "GET",
      url = "https://api.com/users",
      status = 200,
      headers = { ["content-type"] = "application/json" },
      body = '{"name": "Alice", "role": "admin"}',
      raw_headers = "HTTP/1.1 200 OK\n\n",
    })

    local line1 = vim.api.nvim_buf_get_lines(View.bufnr, 0, 1, false)[1]
    assert_eq(line1, "{", "line 1 is the clean JSON body")
    View.close()
  end)

  it("formats and displays chain timeline with exported and injected variables", function()
    local fake_resp = {
      id = "test_1",
      name = "chained_request",
      method = "POST",
      url = "https://httpbin.org/anything",
      status = 200,
      status_text = "OK",
      time = 138.4,
      headers = {},
      raw_headers = "HTTP/1.1 200 OK\n\n",
      cookies = {},
      body = '{"success": true}',
      raw_body = '{"success": true}',
      json = { success = true },
      timestamp = os.time(),
      env = "dev",
      chain = {
        id = "ch_test_99",
        step = 2,
        total = 2,
        steps = {
          {
            step = 1,
            name = "create_session",
            method = "POST",
            url = "https://httpbin.org/post",
            status = 200,
            status_text = "OK",
            time = 142.1,
            size = 738,
            is_prereq = true,
            exported = {
              ["create_session.response.body.$.json.uuid"] = "cb9c1a5b-6910-4fb2-b457-a9c72a392d90",
            },
          },
          {
            step = 2,
            name = "chained_request",
            method = "POST",
            url = "https://httpbin.org/anything",
            status = 200,
            status_text = "OK",
            time = 138.4,
            size = 812,
            is_prereq = false,
            injected = {
              ["create_session.response.body.$.json.uuid"] = "cb9c1a5b-6910-4fb2-b457-a9c72a392d90",
            },
          },
        },
      },
    }

    Store.history = { fake_resp }
    View.history_idx = 1
    View.active_view = "chain"
    View.display(fake_resp)

    local lines = vim.api.nvim_buf_get_lines(View.bufnr, 0, -1, false)
    local full_text = table.concat(lines, "\n")

    -- Check chain timeline content
    assert_true(full_text:match("EXECUTION CHAIN TIMELINE") ~= nil, "chain title")
    assert_true(full_text:match("create_session") ~= nil, "step 1 name")
    assert_true(full_text:match("Upstream Prerequisite") ~= nil, "step 1 role")
    assert_true(full_text:match("cb9c1a5b") ~= nil, "exported variable value")
    assert_true(full_text:match("chained_request") ~= nil, "step 2 name")
    assert_true(full_text:match("Downstream Consumer") ~= nil, "step 2 role")
    assert_true(full_text:match("Active View") ~= nil, "active view marker")
    assert_true(full_text:match("piped into dependent request") ~= nil, "dependency edge")

    View.close()
  end)

  it("extracts variable references correctly from blocks", function()
    local RequestVars = require("nuntio.parser.request_vars")
    local block = {
      url = "https://api.com/users/{{auth.response.body.$.id}}",
      headers = { authorization = "Bearer {{auth.response.body.$.token}}" },
      body = '{"client": "{{login.response.body.$.client}}", "code": {{auth.response.headers.code}}}',
    }

    local refs = RequestVars.get_block_variable_references(block)
    assert_true(refs["auth"] ~= nil, "auth referenced")
    assert_true(refs["login"] ~= nil, "login referenced")
    assert_eq(#refs["auth"], 3)
    assert_eq(#refs["login"], 1)
  end)

  it("tracks chains formed via @env-json-key dynamic environment variables", function()
    local RequestVars = require("nuntio.parser.request_vars")
    local producer = {
      name = "auth_token_generator",
      url = "https://api.com/auth",
      metadata = {
        ["env-json-key"] = { "jwt_token = $.token" },
      },
    }
    local consumer = {
      name = "get_profile",
      url = "https://api.com/profile",
      headers = { authorization = "Bearer {{jwt_token}}" },
    }
    local all_blocks = { producer, consumer }

    local deps = RequestVars.get_block_dependencies(consumer, all_blocks)
    assert_eq(#deps, 1)
    assert_eq(deps[1], "auth_token_generator")

    local refs = RequestVars.get_block_variable_references(consumer, all_blocks)
    assert_true(refs["auth_token_generator"] ~= nil)
    assert_eq(refs["auth_token_generator"][1], "jwt_token")
  end)

  it("renders visible dividers on ### request boundaries", function()
    local Dividers = require("nuntio.ui.dividers")
    local Config = require("nuntio.config")
    Config.setup({
      dividers = { enabled = true, icon = "󰖟", hint = true, style = "above" },
    })

    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "@baseUrl = https://api.com",
      "",
      "### Shared",
      "User-Agent: my-agent",
      "",
      "### 1. First Request",
      "GET {{baseUrl}}/users",
      "",
      "### 2. Second Request",
      "POST {{baseUrl}}/users",
    })
    vim.bo[bufnr].filetype = "http"

    Dividers.render(bufnr)

    local ns_id = vim.api.nvim_create_namespace("nuntio_dividers")
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
    assert_eq(#marks, 3, "3 dividers rendered (including shared)")

    -- Mark 1 is ### Shared
    local m_shared = marks[1]
    assert_eq(m_shared[2], 2, "shared mark on row 2")
    assert_true(m_shared[4].virt_lines_above, "virt_lines_above is true")
    assert_true(m_shared[4].virt_lines[1][2][1]:match("SHARED DEFAULTS") ~= nil, "shared defaults header rule")
    assert_true(m_shared[4].virt_text[1][1]:match("Auto%-injected into all requests") ~= nil, "shared auto-injected badge")

    -- Mark 2 is runnable request
    local m_req = marks[2]
    assert_eq(m_req[2], 5, "request mark on row 5")
    assert_true(m_req[4].virt_text[2][1]:match("▶") ~= nil, "run symbol on runnable request")

    -- Test clear
    Dividers.clear(bufnr)
    local cleared = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
    assert_eq(#cleared, 0, "dividers cleared")
  end)

  it("applies header syntax highlights to headers inside ### Shared blocks", function()
    local Dividers = require("nuntio.ui.dividers")
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "### Shared",
      "# Comment line",
      "User-Agent: nuntio.nvim/1.0",
      "X-Custom-Auth: Bearer {{token}}",
      "",
      "### 1. Test",
      "GET https://api.com",
    })
    vim.bo[bufnr].filetype = "http"

    Dividers.render(bufnr)

    local header_ns_id = vim.api.nvim_create_namespace("nuntio_shared_headers")
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, header_ns_id, 0, -1, { details = true })
    assert_true(#marks >= 4, "extmarks applied to header keys and values in ### Shared")

    -- Check User-Agent header key mark
    local found_user_agent = false
    for _, mark in ipairs(marks) do
      if mark[2] == 2 and mark[4].hl_group == "NuntioHeaderKey" then
        found_user_agent = true
        assert_eq(mark[4].end_col, 10, "User-Agent is 10 chars")
        assert_eq(mark[4].priority, 130, "priority 130 overrides tree-sitter target_url")
      end
    end
    assert_true(found_user_agent, "User-Agent header key marked with NuntioHeaderKey")

    Dividers.clear(bufnr)
    local cleared = vim.api.nvim_buf_get_extmarks(bufnr, header_ns_id, 0, -1, {})
    assert_eq(#cleared, 0, "shared header marks cleared")
  end)

  it("decorates simplified multipart and RFC 7578 multipart bodies", function()
    local Dividers = require("nuntio.ui.dividers")
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "### Simplified Multipart",
      "POST https://api.com/upload",
      "Content-Type: multipart/form-data",
      "",
      "title = My Document",
      "file = < ./data.json; type=application/json",
      "",
      "### Raw RFC 7578 Multipart",
      "POST https://api.com/upload",
      "Content-Type: multipart/form-data; boundary=----WebKitFormBoundary{{$timestamp}}",
      "",
      "------WebKitFormBoundary{{$timestamp}}",
      'Content-Disposition: form-data; name="title"',
      "",
      "Demo File Upload",
      "------WebKitFormBoundary{{$timestamp}}",
      'Content-Disposition: form-data; name="file"; filename="payload.json"',
      "Content-Type: application/json",
      "",
      "< ./payload.json",
      "------WebKitFormBoundary{{$timestamp}}--",
    })
    vim.bo[bufnr].filetype = "http"

    Dividers.render(bufnr)

    local header_ns_id = vim.api.nvim_create_namespace("nuntio_shared_headers")
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, header_ns_id, 0, -1, { details = true })
    assert_true(#marks > 15, "extmarks applied to multipart bodies and boundaries")

    -- Verify simplified form field 'title ='
    local has_title_var = false
    for _, m in ipairs(marks) do
      if m[2] == 4 and m[4].hl_group == "NuntioDocVar" then
        has_title_var = true
      end
    end
    assert_true(has_title_var, "title field decorated with NuntioDocVar")

    -- Verify multipart boundary line has divider hl and variable hl
    local has_boundary = false
    local has_boundary_var = false
    for _, m in ipairs(marks) do
      if m[2] == 11 and m[4].hl_group == "NuntioBannerDoubleDivider" then
        has_boundary = true
      end
      if m[2] == 11 and m[4].hl_group == "NuntioVariable" then
        has_boundary_var = true
      end
    end
    assert_true(has_boundary, "MIME boundary decorated with NuntioBannerDoubleDivider")
    assert_true(has_boundary_var, "{{$timestamp}} in boundary decorated with NuntioVariable")

    -- Verify embedded Content-Disposition header
    local has_content_disp = false
    for _, m in ipairs(marks) do
      if m[2] == 12 and m[4].hl_group == "NuntioHeaderKey" then
        has_content_disp = true
      end
    end
    assert_true(has_content_disp, "Content-Disposition inside body decorated with NuntioHeaderKey")
  end)

  it("highlights HTTP requests, JSON bodies and nested template variables", function()
    vim.cmd("syntax on")
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "http"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "@baseUrl = https://api.com",
      "### Shared",
      "User-Agent: test-app",
      "# @name login_user",
      "### Login",
      "POST {{baseUrl}}/login",
      "Content-Type: application/json",
      "",
      "{",
      '  "user_id": "{{user_id}}",',
      '  "active": true',
      "}",
    })
    vim.cmd("syntax sync fromstart")

    -- Doc variable
    local syn_docvar = vim.fn.synIDattr(vim.fn.synID(1, 2, 1), "name")
    assert_eq(syn_docvar, "httpDocVarName")

    -- Shared delimiter keyword
    local syn_shared = vim.fn.synIDattr(vim.fn.synID(2, 6, 1), "name")
    assert_eq(syn_shared, "httpSharedKeyword")

    -- Metadata tag
    local syn_tag = vim.fn.synIDattr(vim.fn.synID(4, 4, 1), "name")
    assert_eq(syn_tag, "httpMetadataTag")

    -- Method
    local syn_post = vim.fn.synIDattr(vim.fn.synID(6, 2, 1), "name")
    assert_eq(syn_post, "httpMethodPost")

    -- JSON keyword inside request body
    local syn_json_key = vim.fn.synIDattr(vim.fn.synID(10, 5, 1), "name")
    assert_eq(syn_json_key, "jsonKeyword")

    -- Nested template variable inside JSON string
    local syn_var_in_json = vim.fn.synIDattr(vim.fn.synID(10, 16, 1), "name")
    assert_eq(syn_var_in_json, "httpVariable")
  end)

  it("evaluates live filter expressions (JSONPath and JQ)", function()
    local Filter = require("nuntio.ui.filter")
    local sample = '{"user": {"name": "Alice", "id": 42}, "roles": ["admin", "dev"]}'

    -- Empty query returns original
    local ok0, res0 = Filter.eval(sample, "")
    assert_true(ok0)
    assert_eq(res0, sample)

    -- JSONPath query
    local ok1, res1 = Filter.eval(sample, "$.user.name")
    assert_true(ok1)
    assert_eq(res1, "Alice")

    -- Dot notation fallback
    local ok2, res2 = Filter.eval(sample, ".user.id")
    assert_true(ok2)
    assert_true(res2:find("42") ~= nil)

    -- Array index
    local ok3, res3 = Filter.eval(sample, "$.roles[0]")
    assert_true(ok3)
    assert_eq(res3, "admin")

    -- Invalid / non-existent path
    local ok4, res4 = Filter.eval(sample, "$.user.nonexistent")
    assert_true(not ok4)
    assert_true(res4:find("No matches") ~= nil)
  end)

  it("integrates live filter with response view and winbar", function()
    local View = require("nuntio.ui.view")
    local Filter = require("nuntio.ui.filter")
    local Winbar = require("nuntio.ui.winbar")
    local Store = require("nuntio.store")

    local fake_resp = {
      id = "test_filter_resp",
      method = "GET",
      url = "https://api.com/profile",
      status = 200,
      headers = { ["content-type"] = "application/json" },
      body = '{"profile": {"username": "nuntio_user", "role": "lead"}}',
      raw_headers = "HTTP/1.1 200 OK\n\n",
    }
    Store.add_response(fake_resp)

    View.active_view = "body"
    View.display(fake_resp)

    -- Initially un-filtered
    local l1 = vim.api.nvim_buf_get_lines(View.bufnr, 0, 1, false)[1]
    assert_eq(l1, "{", "clean JSON body without filter")

    -- Apply filter
    Filter.active_filter = "$.profile.username"
    View.switch_view("body")

    local l_filtered = vim.api.nvim_buf_get_lines(View.bufnr, 0, 1, false)[1]
    assert_eq(l_filtered, "nuntio_user", "body view displays filtered value")

    -- Verify winbar shows active filter badge
    local wb_str = Winbar.render("body", fake_resp)
    assert_true(wb_str:find("󰈲 %$%.profile%.username") ~= nil, "winbar contains filter badge")
    assert_true(wb_str:find("F:Filter") ~= nil, "winbar contains F:Filter help hint")

    -- Clear filter
    Filter.clear()
    assert_nil(Filter.active_filter)

    local l_cleared = vim.api.nvim_buf_get_lines(View.bufnr, 0, 1, false)[1]
    assert_true(l_cleared == "{" or l_cleared:find("profile") ~= nil, "restores full body")

    View.close()
  end)

  it("collects requests with rich metadata across buffer and workspace", function()
    local sample_doc = {
      "@baseUrl = https://api.test.com",
      "",
      "### Shared",
      "User-Agent: test-suite",
      "",
      "### 1. List Users",
      "# @name list_users",
      "GET {{baseUrl}}/users",
      "Accept: application/json",
      "",
      "### 2. Create User",
      "# @name create_user",
      "POST {{baseUrl}}/users",
      "Content-Type: application/json",
      "",
      '{"name": "tester"}',
    }

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sample_doc)
    vim.bo[bufnr].filetype = "http"

    -- 1. Buffer scope
    local buf_items = Pickers.collect_requests("buffer", bufnr)
    assert_eq(#buf_items, 2, "found 2 runnable requests in buffer")
    assert_eq(buf_items[1].method, "GET")
    assert_eq(buf_items[1].name, "list_users")
    assert_true(buf_items[1].url:find("/users") ~= nil)
    assert_true(#buf_items[1].preview_lines > 0)
    assert_eq(buf_items[2].method, "POST")
    assert_eq(buf_items[2].name, "create_user")
    assert_true(buf_items[2].shared_block ~= nil, "attached shared block")

    -- 2. Workspace scope
    local ws_items = Pickers.collect_requests("workspace")
    assert_true(#ws_items >= 19, "workspace scan found demo.http requests")
    local found_post = false
    for _, it in ipairs(ws_items) do
      if it.method == "POST" and it.name == "create_session" then
        found_post = true
        assert_true(it.filepath:find("demo.http") ~= nil)
        break
      end
    end
    assert_true(found_post, "found create_session from demo.http")

    -- 3. Jump to item
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    Pickers.jump_to(buf_items[2])
    local cur_pos = vim.api.nvim_win_get_cursor(win)
    assert_eq(cur_pos[1], buf_items[2].start_line, "jumped cursor to request start line")

    -- 4. Run item directly from picker
    local Runner = require("nuntio.runner")
    local original_run = Runner.run_block
    local ran_block = nil
    Runner.run_block = function(block)
      ran_block = block
    end

    Pickers.run_item(buf_items[1])
    assert_true(ran_block ~= nil, "invoked Runner.run_block")
    assert_eq(ran_block.method, "GET")
    Runner.run_block = original_run

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("opens dual-pane builtin picker with live preview and handles search", function()
    local sample_doc = {
      "### @name test_endpoint",
      "GET https://httpbin.org/get",
      "Accept: application/json",
    }
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sample_doc)
    vim.bo[bufnr].filetype = "http"

    local items = Pickers.collect_requests("buffer", bufnr)
    assert_eq(#items, 1)

    -- Test pick_builtin
    Pickers.pick_builtin(items, { bufnr = bufnr, scope = "buffer" })

    -- Find created floating windows
    local wins = vim.api.nvim_list_wins()
    local float_wins = {}
    for _, w in ipairs(wins) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= "" then
        table.insert(float_wins, w)
      end
    end

    assert_true(#float_wins >= 3, "opened prompt, list, and preview floating windows")

    -- Clean up all floating windows
    for _, w in ipairs(float_wins) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
