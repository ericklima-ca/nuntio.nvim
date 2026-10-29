local M = {}

local ns_id = nil

--- Get or create the nuntio highlight namespace
---@return integer
function M.get_namespace()
  if not ns_id then
    ns_id = vim.api.nvim_create_namespace("nuntio_ui")
  end
  return ns_id
end

--- Initialize all highlight groups for nuntio
function M.setup()
  local set_hl = function(name, opts)
    opts.default = true -- Allow user / colorscheme to override
    vim.api.nvim_set_hl(0, name, opts)
  end

  -- Method Badges (Bold + Distinct Colors)
  set_hl("NuntioMethodGet", { fg = "#10b981", bold = true })
  set_hl("NuntioMethodPost", { fg = "#3b82f6", bold = true })
  set_hl("NuntioMethodPut", { fg = "#f59e0b", bold = true })
  set_hl("NuntioMethodPatch", { fg = "#8b5cf6", bold = true })
  set_hl("NuntioMethodDelete", { fg = "#ef4444", bold = true })
  set_hl("NuntioMethodHead", { fg = "#06b6d4", bold = true })
  set_hl("NuntioMethodOptions", { fg = "#14b8a6", bold = true })

  -- Status Code Badges
  set_hl("NuntioStatus2xx", { fg = "#10b981", bold = true })
  set_hl("NuntioStatus3xx", { fg = "#38bdf8", bold = true })
  set_hl("NuntioStatus4xx", { fg = "#f59e0b", bold = true })
  set_hl("NuntioStatus5xx", { fg = "#ef4444", bold = true })

  -- Latency & Metrics
  set_hl("NuntioLatencyFast", { fg = "#10b981", bold = true })
  set_hl("NuntioLatencyMed", { fg = "#f59e0b", bold = true })
  set_hl("NuntioLatencySlow", { fg = "#ef4444", bold = true })

  -- Header Banner & Dividers
  set_hl("NuntioBannerUrl", { fg = "#7dcfff", underline = false })
  set_hl("NuntioBannerDivider", { fg = "#3b4261" })
  set_hl("NuntioBannerDoubleDivider", { fg = "#565f89" })
  set_hl("NuntioDivider", { fg = "#414868" })
  set_hl("NuntioDividerText", { fg = "#7aa2f7", bold = true })
  set_hl("NuntioDividerIcon", { fg = "#e0af68" })
  set_hl("NuntioRunHint", { fg = "#565f89", italic = true })
  set_hl("NuntioBadge", { fg = "#c0caf5", bg = "#24283b", bold = true })
  set_hl("NuntioBadgeGreen", { fg = "#10b981", bg = "#1a2e2b", bold = true })
  set_hl("NuntioBadgeBlue", { fg = "#7aa2f7", bg = "#1e283d", bold = true })
  set_hl("NuntioBadgePurple", { fg = "#bb9af7", bg = "#27203b", bold = true })
  set_hl("NuntioBadgeAmber", { fg = "#e0af68", bg = "#2d261e", bold = true })
  set_hl("NuntioBadgeRed", { fg = "#f7768e", bg = "#361f26", bold = true })

  -- Headers & Metadata (Inherits active colorscheme colors; nocombine suppresses URL underline leak)
  local c_hl = vim.api.nvim_get_hl(0, { name = "@constant", link = false })
  if not c_hl.fg then
    c_hl = vim.api.nvim_get_hl(0, { name = "Constant", link = false })
  end
  local s_hl = vim.api.nvim_get_hl(0, { name = "@string", link = false })
  if not s_hl.fg then
    s_hl = vim.api.nvim_get_hl(0, { name = "String", link = false })
  end
  local d_hl = vim.api.nvim_get_hl(0, { name = "@punctuation.delimiter", link = false })
  if not d_hl.fg then
    d_hl = vim.api.nvim_get_hl(0, { name = "Delimiter", link = false })
  end

  set_hl("NuntioHeaderKey", { fg = c_hl.fg or "#ff9e64", bold = c_hl.bold, nocombine = true })
  set_hl("NuntioHeaderVal", { fg = s_hl.fg or "#9ece6a", nocombine = true })
  set_hl("NuntioHeaderDelim", { fg = d_hl.fg or "#89ddff", nocombine = true })
  set_hl("NuntioDocVar", { fg = "#bb9af7", bold = true })
  set_hl("NuntioMetadataTag", { fg = "#f7768e", bold = true })
  set_hl("NuntioVariable", { fg = "#e0af68", italic = true })
  set_hl("NuntioUrl", { fg = "#7dcfff", underline = true })
  set_hl("NuntioOperator", { fg = "#89ddff", bold = true })

  -- Shared Configuration Block
  set_hl("NuntioSharedDelimiter", { fg = "#bb9af7", bold = true })
  set_hl("NuntioSharedKeyword", { fg = "#f7768e", bold = true, underline = true })
  set_hl("NuntioSharedBadge", { fg = "#bb9af7", bg = "#27203b", bold = true })
  set_hl("NuntioSharedIcon", { fg = "#bb9af7", bold = true })

  -- Chain & Execution Graph
  set_hl("NuntioChainNode", { fg = "#bb9af7", bold = true })
  set_hl("NuntioChainEdge", { fg = "#565f89" })
  set_hl("NuntioChainArrow", { fg = "#7dcfff", bold = true })
  set_hl("NuntioChainVar", { fg = "#7dcfff" })
  set_hl("NuntioChainVal", { fg = "#9ece6a" })
  set_hl("NuntioChainSummary", { fg = "#e0af68", bold = true })

  -- Winbar
  set_hl("NuntioWinbarActive", { fg = "#ffffff", bg = "#3b4261", bold = true })
  set_hl("NuntioWinbarInactive", { fg = "#7aa2f7", bg = "#1f2335" })
  set_hl("NuntioWinbarKey", { fg = "#e0af68", bold = true })
  set_hl("NuntioWinbarHint", { fg = "#565f89" })

  -- Pickers & Request Search
  set_hl("NuntioPickerSelected", { fg = "#7aa2f7", bold = true })
  set_hl("NuntioPickerMatch", { fg = "#e0af68", bold = true })
end

--- Get method highlight group
---@param method string
---@return string
function M.get_method_hl(method)
  local m = (method or ""):upper()
  if m == "GET" then return "NuntioMethodGet"
  elseif m == "POST" then return "NuntioMethodPost"
  elseif m == "PUT" then return "NuntioMethodPut"
  elseif m == "PATCH" then return "NuntioMethodPatch"
  elseif m == "DELETE" then return "NuntioMethodDelete"
  elseif m == "HEAD" then return "NuntioMethodHead"
  elseif m == "OPTIONS" then return "NuntioMethodOptions"
  end
  return "NuntioMethodPost"
end

--- Get status highlight group
---@param status number
---@return string
function M.get_status_hl(status)
  status = tonumber(status) or 0
  if status >= 200 and status < 300 then
    return "NuntioStatus2xx"
  elseif status >= 300 and status < 400 then
    return "NuntioStatus3xx"
  elseif status >= 400 and status < 500 then
    return "NuntioStatus4xx"
  elseif status >= 500 then
    return "NuntioStatus5xx"
  end
  return "Comment"
end

--- Get latency highlight group
---@param ms number
---@return string
function M.get_latency_hl(ms)
  ms = tonumber(ms) or 0
  if ms < 200 then
    return "NuntioLatencyFast"
  elseif ms < 1000 then
    return "NuntioLatencyMed"
  end
  return "NuntioLatencySlow"
end

return M
