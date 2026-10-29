local Curl = require("nuntio.transport.curl")
local Utils = require("nuntio.utils")

local M = {}

M.winid = nil
M.bufnr = nil

--- Render cookie lines for buffer
---@param jar_path string
---@param cookies table<string, table>
---@return string[]
local function render_lines(jar_path, cookies)
  local lines = {
    "# nuntio Session Cookie Jar",
    "# Path: " .. jar_path,
    "# Keymaps: [d] Clear cookies  [r] Reload  [e] Edit raw file  [q/Esc] Close",
    "",
  }

  local list = {}
  for name, c in pairs(cookies) do
    table.insert(list, {
      name = name,
      domain = c.domain or "",
      path = c.path or "",
      secure = c.secure and "true" or "false",
      expires = c.expires or "",
      value = c.value or "",
    })
  end

  if #list == 0 then
    table.insert(lines, "(Cookie jar is empty. Requests will automatically persist cookies here.)")
    return lines
  end

  -- Table header
  local fmt = "%-24s %-8s %-7s %-12s %-20s %s"
  table.insert(lines, string.format(fmt, "DOMAIN", "PATH", "SECURE", "EXPIRES", "NAME", "VALUE"))
  table.insert(lines, string.format(fmt, string.rep("-", 24), string.rep("-", 8), string.rep("-", 7), string.rep("-", 12), string.rep("-", 20), string.rep("-", 24)))

  for _, c in ipairs(list) do
    local exp_str = c.expires
    if tonumber(exp_str) and tonumber(exp_str) > 0 then
      exp_str = os.date("%Y-%m-%d", tonumber(exp_str))
    end
    table.insert(lines, string.format(fmt, c.domain, c.path, c.secure, exp_str, c.name, c.value))
  end

  return lines
end

--- Open or toggle the Cookie Jar manager floating window
function M.open()
  local jar_path = Curl.get_cookie_jar_path()

  -- If window already open, close it
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_win_close(M.winid, true)
    M.winid = nil
    return
  end

  local cookies = Curl.parse_cookie_file(jar_path)
  local lines = render_lines(jar_path, cookies)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("filetype", "nuntio_cookies", { buf = bufnr })

  local width = math.min(110, math.floor(vim.o.columns * 0.85))
  local height = math.min(20, math.max(8, #lines + 2))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Nuntio Cookies ",
    title_pos = "center",
  })

  M.winid = winid
  M.bufnr = bufnr

  local function reload()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local refreshed = Curl.parse_cookie_file(jar_path)
    local updated_lines = render_lines(jar_path, refreshed)
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, updated_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end

  map("q", function()
    if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
  end)
  map("<Esc>", function()
    if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
  end)
  map("r", reload)
  map("d", function()
    Utils.write_file(jar_path, "")
    reload()
    vim.notify("nuntio: cookie jar cleared", vim.log.levels.INFO)
  end)
  map("x", function()
    Utils.write_file(jar_path, "")
    reload()
    vim.notify("nuntio: cookie jar cleared", vim.log.levels.INFO)
  end)
  map("e", function()
    if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
    vim.cmd("edit " .. vim.fn.fnameescape(jar_path))
  end)
end

return M
