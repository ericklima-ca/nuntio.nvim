local Highlights = require("nuntio.ui.highlights")

local M = {}

M.panes = {
  { id = "body", label = "Body", icon = "󰖟", click = "v:lua.NuntioWinbarClick_body" },
  { id = "headers", label = "Headers", icon = "󰒚", click = "v:lua.NuntioWinbarClick_headers" },
  { id = "headers_body", label = "All", icon = "󱂛", click = "v:lua.NuntioWinbarClick_overview" },
  { id = "chain", label = "Chain", icon = "󰌷", click = "v:lua.NuntioWinbarClick_chain", req_chain = true },
  { id = "tests", label = "Tests", icon = "󰙨", click = "v:lua.NuntioWinbarClick_tests", req_tests = true },
  { id = "stats", label = "Stats", icon = "󰄬", click = "v:lua.NuntioWinbarClick_stats" },
  { id = "verbose", label = "Raw", icon = "󰆼", click = "v:lua.NuntioWinbarClick_raw" },
}

-- Setup global click handlers for mouse support
_G.NuntioWinbarClick_body = function() require("nuntio.ui.view").switch_view("body") end
_G.NuntioWinbarClick_headers = function() require("nuntio.ui.view").switch_view("headers") end
_G.NuntioWinbarClick_overview = function() require("nuntio.ui.view").switch_view("headers_body") end
_G.NuntioWinbarClick_chain = function() require("nuntio.ui.view").switch_view("chain") end
_G.NuntioWinbarClick_tests = function() require("nuntio.ui.view").switch_view("tests") end
_G.NuntioWinbarClick_stats = function() require("nuntio.ui.view").switch_view("stats") end
_G.NuntioWinbarClick_raw = function() require("nuntio.ui.view").switch_view("verbose") end
_G.NuntioWinbarClick_history = function() require("nuntio.ui.view").open_history_picker() end

--- Render modern responsive winbar string for a window
---@param active_id string
---@param resp? NuntioStoredResponse
---@return string
function M.render(active_id, resp)
  local parts = {}
  table.insert(parts, " ")

  local has_chain = (resp and resp.chain and resp.chain.total and resp.chain.total > 1)
  local has_exports = (resp and resp.exported_vars and next(resp.exported_vars) ~= nil)
  local show_chain_tab = has_chain or has_exports
  local tests = resp and resp.assertions
  local has_tests = tests ~= nil and tests.total > 0

  for _, p in ipairs(M.panes) do
    if (not p.req_chain or show_chain_tab) and (not p.req_tests or has_tests) then
      local is_active = (p.id == active_id)
      local click_prefix = "%@" .. p.click .. "@"
      local click_suffix = "%X"

      local item
      if is_active then
        item = string.format("%s%%#NuntioWinbarActive# [ %s %s ] %%*%s",
          click_prefix, p.icon, p.label, click_suffix)
      else
        item = string.format("%s%%#NuntioWinbarInactive#  %s %s  %%*%s",
          click_prefix, p.icon, p.label, click_suffix)
      end
      table.insert(parts, item)
    end
  end

  table.insert(parts, "%=")

  local Filter = require("nuntio.ui.filter")
  if Filter.active_filter and Filter.active_filter ~= "" then
    table.insert(parts, string.format("%%#NuntioBadgeAmber#󰈲 %s%%* ", Filter.active_filter))
  end

  if resp then
    local status_sym = (resp.status >= 200 and resp.status < 300) and "✔"
      or (resp.status >= 300 and resp.status < 400) and "󰁔"
      or "󰅚"
    local status_hl = Highlights.get_status_hl(resp.status)
    local lat_hl = Highlights.get_latency_hl(resp.time)

    local size_b = resp.stats and resp.stats.size_download or (resp.body and #resp.body or 0)
    local size_str = size_b < 1024 and string.format("%dB", size_b) or string.format("%.1fKB", size_b / 1024)

    table.insert(parts, string.format("%%#%s#%s %d%%* ", status_hl, status_sym, resp.status))
    table.insert(parts, string.format("%%#%s#⏱ %.0fms%%* ", lat_hl, resp.time or 0))
    table.insert(parts, string.format("%%#Comment#📦 %s%%* ", size_str))

    if has_tests then
      local tests_hl = tests.failed > 0 and "DiagnosticError" or "DiagnosticOk"
      local tests_sym = tests.failed > 0 and "✘" or "✔"
      table.insert(parts, string.format("%%#%s#󰙨 %s %d/%d%%* ", tests_hl, tests_sym, tests.passed, tests.total))
    end

    if has_chain then
      table.insert(parts, string.format("%%#NuntioBadgePurple#󰌷 %d/%d%%* ", resp.chain.step or 1, resp.chain.total))
    elseif has_exports then
      table.insert(parts, "%#NuntioBadgePurple#󰌷 Exports%* ")
    end
  end

  table.insert(parts, "%#Comment#[q  [:◄  ]:►  F:Filter] %*")

  return table.concat(parts, "")
end

return M
