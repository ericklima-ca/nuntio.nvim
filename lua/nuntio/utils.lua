local M = {}

--- Trim leading and trailing whitespace
---@param s string
---@return string
function M.trim(s)
  if not s then return "" end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Split string by delimiter
---@param str string
---@param sep string
---@return string[]
function M.split(str, sep)
  if sep == "" then
    local res = {}
    for i = 1, #str do
      res[#res + 1] = str:sub(i, i)
    end
    return res
  end
  local res = {}
  local pattern = string.format("([^%s]+)", sep)
  for match in str:gmatch(pattern) do
    table.insert(res, match)
  end
  return res
end

--- Split lines preserving empty lines
---@param str? string
---@return string[]
function M.split_lines(str)
  if not str or str == "" then return {} end
  str = tostring(str):gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  local start = 1
  while true do
    local s, e = str:find("\n", start, true)
    if not s then
      table.insert(lines, str:sub(start))
      break
    end
    table.insert(lines, str:sub(start, s - 1))
    start = e + 1
  end
  return lines
end

--- Find a file in current or parent directories
---@param filename string
---@param start_dir? string
---@return string|nil
function M.find_in_parents(filename, start_dir)
  local current = start_dir or vim.fn.expand("%:p:h")
  if not current or current == "" then
    current = vim.uv.cwd()
  end
  current = vim.fs.normalize(current)

  while current and current ~= "" do
    local candidate = vim.fs.joinpath(current, filename)
    if vim.uv.fs_stat(candidate) then
      return candidate
    end
    local parent = vim.fs.dirname(current)
    if not parent or parent == current then
      break
    end
    current = parent
  end
  return nil
end

--- Read entire file
---@param path string
---@return string|nil
function M.read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Write file contents
---@param path string
---@param content string
---@return boolean
function M.write_file(path, content)
  local dir = vim.fs.dirname(path)
  if dir and not vim.uv.fs_stat(dir) then
    vim.fn.mkdir(dir, "p")
  end
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

--- Safe JSON decode
---@param str string
---@return any|nil, string|nil
function M.json_decode(str)
  if not str or str == "" then return nil, "empty string" end
  local ok, res = pcall(vim.json.decode, str)
  if ok then return res, nil end
  return nil, res
end

--- Pure Lua JSON / table pretty printer with 2 spaces indent
---@param val any
---@param indent? integer
---@return string
local function pretty_format(val, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local inner_pad = string.rep("  ", indent + 1)

  if type(val) == "table" then
    local is_array = vim.islist and vim.islist(val) or (#val > 0 and next(val, #val) == nil)
    if is_array then
      if #val == 0 then return "[]" end
      local items = {}
      for _, v in ipairs(val) do
        table.insert(items, inner_pad .. pretty_format(v, indent + 1))
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "]"
    else
      local keys = vim.tbl_keys(val)
      if #keys == 0 then return "{}" end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local items = {}
      for _, k in ipairs(keys) do
        local k_str = string.format("%q", tostring(k))
        table.insert(items, inner_pad .. k_str .. ": " .. pretty_format(val[k], indent + 1))
      end
      return "{\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "}"
    end
  elseif type(val) == "string" then
    return string.format("%q", val)
  elseif type(val) == "number" or type(val) == "boolean" then
    return tostring(val)
  elseif val == nil then
    return "null"
  end
  return tostring(val)
end

--- JSON encode with pretty formatting option
---@param val any
---@param pretty? boolean
---@return string
function M.json_encode(val, pretty)
  if not pretty then
    return vim.json.encode(val)
  end
  -- Try jq if available for pretty print, fallback to pure Lua pretty formatter
  if vim.fn.executable("jq") == 1 then
    local raw = vim.json.encode(val)
    local out = vim.fn.system({ "jq", "." }, raw)
    if vim.v.shell_error == 0 and out and out ~= "" then
      return M.trim(out)
    end
  end
  return pretty_format(val, 0)
end

--- Deep copy a table
---@generic T
---@param orig T
---@return T
function M.deepcopy(orig)
  return vim.deepcopy(orig)
end

return M
