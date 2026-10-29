local Highlights = require("nuntio.ui.highlights")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")

local M = {}

--- Format a single response for display in history list
---@param resp NuntioStoredResponse
---@param idx integer
---@param is_current boolean
---@return string
local function format_history_item(resp, idx, is_current)
  local status_sym = (resp.status >= 200 and resp.status < 300) and "✔"
    or (resp.status >= 300 and resp.status < 400) and "󰁔"
    or (resp.status >= 400 and resp.status < 500) and "󰅚"
    or "󰚌"

  local name_str = (resp.name and resp.name ~= "") and (" [" .. resp.name .. "]") or ""
  local current_marker = is_current and " ◀ current" or ""
  local time_str = os.date("%H:%M:%S", resp.timestamp or os.time())

  -- Shorten URL if too long
  local url = resp.url
  if #url > 50 then
    url = url:sub(1, 47) .. "..."
  end

  return string.format("[%d] %s %-3d %-6s %-45s%s  ⏱ %4.0fms  %s%s",
    idx,
    status_sym,
    resp.status,
    resp.method,
    url,
    name_str,
    resp.time or 0,
    time_str,
    current_marker
  )
end

--- Open interactive history picker
---@param on_select? fun(selected: NuntioStoredResponse, idx: integer)
function M.open(on_select)
  local count = #Store.history
  if count == 0 then
    vim.notify("nuntio: history is empty", vim.log.levels.INFO)
    return
  end

  local View = require("nuntio.ui.view")
  local current_idx = View.history_idx or count

  -- List items in reverse chronological order (newest first)
  local items = {}
  local index_map = {}

  for i = count, 1, -1 do
    local resp = Store.history[i]
    local label = format_history_item(resp, i, i == current_idx)
    table.insert(items, label)
    table.insert(index_map, i)
  end

  vim.ui.select(items, {
    prompt = " 󰋚 Select HTTP Response History: ",
    format_item = function(item) return item end,
  }, function(choice, idx)
    if not choice or not idx then return end
    local target_idx = index_map[idx]
    local selected = Store.history[target_idx]
    if on_select then
      on_select(selected, target_idx)
    else
      View.history_idx = target_idx
      View.display(selected)
    end
  end)
end

--- Diff current response against previous response
function M.diff_previous()
  local View = require("nuntio.ui.view")
  local current_idx = View.history_idx or #Store.history
  if current_idx <= 1 or #Store.history < 2 then
    vim.notify("nuntio: need at least 2 responses in history to diff", vim.log.levels.WARN)
    return
  end

  local curr = Store.history[current_idx]
  local prev = Store.history[current_idx - 1]

  if not curr or not prev then return end

  -- Create scratch buffers for diff
  local buf_prev = vim.api.nvim_create_buf(false, true)
  local buf_curr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf_prev, 0, -1, false, Utils.split_lines(prev.body or ""))
  vim.api.nvim_buf_set_lines(buf_curr, 0, -1, false, Utils.split_lines(curr.body or ""))

  local name_prev = prev.name and ("#" .. prev.name) or (prev.method .. " " .. prev.url)
  local name_curr = curr.name and ("#" .. curr.name) or (curr.method .. " " .. curr.url)

  vim.api.nvim_buf_set_name(buf_prev, string.format("nuntio://history/[%d] %s", current_idx - 1, name_prev))
  vim.api.nvim_buf_set_name(buf_curr, string.format("nuntio://history/[%d] %s", current_idx, name_curr))

  -- Open split diff
  vim.cmd("tabnew")
  local win_prev = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win_prev, buf_prev)
  vim.cmd("diffthis")

  vim.cmd("vsplit")
  local win_curr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win_curr, buf_curr)
  vim.cmd("diffthis")

  local function close_diff()
    pcall(vim.cmd, "tabclose")
  end

  for _, b in ipairs({ buf_prev, buf_curr }) do
    vim.keymap.set("n", "q", close_diff, { buffer = b, silent = true })
    vim.keymap.set("n", "<Esc>", close_diff, { buffer = b, silent = true })
  end

  vim.notify(string.format("nuntio diff: comparing [%d] vs [%d]", current_idx - 1, current_idx), vim.log.levels.INFO)
end

return M
