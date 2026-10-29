local Utils = require("nuntio.utils")

local M = {}

---@class NuntioRedirect
---@field file string
---@field overwrite boolean

---@class NuntioBlock
---@field start_line integer
---@field end_line integer
---@field icon_line integer
---@field name? string
---@field method string
---@field url string
---@field http_version? string
---@field headers table<string, string>
---@field headers_list { name: string, value: string }[]
---@field body string
---@field body_file? string
---@field variables table<string, string>
---@field metadata table<string, string[]>
---@field redirect? NuntioRedirect
---@field is_shared boolean
---@field is_shared_each boolean
---@field is_plan? boolean Load plan block without a request line

local HTTP_METHODS = {
  GET = true, POST = true, PUT = true, DELETE = true,
  PATCH = true, HEAD = true, OPTIONS = true, TRACE = true, CONNECT = true,
}

--- Create a case-insensitive table wrapper for headers
---@param tbl? table
---@return table
local function make_case_insensitive(tbl)
  return setmetatable(tbl or {}, {
    __index = function(t, k)
      if type(k) == "string" then
        local lk = k:lower()
        for tk, tv in pairs(t) do
          if tk:lower() == lk then return tv end
        end
      end
      return nil
    end,
  })
end

--- Create an empty block
---@param start_line integer
---@return NuntioBlock
local function new_block(start_line)
  return {
    start_line = start_line,
    end_line = start_line,
    icon_line = start_line,
    name = nil,
    method = "GET",
    url = "",
    http_version = nil,
    headers = make_case_insensitive({}),
    headers_list = {},
    body = "",
    body_file = nil,
    variables = {},
    metadata = {},
    redirect = nil,
    is_shared = false,
    is_shared_each = false,
  }
end

--- Parse a single request line e.g. "GET https://api.com HTTP/1.1" or "https://api.com"
---@param line string
---@return string method, string url, string|nil version
local function parse_request_line(line)
  line = Utils.trim(line)
  local first_word, rest = line:match("^([%a]+)%s+(.*)$")
  if first_word and HTTP_METHODS[first_word:upper()] then
    local method = first_word:upper()
    local url, ver = rest:match("^(.-)%s+HTTP/([%d%.]+)%s*$")
    if url and ver then
      return method, Utils.trim(url), "HTTP/" .. ver
    else
      return method, Utils.trim(rest), nil
    end
  else
    -- Method omitted: defaults to GET
    local url, ver = line:match("^(.-)%s+HTTP/([%d%.]+)%s*$")
    if url and ver then
      return "GET", Utils.trim(url), "HTTP/" .. ver
    else
      return "GET", line, nil
    end
  end
end

--- Check if line looks like a request URL line
---@param line string
---@return boolean
local function is_request_line(line)
  line = Utils.trim(line)
  if line == "" or line:match("^#") or line:match("^//") or line:match("^@") then
    return false
  end
  local first_word = line:match("^([%a]+)%s+")
  if first_word and HTTP_METHODS[first_word:upper()] then
    return true
  end
  if line:match("^https?://") then
    return true
  end
  if line:match("^/") then
    return true
  end
  if line:match("^[%w_%-]+%.[%w_%-]+") and not line:match("^[%w_%-]+%s*:%s*") then
    return true
  end
  return false
end

--- Parse document lines into NuntioBlock array
---@param lines string[]
---@return NuntioBlock[] blocks
---@return table<string, string> doc_variables
---@return NuntioBlock[] plans Request-less load plan blocks (`# @scenario` / `# @load-mix`)
function M.parse_document(lines)
  local blocks = {}
  local doc_variables = {}
  local plans = {}

  local current = new_block(1)
  local section = "pre_request" -- "pre_request" | "headers" | "body"

  local function finish_block(end_line)
    if current.url ~= "" or current.is_shared then
      current.end_line = end_line
      current.body = Utils.trim(current.body)
      table.insert(blocks, current)
    elseif current.metadata["scenario"] or current.metadata["load-mix"] then
      current.end_line = end_line
      current.is_plan = true
      table.insert(plans, current)
    end
  end

  for lnum, line in ipairs(lines) do
    local trimmed = Utils.trim(line)

    -- 1. Block separator ###
    if trimmed:match("^###") then
      finish_block(lnum - 1)

      current = new_block(lnum)
      section = "pre_request"

      local sep_name = trimmed:match("^###%s*(.-)%s*$")
      if sep_name and sep_name ~= "" then
        current.name = sep_name
        if sep_name:lower() == "shared" then
          current.is_shared = true
          section = "headers"
        elseif sep_name:lower() == "shared each" then
          current.is_shared = true
          current.is_shared_each = true
          section = "headers"
        end
      end

    -- 2. Comments (ignored unless metadata # @...)
    elseif trimmed:match("^#%s*@") then
      local meta_key, meta_val = trimmed:match("^#%s*@([%w_%-]+)%s*(.*)$")
      if meta_key then
        meta_val = Utils.trim(meta_val or "")
        if meta_key == "name" and meta_val ~= "" then
          current.name = meta_val
        else
          current.metadata[meta_key] = current.metadata[meta_key] or {}
          table.insert(current.metadata[meta_key], meta_val)
        end
      end

    elseif trimmed:match("^#") or trimmed:match("^//") then
      -- Plain comment, ignore

    -- 3. Document / Block variable declaration: @var = value
    elseif trimmed:match("^@([%w_%-]+)%s*=") then
      local vname, vval = trimmed:match("^@([%w_%-]+)%s*=%s*(.*)$")
      if vname then
        vval = Utils.trim(vval or "")
        current.variables[vname] = vval
        doc_variables[vname] = vval
      end

    -- 4. Request line
    elseif section == "pre_request" and is_request_line(trimmed) then
      local method, url, ver = parse_request_line(trimmed)
      current.method = method
      current.url = url
      current.http_version = ver
      current.icon_line = lnum
      section = "headers"

    -- 5. Multi-line URL parts or query params before headers
    elseif section == "headers" and (trimmed:match("^/") or trimmed:match("^[?&]")) and #current.headers_list == 0 then
      current.url = current.url .. trimmed

    -- 6. Headers (Key: Value)
    elseif (section == "headers" or current.is_shared) and trimmed:match("^[%w_%-]+%s*:%s*") then
      local hkey, hval = trimmed:match("^([%w_%-]+)%s*:%s*(.*)$")
      if hkey then
        hval = Utils.trim(hval or "")
        -- Handle Cookie merging
        if hkey:lower() == "cookie" then
          local existing = current.headers["cookie"]
          if existing and existing ~= "" then
            hval = existing .. "; " .. hval
          end
        end
        current.headers[hkey] = hval
        table.insert(current.headers_list, { name = hkey, value = hval })
      end

    -- 7. Blank line after headers transitions to body
    elseif section == "headers" and trimmed == "" then
      section = "body"

    -- 8. Response redirect: >> file or >>! file
    elseif trimmed:match("^>>!?%s+") then
      local bang, dest = trimmed:match("^>>( !? )%s*(.*)$")
      if not dest then
        local is_overwrite = trimmed:match("^>>!%s*(.*)$")
        if is_overwrite then
          current.redirect = { file = Utils.trim(is_overwrite), overwrite = true }
        else
          local append = trimmed:match("^>>%s*(.*)$")
          if append then
            current.redirect = { file = Utils.trim(append), overwrite = false }
          end
        end
      end

    -- 9. Included body file: < ./file.json or <@ ./file.bin
    elseif (section == "body" or section == "headers") and trimmed:match("^<@?%s+(.-)$") then
      local target_file = trimmed:match("^<@?%s+(.-)$")
      current.body_file = Utils.trim(target_file)
      section = "body"

    -- 10. Body lines
    elseif section == "body" then
      if current.body == "" then
        current.body = line
      else
        current.body = current.body .. "\n" .. line
      end
    end
  end

  finish_block(#lines)

  return blocks, doc_variables, plans
end

--- Get request block at cursor line
---@param blocks NuntioBlock[]
---@param lnum integer 1-based line number
---@return NuntioBlock|nil
function M.get_block_at_line(blocks, lnum)
  for _, block in ipairs(blocks) do
    if lnum >= block.start_line and lnum <= block.end_line then
      return block
    end
  end
  -- Fallback to nearest or first block
  if #blocks > 0 then
    local nearest = blocks[1]
    for _, block in ipairs(blocks) do
      if block.start_line <= lnum then
        nearest = block
      end
    end
    return nearest
  end
  return nil
end

return M
