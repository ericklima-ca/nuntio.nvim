local Load = require("nuntio.load")

local M = {}

---@type integer|nil
M.bufnr = nil

local hl_ns = vim.api.nvim_create_namespace("nuntio_load_report")

local WINBAR = "%#NuntioWinbarActive# 󰓅 Load test %*%=%#Comment#[q close  <C-c> cancel  R rerun] %*"

--- Create the report buffer once
---@return integer
local function ensure_buffer()
  if M.bufnr and vim.api.nvim_buf_is_valid(M.bufnr) then
    return M.bufnr
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  pcall(vim.api.nvim_buf_set_name, buf, "nuntio://load")

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", function() require("nuntio.ui.view").close() end)
  map("<C-c>", function() require("nuntio").cancel() end)
  map("R", function() M.rerun() end)

  M.bufnr = buf
  return buf
end

--- Highlight status markers and the client-bound warning
---@param buf integer
---@param lines string[]
local function apply_highlights(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  local marks = {
    { "✔", "DiagnosticOk" },
    { "✘", "DiagnosticError" },
    { "⏳", "DiagnosticInfo" },
    { "⚠", "DiagnosticWarn" },
    { "█+", "DiagnosticInfo" },
  }
  for i, line in ipairs(lines) do
    for _, m in ipairs(marks) do
      local s, e = line:find(m[1])
      if s then
        pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, i - 1, s - 1, { end_col = e, hl_group = m[2] })
      end
    end
  end
end

--- Render a load test state into the report buffer
---@param state table
function M.render(state)
  local buf = ensure_buffer()
  local lines = Load.render_lines(state)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  apply_highlights(buf, lines)
end

--- Start a load test and show its live report
---@param ctx NuntioLoadContext
---@return table|nil state
function M.start(ctx)
  ctx.on_update = M.render
  local state, err = Load.start(ctx)
  if not state then
    vim.notify(err, vim.log.levels.ERROR)
    return nil
  end
  M.render(state)
  require("nuntio.ui.view").show_buffer(ensure_buffer(), WINBAR)
  return state
end

--- Run the last load test again with the same settings
function M.rerun()
  local last = Load.last
  if not last then
    vim.notify("nuntio: no previous load test to rerun", vim.log.levels.WARN)
    return
  end
  M.start({
    block = last.block,
    blocks = last.blocks,
    plans = last.plans,
    doc_vars = last.doc_vars,
    bufnr = last.bufnr,
    buffer_dir = last.buffer_dir,
    shared_block = last.shared_block,
    args = last.args,
  })
end

return M
