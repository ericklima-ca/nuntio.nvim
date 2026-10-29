local M = {}

--- Generate a v4 UUID
---@return string
local function generate_uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end))
end

--- Built-in dynamic variables
M.builtins = {
  ["$uuid"] = function()
    return generate_uuid()
  end,
  ["$timestamp"] = function()
    return tostring(os.time())
  end,
  ["$isoTimestamp"] = function()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
  end,
  ["$date"] = function()
    return os.date("%Y-%m-%d")
  end,
  ["$randomInt"] = function()
    return tostring(math.random(0, 999999))
  end,
}

--- Check if variable name is a dynamic variable
---@param name string
---@return boolean
function M.is_dynamic(name)
  return name:sub(1, 1) == "$"
end

--- Evaluate dynamic variable
---@param name string
---@param custom_vars? table<string, fun():any>
---@return string|nil
function M.eval(name, custom_vars)
  local trimmed = vim.trim(name)
  if custom_vars and custom_vars[trimmed] then
    local res = custom_vars[trimmed]()
    return res ~= nil and tostring(res) or nil
  end

  local first_word, args_str = trimmed:match("^(%S+)%s*(.*)$")
  first_word = first_word or trimmed

  if first_word == "$randomInt" then
    if args_str and args_str ~= "" then
      local min_s, max_s = args_str:match("^(%d+)%s+(%d+)$")
      if min_s and max_s then
        local min_n = tonumber(min_s)
        local max_n = tonumber(max_s)
        if min_n and max_n and min_n <= max_n then
          return tostring(math.random(min_n, max_n))
        end
      end
    end
    return tostring(math.random(0, 999999))
  end

  if first_word == "$timestamp" then
    if args_str and args_str ~= "" then
      local offset, unit = args_str:match("^([%+%-]?%d+)%s*([smhdwy]?)$")
      if offset then
        local num = tonumber(offset) or 0
        local multiplier = 1
        unit = (unit or ""):lower()
        if unit == "m" then multiplier = 60
        elseif unit == "h" then multiplier = 3600
        elseif unit == "d" then multiplier = 86400
        elseif unit == "w" then multiplier = 604800
        elseif unit == "y" then multiplier = 31536000
        end
        return tostring(os.time() + (num * multiplier))
      end
    end
    return tostring(os.time())
  end

  local fn = M.builtins[first_word]
  if fn then
    return fn()
  end

  return nil
end

return M
