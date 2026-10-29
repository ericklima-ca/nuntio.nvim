local Config = require("nuntio.config")
local CurlImport = require("nuntio.parser.curl_import")
local Document = require("nuntio.parser.document")
local Pickers = require("nuntio.ui.pickers")
local Request = require("nuntio.request")
local Runner = require("nuntio.runner")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")
local View = require("nuntio.ui.view")

local M = {}

--- Setup nuntio
---@param opts? NuntioConfig
function M.setup(opts)
  Config.setup(opts)
  require("nuntio.ui.highlights").setup()
  require("nuntio.ui.dividers").setup()
  require("nuntio.lsp").setup()
end

--- Get document lines from current buffer
---@param bufnr? integer
---@return string[]
local function get_buffer_lines(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Parse current buffer into blocks and shared block
---@param bufnr? integer
---@return NuntioBlock[] blocks, table<string, string> doc_vars, NuntioBlock|nil shared_block, NuntioBlock[] plans
local function parse_current(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = get_buffer_lines(bufnr)
  local blocks, doc_vars, plans = Document.parse_document(lines)

  local shared_block = nil
  local runnable_blocks = {}

  for _, b in ipairs(blocks) do
    if b.is_shared then
      shared_block = b
    else
      table.insert(runnable_blocks, b)
    end
  end

  return runnable_blocks, doc_vars, shared_block, plans
end

--- Load plan block (`# @scenario` / `# @load-mix`) containing a line, if any
---@param plans NuntioBlock[]
---@param lnum integer
---@return NuntioBlock|nil
local function plan_at_line(plans, lnum)
  for _, p in ipairs(plans) do
    if lnum >= p.start_line and lnum <= p.end_line then
      return p
    end
  end
  return nil
end

--- Run request at cursor or visual selection
function M.run()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer_dir = vim.fn.expand("%:p:h")
  if not buffer_dir or buffer_dir == "" then buffer_dir = vim.uv.cwd() end

  -- Check if visual mode
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.api.nvim_input("<Esc>")
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_lnum = start_pos[2]
    local end_lnum = end_pos[2]
    if start_lnum > end_lnum then
      start_lnum, end_lnum = end_lnum, start_lnum
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)
    local blocks, doc_vars = Document.parse_document(lines)
    if #blocks == 0 then
      vim.notify("nuntio: no valid request found in selection", vim.log.levels.WARN)
      return
    end
    -- Offset line numbers
    for _, b in ipairs(blocks) do
      b.start_line = b.start_line + start_lnum - 1
      b.end_line = b.end_line + start_lnum - 1
      b.icon_line = b.icon_line + start_lnum - 1
    end
    Runner.run_queue(blocks, doc_vars, bufnr, buffer_dir, nil)
    return
  end

  -- Normal mode: run request at cursor
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local blocks, doc_vars, shared_block, plans = parse_current(bufnr)

  if plan_at_line(plans, lnum) then
    vim.notify("nuntio: this is a load scenario block; run it with :Nuntio load", vim.log.levels.INFO)
    return
  end

  local target_block = Document.get_block_at_line(blocks, lnum)
  if not target_block then
    if shared_block and lnum >= shared_block.start_line and lnum <= shared_block.end_line then
      vim.notify("nuntio: '### Shared' is a configuration block; its headers and variables are automatically applied to all requests in this file", vim.log.levels.INFO)
      return
    end
    vim.notify("nuntio: no request found at cursor", vim.log.levels.WARN)
    return
  end

  Runner.run_block(target_block, doc_vars, bufnr, buffer_dir, shared_block, nil, blocks)
end

--- Run all requests in current buffer sequentially
function M.run_all()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer_dir = vim.fn.expand("%:p:h")
  if not buffer_dir or buffer_dir == "" then buffer_dir = vim.uv.cwd() end

  local blocks, doc_vars, shared_block = parse_current(bufnr)
  if #blocks == 0 then
    vim.notify("nuntio: no requests found in buffer", vim.log.levels.WARN)
    return
  end

  Runner.run_queue(blocks, doc_vars, bufnr, buffer_dir, shared_block, function()
    vim.notify("nuntio: finished running all requests", vim.log.levels.INFO)
  end)
end

--- Replay last executed request
function M.replay()
  local last = Store.last_request
  if not last then
    vim.notify("nuntio: no previous request to replay", vim.log.levels.WARN)
    return
  end

  Runner.run_block(last.block, last.doc_vars, last.bufnr, last.buffer_dir, last.shared_block)
end

--- Inspect / preview resolved request at cursor
function M.inspect()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer_dir = vim.fn.expand("%:p:h")
  if not buffer_dir or buffer_dir == "" then buffer_dir = vim.uv.cwd() end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local blocks, doc_vars, shared_block = parse_current(bufnr)
  local block = Document.get_block_at_line(blocks, lnum)
  if not block then
    vim.notify("nuntio: no request found at cursor", vim.log.levels.WARN)
    return
  end

  local resolved = Request.resolve(block, doc_vars, buffer_dir, bufnr, shared_block)
  local curl_str = CurlImport.to_curl_string(resolved)

  local lines = {}
  table.insert(lines, "─── Resolved Request Preview ────────────────────────────────")
  table.insert(lines, string.format("%s %s %s", resolved.method, resolved.url, resolved.http_version or "HTTP/1.1"))
  for k, v in pairs(resolved.headers) do
    table.insert(lines, string.format("%s: %s", k, v))
  end
  if resolved.body and resolved.body ~= "" then
    table.insert(lines, "")
    for _, l in ipairs(Utils.split_lines(resolved.body)) do
      table.insert(lines, l)
    end
  end
  table.insert(lines, "")
  table.insert(lines, "─── Equivalent cURL Command ──────────────────────────────────")
  table.insert(lines, curl_str)

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("filetype", "http", { buf = float_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = float_buf })

  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
  local win = vim.api.nvim_open_win(float_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = " Request Inspection ",
    title_pos = "center",
  })
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = float_buf, silent = true })
  vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = float_buf, silent = true })
end

--- Copy request at cursor as curl command
function M.copy_as_curl()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer_dir = vim.fn.expand("%:p:h")
  if not buffer_dir or buffer_dir == "" then buffer_dir = vim.uv.cwd() end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local blocks, doc_vars, shared_block = parse_current(bufnr)
  local block = Document.get_block_at_line(blocks, lnum)
  if not block then
    vim.notify("nuntio: no request found at cursor", vim.log.levels.WARN)
    return
  end

  local resolved = Request.resolve(block, doc_vars, buffer_dir, bufnr, shared_block)
  local curl_str = CurlImport.to_curl_string(resolved)
  vim.fn.setreg("+", curl_str)
  vim.fn.setreg('"', curl_str)
  vim.notify("Copied as cURL command to clipboard!", vim.log.levels.INFO)
end

--- Load test the request at cursor
--- Arguments override `# @load`: requests=N concurrency=C duration=30s timeout=5000
---@param ... string
function M.load(...)
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer_dir = vim.fn.expand("%:p:h")
  if not buffer_dir or buffer_dir == "" then buffer_dir = vim.uv.cwd() end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local blocks, doc_vars, shared_block, plans = parse_current(bufnr)
  local block = plan_at_line(plans, lnum) or Document.get_block_at_line(blocks, lnum)
  if not block then
    vim.notify("nuntio: no request found at cursor", vim.log.levels.WARN)
    return
  end

  require("nuntio.ui.load_view").start({
    block = block,
    blocks = blocks,
    plans = plans,
    doc_vars = doc_vars,
    bufnr = bufnr,
    buffer_dir = buffer_dir,
    shared_block = shared_block,
    args = { ... },
  })
end

--- Cancel a running load test (keeps partial results), or in-flight requests
function M.cancel()
  if require("nuntio.load").cancel() then
    return
  end
  require("nuntio.transport.curl").cancel_all()
  vim.notify("nuntio: cancelled in-flight requests", vim.log.levels.INFO)
end

--- Convert clipboard or input curl command into .http and insert at cursor
function M.from_curl()
  local clipboard = vim.fn.getreg("+")
  local input = nil
  if clipboard and clipboard:match("^curl%s") then
    input = clipboard
  else
    input = vim.fn.input("Paste cURL command: ")
  end

  if not input or input == "" then return end
  local http_text = CurlImport.to_http(input)
  if http_text == "" then
    vim.notify("nuntio: could not parse curl command", vim.log.levels.ERROR)
    return
  end

  local lines = Utils.split_lines(http_text)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, row, row, false, lines)
  vim.notify("Inserted HTTP request from cURL!", vim.log.levels.INFO)
end

--- Select environment
function M.select_env()
  Pickers.select_env()
end

--- Find and jump to request block (Fuzzy Request Picker)
---@param scope_or_opts? string|table "buffer"|"workspace" or configuration options
function M.find_request(scope_or_opts)
  Pickers.find(scope_or_opts)
end

M.find = M.find_request

--- Jump to next request block
function M.jump_next()
  local blocks, _ = parse_current()
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  for _, b in ipairs(blocks) do
    if b.start_line > cur_line then
      vim.api.nvim_win_set_cursor(0, { b.start_line, 0 })
      return
    end
  end
  vim.notify("nuntio: no next request", vim.log.levels.INFO)
end

--- Jump to previous request block
function M.jump_prev()
  local blocks, _ = parse_current()
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local prev = nil
  for _, b in ipairs(blocks) do
    if b.start_line < cur_line then
      prev = b
    else
      break
    end
  end
  if prev then
    vim.api.nvim_win_set_cursor(0, { prev.start_line, 0 })
  else
    vim.notify("nuntio: no previous request", vim.log.levels.INFO)
  end
end

--- Open scratchpad
function M.scratchpad()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_option_value("filetype", "http", { buf = buf })
  local template = {
    "@baseUrl = https://httpbin.org",
    "",
    "### 1. Get JSON sample",
    "# @name sample_get",
    "GET {{baseUrl}}/json",
    "Accept: application/json",
    "",
    "### 2. Post data referencing previous response",
    "# @env-json-key author = $.slideshow.author",
    "POST {{baseUrl}}/post",
    "Content-Type: application/json",
    "",
    "{",
    '  "message": "Hello from nuntio.nvim!",',
    '  "timestamp": "{{$isoTimestamp}}",',
    '  "uuid": "{{$uuid}}"',
    "}",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, template)
  vim.api.nvim_set_current_buf(buf)
end

--- Inspect or manage cookies in cookie jar
function M.cookies()
  local CookiesUI = require("nuntio.ui.cookies")
  CookiesUI.open()
end

--- Get currently active environment for buffer (useful for statuslines)
---@param bufnr? integer
---@return string
function M.get_selected_env(bufnr)
  return Store.get_selected_env(bufnr or 0)
end

--- Toggle / close response window
function M.close()
  View.close()
end

--- Toggle view between headers and body
function M.toggle_view()
  View.toggle_view()
end

--- Open interactive history picker
function M.history()
  local History = require("nuntio.ui.history")
  History.open()
end

--- Diff current response against previous
function M.history_diff()
  local History = require("nuntio.ui.history")
  History.diff_previous()
end

--- Clear response history
function M.clear_history()
  Store.clear_history()
  vim.notify("nuntio: cleared response history", vim.log.levels.INFO)
end

--- Open interactive Live Filter (JQ / JSONPath) for active response
function M.filter()
  require("nuntio.ui.filter").open()
end

--- Clear active response filter
function M.filter_clear()
  require("nuntio.ui.filter").clear()
end

--- Format current .http document
---@param bufnr? integer
function M.format(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local Formatter = require("nuntio.lsp.formatter")
  local edits = Formatter.format_document(bufnr)
  if edits and #edits > 0 then
    local new_lines = vim.split(edits[1].newText, "\n")
    -- pop trailing empty element if split created one
    if #new_lines > 0 and new_lines[#new_lines] == "" then
      table.remove(new_lines, #new_lines)
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    vim.notify("nuntio: formatted document", vim.log.levels.INFO)
  end
end

--- Restart in-process LSP server
function M.lsp_restart()
  require("nuntio.lsp").restart()
end

return M
