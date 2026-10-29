local ok, lualine_require = pcall(require, "lualine_require")
if not ok then
  -- Standalone fallback when lualine_require is not in path
  local M = {}
  function M.update_status()
    local ft = vim.bo.filetype
    if ft == "http" or ft == "rest" then
      return "nuntio: " .. require("nuntio").get_selected_env()
    end
    return ""
  end
  return M
end

local Component = lualine_require.require("lualine.component"):extend()

local default_options = {
  icon = "󱂛",
}

function Component:init(options)
  Component.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", self.options or {}, default_options)
end

function Component.update_status()
  local ft = vim.bo.filetype
  if ft == "http" or ft == "rest" then
    local env = require("nuntio").get_selected_env()
    return env or "default"
  end
  return ""
end

return Component
