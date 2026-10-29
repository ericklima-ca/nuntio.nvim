local Config = require("nuntio.config")
local CurlImport = require("nuntio.parser.curl_import")
local Highlights = require("nuntio.ui.highlights")
local History = require("nuntio.ui.history")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")
local Winbar = require("nuntio.ui.winbar")

local M = {}

---@type integer|nil
M.bufnr = nil

local tests_ns = vim.api.nvim_create_namespace("nuntio_tests")

---@type integer|nil
M.winid = nil

---@type string
M.active_view = "body"

--- History navigation index
---@type integer
M.history_idx = 0

--- Infer filetype from Content-Type header
---@param headers table<string, string>
---@param body string
---@return string
local function detect_filetype(headers, body)
  local ct = nil
  for k, v in pairs(headers or {}) do
    if k:lower() == "content-type" then
      ct = v:lower()
      break
    end
  end

  if ct then
    if ct:match("application/json") or ct:match("%+json") then
      return "json"
    elseif ct:match("text/html") then
      return "html"
    elseif ct:match("xml") then
      return "xml"
    elseif ct:match("javascript") then
      return "javascript"
    elseif ct:match("css") then
      return "css"
    end
  end

  local trimmed = Utils.trim(body)
  if (trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}") or
     (trimmed:sub(1, 1) == "[" and trimmed:sub(-1) == "]") then
    return "json"
  elseif trimmed:sub(1, 1) == "<" and trimmed:sub(-1) == ">" then
    return "xml"
  end

  return "text"
end

--- Format JSON body with 2 spaces indent
---@param body string
---@return string
local function format_body(body)
  if not body or body == "" then return "" end
  local ok, decoded = pcall(vim.json.decode, body)
  if ok and type(decoded) == "table" then
    return Utils.json_encode(decoded, true)
  end
  return body
end

--- Format chain timeline view
---@param resp NuntioStoredResponse
---@return string[]
local function format_chain(resp)
  local lines = {}
  local chain = resp.chain

  if not chain or not chain.steps or #chain.steps == 0 then
    if resp.exported_vars and next(resp.exported_vars) ~= nil then
      table.insert(lines, "┌─────────────────────────────────────────────────────────────────────────────┐")
      table.insert(lines, "│ 󰌷 EXECUTION CHAIN • UPSTREAM VARIABLE PROVIDER                             │")
      table.insert(lines, "└─────────────────────────────────────────────────────────────────────────────┘")
      table.insert(lines, "")
      table.insert(lines, "  This request exported dynamic session variables for downstream requests:")
      for var_name, info in pairs(resp.exported_vars) do
        local val = info.val or Store.get_global(var_name)
        local src = info.path and (" (from " .. tostring(info.path) .. ")") or ""
        table.insert(lines, string.format("    • {{%s}} ➔ %q%s", var_name, tostring(val), src))
      end
      table.insert(lines, "")
      table.insert(lines, "  Downstream requests can reference these variables directly:")
      local sample_var = next(resp.exported_vars) or "variable"
      table.insert(lines, string.format('    GET /api/resource?user={{%s}}', sample_var))
      return lines
    end

    table.insert(lines, "┌─────────────────────────────────────────────────────────────────────────────┐")
    table.insert(lines, "│ 󰌷 EXECUTION CHAIN                                                          │")
    table.insert(lines, "└─────────────────────────────────────────────────────────────────────────────┘")
    table.insert(lines, "")
    table.insert(lines, "  This request was executed directly without prerequisites or downstream chains.")
    table.insert(lines, "")
    table.insert(lines, "  To chain requests across requests in this file:")
    table.insert(lines, '    • Explicit response path:  "token": "{{login.response.body.$.access_token}}"')
    table.insert(lines, '    • Dynamic session export:  # @env-json-key token = $.access_token')
    return lines
  end

  local total_elapsed = 0
  local successful_steps = 0

  local title = string.format("│ 󰌷 EXECUTION CHAIN TIMELINE (ID: %s)", chain.id or "ch_manual")
  local pad = string.rep(" ", math.max(0, 78 - vim.fn.strdisplaywidth(title))) .. "│"

  table.insert(lines, "┌─────────────────────────────────────────────────────────────────────────────┐")
  table.insert(lines, title .. pad)
  table.insert(lines, "└─────────────────────────────────────────────────────────────────────────────┘")
  table.insert(lines, "")

  for i, step in ipairs(chain.steps) do
    total_elapsed = total_elapsed + (step.time or 0)
    if step.status >= 200 and step.status < 400 then
      successful_steps = successful_steps + 1
    end

    local status_sym = (step.status >= 200 and step.status < 300) and "✔"
      or (step.status >= 300 and step.status < 400) and "󰁔"
      or "󰅚"

    local size_str = ""
    if step.size and step.size > 0 then
      size_str = step.size < 1024 and string.format(" • 📦 %d B", step.size) or string.format(" • 📦 %.1f KB", step.size / 1024)
    end

    local is_current = (step.name == resp.name)
    local role = step.is_prereq and "(Upstream Prerequisite)" or "(Downstream Consumer)"
    if is_current then
      role = role .. " [Active View]"
    end

    table.insert(lines, string.format("[%d/%d]  󰖟 %-6s %s", i, #chain.steps, step.method, step.url))
    table.insert(lines, string.format("       ├─ Target:      # @name %-20s %s", step.name, role))
    table.insert(lines, string.format("       ├─ Status:      %s %d %s  (⏱ %.1fms%s)", status_sym, step.status, step.status_text or "", step.time or 0, size_str))

    local has_exports = step.exported and next(step.exported) ~= nil
    local has_injected = step.injected and next(step.injected) ~= nil

    if has_exports then
      table.insert(lines, "       ├─ Exported:")
      for k, v in pairs(step.exported) do
        table.insert(lines, string.format("       │    • %s ➔ %q", k, tostring(v)))
      end
    end

    if has_injected then
      table.insert(lines, "       └─ Injected:")
      for k, v in pairs(step.injected) do
        table.insert(lines, string.format("            • %s ➔ %q", k, tostring(v)))
      end
    elseif not has_exports then
      table.insert(lines, "       └─ Dependencies satisfied")
    else
      table.insert(lines, "       └─ Exported variables ready for downstream")
    end

    if i < #chain.steps then
      table.insert(lines, "         │")
      table.insert(lines, "         ▼ (piped into dependent request)")
      table.insert(lines, "         │")
    end
  end

  table.insert(lines, "")
  table.insert(lines, "───────────────────────────────────────────────────────────────────────────────")
  table.insert(lines, string.format("󰄬 Chain Summary: %d/%d succeeded  •  %.1fms total elapsed  •  Chain ID: %s",
    successful_steps, #chain.steps, total_elapsed, chain.id or "ch_manual"))

  return lines
end

--- Format stats panel
---@param resp NuntioStoredResponse
---@return string[]
local function format_stats(resp)
  local lines = {}
  table.insert(lines, "┌─────────────────────────────────────────────────────────────────────────────┐")
  table.insert(lines, "│ 󰄬 PERFORMANCE TIMINGS & METRICS                                             │")
  table.insert(lines, "└─────────────────────────────────────────────────────────────────────────────┘")
  table.insert(lines, "")
  table.insert(lines, string.format("  Method:       󰖟 %s", resp.method))
  table.insert(lines, string.format("  URL:          %s", resp.url))
  table.insert(lines, string.format("  Status:       %d %s", resp.status, resp.status_text or ""))
  table.insert(lines, string.format("  Total Time:   %.1f ms", resp.time or 0))
  if resp.env then
    table.insert(lines, string.format("  Environment:  󰏚 %s", resp.env))
  end
  table.insert(lines, "")

  local s = resp.stats or {}
  if s.time_total or s.time_namelookup then
    table.insert(lines, "─── Latency Breakdown (cURL Engine) ──────────────────────────────────────────")
    if s.time_namelookup then
      table.insert(lines, string.format("  DNS Lookup:     %7.2f ms", (tonumber(s.time_namelookup) or 0) * 1000))
    end
    if s.time_connect then
      table.insert(lines, string.format("  TCP Connect:    %7.2f ms", (tonumber(s.time_connect) or 0) * 1000))
    end
    if s.time_appconnect then
      table.insert(lines, string.format("  TLS Handshake:  %7.2f ms", (tonumber(s.time_appconnect) or 0) * 1000))
    end
    if s.time_starttransfer then
      table.insert(lines, string.format("  TTFB (1st Byte):%7.2f ms", (tonumber(s.time_starttransfer) or 0) * 1000))
    end
    if s.time_total then
      table.insert(lines, string.format("  Total Transfer: %7.2f ms", (tonumber(s.time_total) or 0) * 1000))
    end
    if s.size_download then
      local b = tonumber(s.size_download) or 0
      local size_str = b < 1024 and string.format("%d B", b) or string.format("%.1f KB", b / 1024)
      table.insert(lines, string.format("  Download Size:  %s", size_str))
    end
  end

  return lines
end

--- Format assertion results panel
---@param resp NuntioStoredResponse
---@return string[]
local function format_tests(resp)
  local lines = {}
  table.insert(lines, "┌─────────────────────────────────────────────────────────────────────────────┐")
  table.insert(lines, "│ 󰙨 ASSERTIONS                                                                │")
  table.insert(lines, "└─────────────────────────────────────────────────────────────────────────────┘")
  table.insert(lines, "")

  local summary = resp.assertions
  if not summary or summary.total == 0 then
    table.insert(lines, "  No assertions for this request.")
    table.insert(lines, "  Add one above the request line, e.g.  # @assert status == 200")
    return lines
  end

  if summary.failed == 0 then
    table.insert(lines, string.format("  Result:  ✔ %d/%d passed", summary.passed, summary.total))
  else
    table.insert(lines, string.format("  Result:  ✘ %d failed, %d/%d passed", summary.failed, summary.passed, summary.total))
  end
  table.insert(lines, "")

  for _, r in ipairs(summary.results) do
    table.insert(lines, string.format("  %s %s", r.ok and "✔" or "✘", r.expr))
    if not r.ok then
      if r.expected then
        table.insert(lines, string.format("      expected: %s", r.expected))
      end
      if r.actual then
        table.insert(lines, string.format("      actual:   %s", r.actual))
      end
      if r.message then
        table.insert(lines, string.format("      reason:   %s", r.message))
      end
    end
  end

  return lines
end

--- Highlight ✔ / ✘ markers in the Tests panel
---@param buf integer
---@param lines string[]
local function apply_tests_highlights(buf, lines)
  for i, line in ipairs(lines) do
    for _, mark in ipairs({ { "✔", "DiagnosticOk" }, { "✘", "DiagnosticError" } }) do
      local s, e = line:find(mark[1], 1, true)
      if s then
        pcall(vim.api.nvim_buf_set_extmark, buf, tests_ns, i - 1, s - 1, { end_col = e, hl_group = mark[2] })
      end
    end
  end
end

--- Format the colorful header banner
---@param resp NuntioStoredResponse
---@return string[]
local function format_header_banner(resp)
  local status_sym = (resp.status >= 200 and resp.status < 300) and "✔"
    or (resp.status >= 300 and resp.status < 400) and "󰁔"
    or (resp.status >= 400 and resp.status < 500) and "󰅚"
    or "󰚌"

  local size_b = resp.stats and resp.stats.size_download or (resp.body and #resp.body or 0)
  local size_str = size_b < 1024 and string.format("%d B", size_b) or string.format("%.1f KB", size_b / 1024)

  local chain_badge = ""
  if resp.chain and resp.chain.total and resp.chain.total > 1 then
    chain_badge = string.format("   󰌷 Chain [%d/%d]", resp.chain.step or 1, resp.chain.total)
  end

  local hist_badge = string.format("   󰋚 History [%d/%d]", M.history_idx, #Store.history)
  local env_badge = resp.env and string.format("   󰏚 env: %s", resp.env) or ""

  local line1 = string.format(" 󰖟 %s  %s", resp.method, resp.url)
  local line2 = " ══════════════════════════════════════════════════════════════════════════════════"
  local line3 = string.format("  %s %d %s   ⏱ %.1fms   📦 %s%s%s%s",
    status_sym, resp.status, resp.status_text or "", resp.time or 0, size_str, chain_badge, hist_badge, env_badge)
  local line4 = " ──────────────────────────────────────────────────────────────────────────────────"

  return { line1, line2, line3, line4, "" }
end

--- Apply extmark highlights to the header banner
---@param buf integer
---@param resp NuntioStoredResponse
local function apply_banner_highlights(buf, resp)
  local ns = Highlights.get_namespace()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, 5)

  local line0 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  local method_hl = Highlights.get_method_hl(resp.method)
  local m_start, m_end = line0:find(resp.method)
  if m_start then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, m_start - 1, {
      end_col = m_end,
      hl_group = method_hl,
    })
  end

  local url_start, url_end = line0:find("https?://[^%s]+")
  if url_start then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, url_start - 1, {
      end_col = url_end,
      hl_group = "NuntioBannerUrl",
    })
  end

  -- Line 1: Double divider
  local line1 = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] or ""
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, {
    end_col = #line1,
    hl_group = "NuntioBannerDoubleDivider",
  })

  -- Line 2: Badges
  local line2 = vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1] or ""
  local s_start, s_end = line2:find(tostring(resp.status))
  if s_start then
    local status_sym_start = math.max(0, s_start - 3)
    local status_end = s_end + (resp.status_text and #resp.status_text + 1 or 0)
    vim.api.nvim_buf_set_extmark(buf, ns, 2, status_sym_start, {
      end_col = math.min(#line2, status_end),
      hl_group = Highlights.get_status_hl(resp.status),
    })
  end

  local lat_start, lat_end = line2:find("⏱%s*[%d%.]+ms")
  if lat_start then
    vim.api.nvim_buf_set_extmark(buf, ns, 2, lat_start - 1, {
      end_col = math.min(#line2, lat_end),
      hl_group = Highlights.get_latency_hl(resp.time),
    })
  end

  local size_start, size_end = line2:find("📦%s*[%d%.]+%s*[KB]+")
  if size_start then
    vim.api.nvim_buf_set_extmark(buf, ns, 2, size_start - 1, {
      end_col = math.min(#line2, size_end),
      hl_group = "NuntioBadge",
    })
  end

  local chain_start, chain_end = line2:find("󰌷%s*Chain%s*%[[%d%/]+%]")
  if chain_start then
    vim.api.nvim_buf_set_extmark(buf, ns, 2, chain_start - 1, {
      end_col = math.min(#line2, chain_end),
      hl_group = "NuntioBadgePurple",
    })
  end

  local hist_start, hist_end = line2:find("󰋚%s*History%s*%[[%d%/]+%]")
  if hist_start then
    vim.api.nvim_buf_set_extmark(buf, ns, 2, hist_start - 1, {
      end_col = math.min(#line2, hist_end),
      hl_group = "NuntioBadgeBlue",
    })
  end

  local env_start, env_end = line2:find("󰏚%s*env:%s*[%w_%-]+")
  if env_start then
    vim.api.nvim_buf_set_extmark(buf, ns, 2, env_start - 1, {
      end_col = math.min(#line2, env_end),
      hl_group = "NuntioBadgeGreen",
    })
  end

  -- Line 3: Single divider
  local line3 = vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1] or ""
  vim.api.nvim_buf_set_extmark(buf, ns, 3, 0, {
    end_col = #line3,
    hl_group = "NuntioBannerDivider",
  })
end

--- Get or create the response buffer
---@return integer
local function ensure_buffer()
  Highlights.setup()
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    M.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.bufnr })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = M.bufnr })
    vim.api.nvim_set_option_value("swapfile", false, { buf = M.bufnr })
    pcall(vim.api.nvim_buf_set_name, M.bufnr, "nuntio://response")
    M.setup_keymaps(M.bufnr)
  end
  return M.bufnr
end

--- Open or reuse window for the buffer
---@return integer winid
local function open_window()
  local buf = ensure_buffer()
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_win_set_buf(M.winid, buf)
    return M.winid
  end

  local cfg = Config.get().ui
  local mode = cfg.display_mode or "split"

  if mode == "float" then
    local width = math.floor(vim.o.columns * (cfg.width or 0.5))
    local height = math.floor(vim.o.lines * (cfg.height or 0.5))
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    M.winid = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      border = "rounded",
      title = " 󰖟 HTTP Response ",
      title_pos = "center",
    })
  else
    local dir = cfg.split_direction or "right"
    if dir == "right" then
      local width = math.floor(vim.o.columns * (cfg.width or 0.45))
      vim.cmd("botright vsplit")
      vim.cmd(string.format("vertical resize %d", width))
    elseif dir == "left" then
      local width = math.floor(vim.o.columns * (cfg.width or 0.45))
      vim.cmd("topleft vsplit")
      vim.cmd(string.format("vertical resize %d", width))
    elseif dir == "above" then
      local height = math.floor(vim.o.lines * (cfg.height or 0.4))
      vim.cmd("topleft split")
      vim.cmd(string.format("resize %d", height))
    else
      local height = math.floor(vim.o.lines * (cfg.height or 0.4))
      vim.cmd("botright split")
      vim.cmd(string.format("resize %d", height))
    end
    M.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.winid, buf)
  end

  vim.api.nvim_set_option_value("wrap", false, { win = M.winid })
  vim.api.nvim_set_option_value("number", false, { win = M.winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.winid })
  vim.api.nvim_set_option_value("foldmethod", "indent", { win = M.winid })
  vim.api.nvim_set_option_value("foldlevel", 99, { win = M.winid })
  vim.api.nvim_set_option_value("foldenable", true, { win = M.winid })

  return M.winid
end

--- Render content for active view into buffer
---@param resp NuntioStoredResponse
local function render_view(resp)
  local buf = ensure_buffer()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

  local content_lines = {}
  local ft = "text"

  if M.active_view == "body" then
    local Filter = require("nuntio.ui.filter")
    if Filter.active_filter and Filter.active_filter ~= "" then
      local ok, res = Filter.eval(resp.body, Filter.active_filter)
      if ok then
        ft = "json"
        content_lines = Utils.split_lines(res)
      else
        ft = detect_filetype(resp.headers, resp.body)
        local formatted = (ft == "json") and format_body(resp.body) or resp.body
        content_lines = Utils.split_lines(formatted)
      end
    else
      ft = detect_filetype(resp.headers, resp.body)
      local formatted = (ft == "json") and format_body(resp.body) or resp.body
      content_lines = Utils.split_lines(formatted)
    end
    if #content_lines == 0 then
      ft = "text"
      content_lines = {
        string.format("/* Empty response body (HTTP %d %s) */", resp.status, resp.status_text or "OK"),
        "/* Switch to Headers tab [ ] ] to inspect response headers */",
      }
    end
  elseif M.active_view == "headers" then
    ft = "http"
    content_lines = Utils.split_lines(resp.raw_headers)
  elseif M.active_view == "headers_body" then
    ft = "http"
    table.insert(content_lines, string.format("### %s %s", resp.method, resp.url))
    table.insert(content_lines, string.format("HTTP/1.1 %d %s", resp.status, resp.status_text or "OK"))
    for _, l in ipairs(Utils.split_lines(resp.raw_headers)) do
      if not l:match("^HTTP/") then
        table.insert(content_lines, l)
      end
    end
    table.insert(content_lines, "")
    for _, l in ipairs(Utils.split_lines(resp.body)) do
      table.insert(content_lines, l)
    end
  elseif M.active_view == "chain" then
    ft = "text"
    content_lines = format_chain(resp)
  elseif M.active_view == "verbose" then
    ft = "text"
    content_lines = Utils.split_lines(resp.verbose or "")
  elseif M.active_view == "tests" then
    ft = "text"
    content_lines = format_tests(resp)
  elseif M.active_view == "stats" then
    ft = "text"
    content_lines = format_stats(resp)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
  vim.api.nvim_buf_clear_namespace(buf, tests_ns, 0, -1)
  if M.active_view == "tests" then
    apply_tests_highlights(buf, content_lines)
  end
  vim.api.nvim_set_option_value("filetype", ft, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Update winbar with responsive tabs and live metrics
  if Config.get().ui.winbar and M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_set_option_value("winbar", Winbar.render(M.active_view, resp), { win = M.winid })
  end
end

--- Display response in UI
---@param response NuntioStoredResponse
function M.display(response)
  M.history_idx = #Store.history
  if not M.active_view then
    if (response.method == "HEAD" or #response.body == 0) and (Config.get().ui.default_view == "body" or not Config.get().ui.default_view) then
      M.active_view = "headers"
    else
      M.active_view = Config.get().ui.default_view or "body"
    end
  elseif (response.method == "HEAD" or #response.body == 0) and M.active_view == "body" then
    M.active_view = "headers"
  end
  open_window()
  render_view(response)
end

--- Switch active pane view
---@param view_id string
function M.switch_view(view_id)
  M.active_view = view_id
  local resp = Store.history[M.history_idx] or Store.get_last_response()
  if resp then
    render_view(resp)
  end
end

--- Get available view tabs for response
---@param resp? NuntioStoredResponse
---@return string[]
function M.get_available_views(resp)
  local views = { "body", "headers", "headers_body" }
  if resp and ((resp.chain and resp.chain.total and resp.chain.total > 1) or (resp.exported_vars and next(resp.exported_vars) ~= nil)) then
    table.insert(views, "chain")
  end
  if resp and resp.assertions and resp.assertions.total > 0 then
    table.insert(views, "tests")
  end
  table.insert(views, "stats")
  table.insert(views, "verbose")
  return views
end

--- Cycle to next view tab (to the right: ])
function M.next_view()
  local resp = Store.history[M.history_idx] or Store.get_last_response()
  local views = M.get_available_views(resp)
  local curr_idx = 1
  for i, v in ipairs(views) do
    if v == M.active_view then
      curr_idx = i
      break
    end
  end
  local next_idx = (curr_idx % #views) + 1
  M.switch_view(views[next_idx])
end

--- Cycle to previous view tab (to the left: [)
function M.prev_view()
  local resp = Store.history[M.history_idx] or Store.get_last_response()
  local views = M.get_available_views(resp)
  local curr_idx = 1
  for i, v in ipairs(views) do
    if v == M.active_view then
      curr_idx = i
      break
    end
  end
  local prev_idx = ((curr_idx - 2 + #views) % #views) + 1
  M.switch_view(views[prev_idx])
end

--- Open interactive history picker
function M.open_history_picker()
  History.open()
end

--- Diff current response against previous
function M.diff_previous()
  History.diff_previous()
end

--- Navigate history
---@param delta integer
function M.nav_history(delta)
  local count = #Store.history
  if count == 0 then return end
  local target = math.max(1, math.min(count, M.history_idx + delta))
  M.history_idx = target
  local resp = Store.history[M.history_idx]
  if resp then
    render_view(resp)
  end
end

--- Toggle view between body and headers
function M.toggle_view()
  if not M.winid or not vim.api.nvim_win_is_valid(M.winid) then
    local resp = Store.get_last_response()
    if resp then
      M.display(resp)
    end
    return
  end

  if M.active_view == "body" then
    M.switch_view("headers")
  else
    M.switch_view("body")
  end
end

--- Close response window
function M.close()
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    pcall(vim.api.nvim_win_close, M.winid, true)
    M.winid = nil
  end
end

--- Setup buffer local keymaps
---@param buf integer
function M.setup_keymaps(buf)
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  map("q", function() M.close() end)
  map("<Esc>", function() M.close() end)

  -- Quick switch tabs: [ left, ] right
  map("]", function() M.next_view() end)
  map("[", function() M.prev_view() end)
  map("<Tab>", function() M.next_view() end)
  map("<S-Tab>", function() M.prev_view() end)

  -- Direct jump shortcuts
  map("b", function() M.switch_view("body") end)
  map("B", function() M.switch_view("body") end)
  map("h", function() M.switch_view("headers") end)
  map("a", function() M.switch_view("headers_body") end)
  map("c", function() M.switch_view("chain") end)
  map("t", function() M.switch_view("tests") end)
  map("s", function() M.switch_view("stats") end)
  map("v", function() M.switch_view("verbose") end)
  map("H", function() M.open_history_picker() end)
  map("D", function() M.diff_previous() end)
  map("F", function() require("nuntio.ui.filter").open() end)
  map("f", function() require("nuntio.ui.filter").open() end)
  map("X", function() require("nuntio.ui.filter").clear() end)

  -- History previous/next: { / } or <C-p> / <C-n>
  map("}", function() M.nav_history(1) end)
  map("{", function() M.nav_history(-1) end)
  map("<C-n>", function() M.nav_history(1) end)
  map("<C-p>", function() M.nav_history(-1) end)

  -- Yank body
  map("y", function()
    local resp = Store.history[M.history_idx] or Store.get_last_response()
    if resp and resp.body then
      vim.fn.setreg("+", resp.body)
      vim.notify("nuntio: response body copied to clipboard!", vim.log.levels.INFO)
    end
  end)

  -- Yank headers
  map("yh", function()
    local resp = Store.history[M.history_idx] or Store.get_last_response()
    if resp and resp.raw_headers then
      vim.fn.setreg("+", resp.raw_headers)
      vim.notify("nuntio: response headers copied to clipboard!", vim.log.levels.INFO)
    end
  end)

  -- Yank as cURL
  map("Y", function()
    local resp = Store.history[M.history_idx] or Store.get_last_response()
    if resp then
      local parts = { "curl", "-X", resp.method, string.format("%q", resp.url) }
      if resp.headers then
        for k, v in pairs(resp.headers) do
          table.insert(parts, "-H")
          table.insert(parts, string.format("%q", k .. ": " .. v))
        end
      end
      if resp.body and resp.body ~= "" then
        table.insert(parts, "--data-raw")
        table.insert(parts, string.format("%q", resp.body))
      end
      local curl_cmd = table.concat(parts, " ")
      vim.fn.setreg("+", curl_cmd)
      vim.notify("nuntio: cURL command copied to clipboard!", vim.log.levels.INFO)
    end
  end)

  -- Replay
  map("r", function()
    require("nuntio").replay()
  end)
end

return M
