local Shlex = require("nuntio.lib.shlex")
local Utils = require("nuntio.utils")

local M = {}

--- Parse curl command line into a table representation
---@param curl_str string
---@return table|nil
function M.parse_curl(curl_str)
  if not curl_str or curl_str == "" then return nil end

  local parts = Shlex.split(curl_str)
  if #parts == 0 then return nil end

  local start_idx = 1
  if parts[1] == "curl" or parts[1]:match("curl$") then
    start_idx = 2
  end

  local req = {
    method = nil,
    url = "",
    headers = {},
    body = {},
    cookie = "",
    flags = {},
  }

  local i = start_idx
  while i <= #parts do
    local p = parts[i]

    if p == "-X" or p == "--request" then
      i = i + 1
      req.method = (parts[i] or ""):upper()
    elseif p == "-H" or p == "--header" then
      i = i + 1
      local hline = parts[i] or ""
      local k, v = hline:match("^([^:]+):%s*(.*)$")
      if k then
        req.headers[Utils.trim(k)] = Utils.trim(v)
      end
    elseif p == "-d" or p == "--data" or p == "--data-raw" or p == "--data-binary" then
      i = i + 1
      table.insert(req.body, parts[i] or "")
    elseif p == "--json" then
      i = i + 1
      req.headers["Content-Type"] = "application/json"
      req.headers["Accept"] = "application/json"
      table.insert(req.body, parts[i] or "")
    elseif p == "-b" or p == "--cookie" then
      i = i + 1
      req.cookie = parts[i] or ""
    elseif p:match("^https?://") or (p:match("^/") and req.url == "") then
      req.url = p
    elseif not p:match("^%-") and req.url == "" then
      req.url = p
    else
      table.insert(req.flags, p)
    end

    i = i + 1
  end

  if not req.method or req.method == "" then
    req.method = (#req.body > 0) and "POST" or "GET"
  end

  return req
end

--- Convert a curl command string into .http format text
---@param curl_str string
---@return string
function M.to_http(curl_str)
  local parsed = M.parse_curl(curl_str)
  if not parsed or parsed.url == "" then
    return ""
  end

  local lines = {}
  table.insert(lines, string.format("%s %s HTTP/1.1", parsed.method, parsed.url))

  for k, v in pairs(parsed.headers) do
    table.insert(lines, string.format("%s: %s", k, v))
  end
  if parsed.cookie and parsed.cookie ~= "" then
    table.insert(lines, string.format("Cookie: %s", parsed.cookie))
  end

  local body = table.concat(parsed.body, "&")
  if body ~= "" then
    table.insert(lines, "")
    table.insert(lines, body)
  end

  return table.concat(lines, "\n")
end

--- Convert an NuntioResolvedRequest into an executable curl string
---@param req NuntioResolvedRequest
---@return string
function M.to_curl_string(req)
  local parts = { "curl", "-i", "-X", req.method }

  for k, v in pairs(req.headers or {}) do
    table.insert(parts, "-H")
    table.insert(parts, string.format("'%s: %s'", k, v))
  end

  if req.body and req.body ~= "" then
    table.insert(parts, "--data-raw")
    -- In shell, escape single quotes inside single-quoted strings: ' -> '\''
    local escaped_body = req.body:gsub("'", "'\\''")
    table.insert(parts, string.format("'%s'", escaped_body))
  end

  table.insert(parts, string.format("'%s'", req.url))
  return table.concat(parts, " ")
end

return M
