local M = {}

--- Extract value from a table or JSON string using JSONPath-like syntax
--- e.g., "$.token", "$.user.id", "$.items[0].name", "$.data['token']"
---@param data table|string
---@param path string
---@return any|nil
function M.extract(data, path)
  if not data or not path then return nil end

  local target = data
  if type(target) == "string" then
    local ok, decoded = pcall(vim.json.decode, target)
    if ok and decoded ~= nil then
      target = decoded
    else
      return nil
    end
  end

  if type(target) ~= "table" then
    return nil
  end

  -- Normalize path: remove leading $. or $
  local clean_path = path:gsub("^%$%.?", "")
  if clean_path == "" or clean_path == "*" then
    return target
  end

  -- Tokenize path into segments: keys or 0-based/1-based array indexes
  local segments = {}
  -- Match dot notation, bracketed numbers, or bracketed string quotes
  local pos = 1
  local len = #clean_path

  while pos <= len do
    local ch = clean_path:sub(pos, pos)
    if ch == "." then
      pos = pos + 1
    elseif ch == "[" then
      local close_pos = clean_path:find("%]", pos + 1)
      if not close_pos then break end
      local inner = clean_path:sub(pos + 1, close_pos - 1)
      -- Strip quotes if present
      if (inner:sub(1, 1) == '"' and inner:sub(-1) == '"') or
         (inner:sub(1, 1) == "'" and inner:sub(-1) == "'") then
        table.insert(segments, inner:sub(2, -2))
      else
        local num = tonumber(inner)
        if num ~= nil then
          -- In JSONPath, array indexes are 0-based: [0] -> 1 in 1-based Lua
          table.insert(segments, { is_index = true, idx = num })
        else
          table.insert(segments, inner)
        end
      end
      pos = close_pos + 1
    else
      local next_dot = clean_path:find("[%.%[]", pos)
      if next_dot then
        table.insert(segments, clean_path:sub(pos, next_dot - 1))
        pos = next_dot
      else
        table.insert(segments, clean_path:sub(pos))
        break
      end
    end
  end

  local curr = target
  for _, seg in ipairs(segments) do
    if type(curr) ~= "table" then
      return nil
    end

    if type(seg) == "table" and seg.is_index then
      -- Try 1-based (0-indexed converted: idx + 1)
      local val = curr[seg.idx + 1]
      if val == nil then
        -- Fallback to literal idx if it was already 1-based
        val = curr[seg.idx]
      end
      curr = val
    else
      local key = seg
      local val = curr[key]
      if val == nil then
        -- Also try numeric index if key is string representation of number
        local num = tonumber(key)
        if num ~= nil then
          val = curr[num + 1] or curr[num]
        end
      end
      curr = val
    end

    if curr == nil then
      return nil
    end
  end

  return curr
end

return M
