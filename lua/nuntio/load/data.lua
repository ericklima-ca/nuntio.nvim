local Utils = require("nuntio.utils")

local M = {}

M.modes = { "sequential", "circular", "random", "unique" }

--- Split one CSV line into fields (RFC 4180 quoting, no embedded newlines)
---@param line string
---@return string[]
local function split_csv_line(line)
  local fields = {}
  local i, n = 1, #line
  while i <= n + 1 do
    if line:sub(i, i) == '"' then
      local buf = {}
      local j = i + 1
      while j <= n do
        local ch = line:sub(j, j)
        if ch == '"' then
          if line:sub(j + 1, j + 1) == '"' then
            table.insert(buf, '"')
            j = j + 2
          else
            j = j + 1
            break
          end
        else
          table.insert(buf, ch)
          j = j + 1
        end
      end
      table.insert(fields, table.concat(buf))
      -- Skip to the next separator
      local comma = line:find(",", j, true)
      i = comma and comma + 1 or n + 2
    else
      local comma = line:find(",", i, true)
      if comma then
        table.insert(fields, line:sub(i, comma - 1))
        i = comma + 1
      else
        table.insert(fields, line:sub(i))
        i = n + 2
      end
    end
  end
  return fields
end

--- Parse CSV content with a header row into a list of rows keyed by column
---@param content string
---@return table[] rows, string|nil err
function M.parse_csv(content)
  local lines = {}
  for _, l in ipairs(Utils.split_lines(content)) do
    l = l:gsub("\r$", "")
    if vim.trim(l) ~= "" then
      table.insert(lines, l)
    end
  end
  if #lines == 0 then
    return {}, "CSV file is empty"
  end

  local header = split_csv_line(lines[1])
  for idx, h in ipairs(header) do
    header[idx] = vim.trim(h)
  end

  local rows = {}
  for i = 2, #lines do
    local fields = split_csv_line(lines[i])
    local row = {}
    for idx, col in ipairs(header) do
      row[col] = fields[idx] or ""
    end
    table.insert(rows, row)
  end
  if #rows == 0 then
    return rows, "CSV file has a header but no rows"
  end
  return rows
end

--- Load rows from a .csv file or a .json array of objects
---@param path string
---@return table[]|nil rows, string|nil err
function M.load(path)
  local content = Utils.read_file(path)
  if not content then
    return nil, "data file not found: " .. path
  end

  if path:lower():match("%.json$") then
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" or not vim.islist(decoded) then
      return nil, "JSON data file must contain an array of objects: " .. path
    end
    if #decoded == 0 then
      return nil, "JSON data file is empty: " .. path
    end
    for idx, row in ipairs(decoded) do
      if type(row) ~= "table" then
        return nil, string.format("JSON data row %d is not an object: %s", idx, path)
      end
    end
    return decoded
  end

  local rows, err = M.parse_csv(content)
  if err then
    return nil, err .. ": " .. path
  end
  return rows
end

--- Parse a `# @data <path> [mode=...]` directive value
---@param value string
---@return { path: string, mode: string }|nil spec, string|nil err
function M.parse_directive(value)
  local path, rest = vim.trim(value or ""):match("^(%S+)%s*(.*)$")
  if not path then
    return nil, "missing data file path"
  end
  local spec = { path = path, mode = "circular" }
  for token in rest:gmatch("%S+") do
    local key, val = token:match("^([%w_]+)=(.+)$")
    if key ~= "mode" then
      return nil, string.format("unknown option '%s' (expected mode=%s)", token, table.concat(M.modes, "|"))
    end
    if not vim.tbl_contains(M.modes, val) then
      return nil, string.format("unknown mode '%s' (expected %s)", val, table.concat(M.modes, ", "))
    end
    spec.mode = val
  end
  return spec
end

--- Create a row feeder. `next()` returns nil once a finite mode is exhausted.
---@param rows table[]
---@param mode string
---@return { next: fun(): table|nil, size: integer }
function M.feeder(rows, mode)
  local idx = 0
  local order = nil

  if mode == "unique" then
    order = {}
    for i = 1, #rows do
      order[i] = i
    end
    -- Fisher-Yates shuffle
    for i = #order, 2, -1 do
      local j = math.random(1, i)
      order[i], order[j] = order[j], order[i]
    end
  end

  local function next_row()
    if mode == "random" then
      return rows[math.random(1, #rows)]
    end
    idx = idx + 1
    if mode == "circular" then
      return rows[((idx - 1) % #rows) + 1]
    elseif mode == "unique" then
      return order[idx] and rows[order[idx]] or nil
    end
    return rows[idx] -- sequential
  end

  return { next = next_row, size = #rows }
end

return M
