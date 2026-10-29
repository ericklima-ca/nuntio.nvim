local Config = require("nuntio.config")

local M = {}

local ns_id = vim.api.nvim_create_namespace("nuntio_inlay")

--- Set loading indicator on a buffer line
---@param bufnr integer
---@param line_nr integer 1-based line number
function M.set_loading(bufnr, line_nr)
  if not Config.get().inlay_icons or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, line_nr - 1, line_nr)

  local icon = Config.get().icons.loading or "⏳"
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_nr - 1, 0, {
    virt_text = { { " " .. icon .. " Sending...", "Comment" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

--- Set completed / done indicator
---@param bufnr integer
---@param line_nr integer 1-based line number
---@param status number HTTP status code
---@param duration_ms number Duration in milliseconds
---@param assertions? NuntioAssertionSummary
function M.set_done(bufnr, line_nr, status, duration_ms, assertions)
  if not Config.get().inlay_icons or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, line_nr - 1, line_nr)

  local has_assertions = assertions and assertions.total > 0
  local icon = Config.get().icons.done or "✔"
  local hl = "String"
  -- With assertions, they decide pass/fail rather than the status code
  if (has_assertions and assertions.failed > 0) or (not has_assertions and status >= 400) then
    icon = Config.get().icons.error or "✘"
    hl = "ErrorMsg"
  end

  local time_str
  if duration_ms < 1000 then
    time_str = string.format("%.0fms", duration_ms)
  else
    time_str = string.format("%.2fs", duration_ms / 1000)
  end

  local label = string.format(" %s %d (%s)", icon, status, time_str)
  if has_assertions then
    label = label .. string.format(" · %d/%d passed", assertions.passed, assertions.total)
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_nr - 1, 0, {
    virt_text = { { label, hl } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

--- Set error indicator
---@param bufnr integer
---@param line_nr integer 1-based line number
---@param err_msg string
function M.set_error(bufnr, line_nr, err_msg)
  if not Config.get().inlay_icons or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, line_nr - 1, line_nr)

  local icon = Config.get().icons.error or "✘"
  local label = string.format(" %s %s", icon, err_msg:sub(1, 40))
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_nr - 1, 0, {
    virt_text = { { label, "ErrorMsg" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

--- Clear inlays in a buffer
---@param bufnr integer
function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
  end
end

return M
