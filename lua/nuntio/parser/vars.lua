local Dynamic = require("nuntio.parser.dynamic")
local RequestVars = require("nuntio.parser.request_vars")
local Store = require("nuntio.store")

local M = {}

--- Access nested key from table, e.g. "a.b.c"
---@param tbl table
---@param key string
---@return any|nil
local function get_nested(tbl, key)
  if type(tbl) ~= "table" then return nil end
  if tbl[key] ~= nil then return tbl[key] end
  local curr = tbl
  for part in key:gmatch("[^%.]+") do
    if type(curr) ~= "table" then return nil end
    curr = curr[part]
    if curr == nil then return nil end
  end
  return curr
end

--- Resolve single variable name
---@param var_name string
---@param doc_vars? table<string, any>
---@param env_vars? table<string, any>
---@param custom_dynamic? table<string, fun():any>
---@return string|nil
function M.resolve_one(var_name, doc_vars, env_vars, custom_dynamic)
  var_name = vim.trim(var_name)

  -- 1. Request variable chaining: e.g. "auth.response.body.$.token"
  local req_val = RequestVars.resolve(var_name)
  if req_val ~= nil then
    return req_val
  end

  -- 2. Dynamic variable: e.g. "$uuid", "$timestamp"
  if Dynamic.is_dynamic(var_name) then
    local dyn_val = Dynamic.eval(var_name, custom_dynamic)
    if dyn_val ~= nil then
      return dyn_val
    end
  end

  -- 3. Document / block variables: @var = value
  if doc_vars and doc_vars[var_name] ~= nil then
    return tostring(doc_vars[var_name])
  end

  -- 4. Script globals: client.global.set(key, val)
  local glob_val = Store.get_global(var_name)
  if glob_val ~= nil then
    return tostring(glob_val)
  end

  -- 5. Environment variables: simple or nested a.b
  if env_vars then
    if env_vars[var_name] ~= nil then
      return tostring(env_vars[var_name])
    end
    local nested = get_nested(env_vars, var_name)
    if nested ~= nil then
      return tostring(nested)
    end
  end

  return nil
end

--- Interpolate all {{var}} occurrences in text
--- Supports recursive interpolation up to max_depth
---@param text string|nil
---@param doc_vars? table<string, any>
---@param env_vars? table<string, any>
---@param custom_dynamic? table<string, fun():any>
---@param max_depth? number
---@return string
function M.interpolate(text, doc_vars, env_vars, custom_dynamic, max_depth)
  if not text or text == "" then return "" end
  max_depth = max_depth or 5
  local result = text
  local depth = 0

  while depth < max_depth do
    local had_replacement = false
    result = result:gsub("{{%s*(.-)%s*}}", function(var_name)
      local val = M.resolve_one(var_name, doc_vars, env_vars, custom_dynamic)
      if val ~= nil then
        had_replacement = true
        return val
      end
      -- Keep unresolved {{var}} intact
      return "{{" .. var_name .. "}}"
    end)

    if not had_replacement or not result:find("{{") then
      break
    end
    depth = depth + 1
  end

  return result
end

return M
