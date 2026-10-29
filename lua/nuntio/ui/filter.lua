local Config = require("nuntio.config")
local JSONPath = require("nuntio.parser.jsonpath")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")

local M = {}

--- Active filter query for the current response view (or nil)
---@type string|nil
M.active_filter = nil

--- Stored original un-filtered body
---@type string|nil
M.original_body = nil

--- Filter prompt window and buffer
---@type integer|nil
M.filter_winid = nil
---@type integer|nil
M.filter_bufnr = nil

--- Namespace for filter prompt virtual text
local ns_id = vim.api.nvim_create_namespace("nuntio_filter_prompt")

--- Evaluate a JQ or JSONPath query against a raw body string
---@param data_str string Raw response body (typically JSON)
---@param query string Filter expression (e.g. "$.items[0]", ".slideshow.title", ".[] | .id")
---@return boolean ok Whether evaluation succeeded with results
---@return string result Formatted output string or error message
function M.eval(data_str, query)
  if not query or query == "" then
    return true, data_str
  end
  query = vim.trim(query)

  -- 1. Try JQ if available and query uses jq syntax (.prop, pipe |, array iterator [])
  local is_jq_syntax = query:find("|") ~= nil
    or query:find("%[%]") ~= nil
    or query:find("{") ~= nil
    or (query:sub(1, 1) == "." and not query:sub(1, 2):match("^%$.") and not query:match("^%.%w+$"))

  if is_jq_syntax and vim.fn.executable("jq") == 1 then
    local res = vim.fn.system({ "jq", query }, data_str)
    if vim.v.shell_error == 0 and res ~= "" then
      return true, res
    end
  end

  -- 2. Try native pure-Lua JSONPath engine
  local jp_query = query
  if jp_query:sub(1, 1) == "." and not jp_query:sub(1, 2):match("^%$.") then
    jp_query = "$" .. jp_query
  end

  local val = JSONPath.extract(data_str, jp_query)
  if val ~= nil then
    if type(val) == "table" then
      return true, Utils.json_encode(val, true)
    else
      return true, tostring(val)
    end
  end

  -- 3. If native JSONPath had no match, fallback to CLI jq if executable
  if vim.fn.executable("jq") == 1 then
    local jq_query = query
    if jq_query:sub(1, 2) == "$." then
      jq_query = "." .. jq_query:sub(3)
    elseif jq_query:sub(1, 1) == "$" then
      jq_query = "." .. jq_query:sub(2)
    end
    local res = vim.fn.system({ "jq", jq_query }, data_str)
    if vim.v.shell_error == 0 and res ~= "" and vim.trim(res) ~= "null" then
      return true, res
    end
  end

  return false, "No matches for query: " .. query
end

--- Close filter prompt window
local function close_prompt()
  if M.filter_winid and vim.api.nvim_win_is_valid(M.filter_winid) then
    pcall(vim.api.nvim_win_close, M.filter_winid, true)
    M.filter_winid = nil
  end
  if M.filter_bufnr and vim.api.nvim_buf_is_valid(M.filter_bufnr) then
    pcall(vim.api.nvim_buf_delete, M.filter_bufnr, { force = true })
    M.filter_bufnr = nil
  end
  vim.cmd("stopinsert")
end

--- Update response buffer view with text
---@param text string
---@param is_filtered boolean
local function update_response_buffer(text, is_filtered)
  local View = require("nuntio.ui.view")
  local Winbar = require("nuntio.ui.winbar")
  if not View.bufnr or not vim.api.nvim_buf_is_valid(View.bufnr) then
    return
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = View.bufnr })
  local lines = Utils.split_lines(text)
  vim.api.nvim_buf_set_lines(View.bufnr, 0, -1, false, lines)

  -- Infer filetype: if looks like JSON, highlight as json
  local trimmed = vim.trim(text)
  if (trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}")
    or (trimmed:sub(1, 1) == "[" and trimmed:sub(-1) == "]")
    or is_filtered
  then
    vim.api.nvim_set_option_value("filetype", "json", { buf = View.bufnr })
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = View.bufnr })

  -- Refresh winbar
  local resp = Store.history[View.history_idx] or Store.get_last_response()
  if resp and View.winid and vim.api.nvim_win_is_valid(View.winid) then
    vim.api.nvim_set_option_value("winbar", Winbar.render(View.active_view, resp), { win = View.winid })
  end
end

--- Open interactive Live Filter prompt
function M.open()
  local View = require("nuntio.ui.view")
  if not View.winid or not vim.api.nvim_win_is_valid(View.winid) then
    vim.notify("nuntio: no active response window open to filter", vim.log.levels.WARN)
    return
  end

  local resp = Store.history[View.history_idx] or Store.get_last_response()
  if not resp or not resp.body or resp.body == "" then
    vim.notify("nuntio: current response has empty body", vim.log.levels.WARN)
    return
  end

  -- Switch to body view if on another tab
  if View.active_view ~= "body" then
    View.switch_view("body")
  end

  M.original_body = resp.body

  -- Calculate geometry relative to View.winid
  local win_w = vim.api.nvim_win_get_width(View.winid)
  local win_h = vim.api.nvim_win_get_height(View.winid)

  local width = math.max(30, win_w - 6)
  local row = math.max(0, win_h - 4)
  local col = 2

  M.filter_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.filter_bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = M.filter_bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = M.filter_bufnr })

  -- If filter was already active, pre-fill with it
  local initial_text = M.active_filter or ""
  vim.api.nvim_buf_set_lines(M.filter_bufnr, 0, -1, false, { initial_text })

  M.filter_winid = vim.api.nvim_open_win(M.filter_bufnr, true, {
    relative = "win",
    win = View.winid,
    row = row,
    col = col,
    width = width,
    height = 1,
    border = "rounded",
    title = " 󰈲 Live Filter (JQ / JSONPath) ",
    title_pos = "left",
    footer = " [<CR> Apply │ <Esc> Cancel │ <C-y> Copy Path │ <C-r> Reset] ",
    footer_pos = "right",
  })

  vim.api.nvim_set_option_value("wrap", false, { win = M.filter_winid })
  vim.api.nvim_set_option_value("number", false, { win = M.filter_winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.filter_winid })

  -- Set prompt icon virtual text
  vim.api.nvim_buf_set_extmark(M.filter_bufnr, ns_id, 0, 0, {
    virt_text = { { "󰈲 ", "NuntioBadgeAmber" } },
    virt_text_pos = "inline",
  })

  -- Debounced live filtering function
  local timer = nil
  local function on_change()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end

    timer = vim.uv.new_timer()
    timer:start(30, 0, vim.schedule_wrap(function()
      if not M.filter_bufnr or not vim.api.nvim_buf_is_valid(M.filter_bufnr) then
        return
      end

      local query = vim.api.nvim_buf_get_lines(M.filter_bufnr, 0, 1, false)[1] or ""
      vim.api.nvim_buf_clear_namespace(M.filter_bufnr, ns_id, 0, -1)

      -- Re-apply inline prompt icon
      vim.api.nvim_buf_set_extmark(M.filter_bufnr, ns_id, 0, 0, {
        virt_text = { { "󰈲 ", "NuntioBadgeAmber" } },
        virt_text_pos = "inline",
      })

      if query == "" then
        update_response_buffer(M.original_body, false)
        return
      end

      local ok, res = M.eval(M.original_body, query)
      if ok then
        update_response_buffer(res, true)
        -- Show success virtual hint at right of prompt
        vim.api.nvim_buf_set_extmark(M.filter_bufnr, ns_id, 0, 0, {
          virt_text = { { " ✔ match", "NuntioStatus2xx" } },
          virt_text_pos = "eol",
        })
      else
        -- Don't destroy preview while user is actively typing partial syntax; show subtle hint
        vim.api.nvim_buf_set_extmark(M.filter_bufnr, ns_id, 0, 0, {
          virt_text = { { " (evaluating...)", "Comment" } },
          virt_text_pos = "eol",
        })
      end
    end))
  end

  -- Autocmds for live updates
  local group = vim.api.nvim_create_augroup("nuntio_live_filter", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = group,
    buffer = M.filter_bufnr,
    callback = on_change,
  })

  -- Keybindings for filter prompt
  local function map(keys, fn)
    for _, k in ipairs(type(keys) == "table" and keys or { keys }) do
      vim.keymap.set({ "n", "i" }, k, fn, { buffer = M.filter_bufnr, silent = true, nowait = true })
    end
  end

  -- <CR>: Apply filter
  map("<CR>", function()
    local query = vim.api.nvim_buf_get_lines(M.filter_bufnr, 0, 1, false)[1] or ""
    query = vim.trim(query)
    close_prompt()

    if query == "" then
      M.clear()
    else
      M.active_filter = query
      local ok, res = M.eval(M.original_body, query)
      if ok then
        update_response_buffer(res, true)
        vim.notify(string.format("nuntio: applied filter: %s", query), vim.log.levels.INFO)
      else
        vim.notify(string.format("nuntio: no matches for: %s", query), vim.log.levels.WARN)
        update_response_buffer(M.original_body, false)
        M.active_filter = nil
      end
    end
  end)

  -- <Esc> / <C-c>: Cancel and restore original
  map({ "<Esc>", "<C-c>" }, function()
    close_prompt()
    if M.active_filter then
      local ok, res = M.eval(M.original_body, M.active_filter)
      update_response_buffer(ok and res or M.original_body, ok)
    else
      update_response_buffer(M.original_body, false)
    end
  end)

  -- <C-y>: Copy query path to clipboard for chaining
  map("<C-y>", function()
    local query = vim.api.nvim_buf_get_lines(M.filter_bufnr, 0, 1, false)[1] or ""
    query = vim.trim(query)
    if query ~= "" then
      vim.fn.setreg("+", query)
      vim.notify(string.format("nuntio: copied %q to clipboard (ready for chaining!)", query), vim.log.levels.INFO)
    end
  end)

  -- <C-r>: Reset filter to empty
  map("<C-r>", function()
    vim.api.nvim_buf_set_lines(M.filter_bufnr, 0, -1, false, { "" })
    M.active_filter = nil
    update_response_buffer(M.original_body, false)
    on_change()
  end)

  -- Enter insert mode at end of line
  vim.cmd("startinsert!")
end

--- Clear active filter and restore full response body
function M.clear()
  M.active_filter = nil
  local View = require("nuntio.ui.view")
  local resp = Store.history[View.history_idx] or Store.get_last_response()
  if resp and resp.body then
    update_response_buffer(resp.body, false)
    vim.notify("nuntio: filter cleared", vim.log.levels.INFO)
  end
end

return M
