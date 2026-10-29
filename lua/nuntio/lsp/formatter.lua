local M = {}

--- Format JSON body text while safely preserving template variables like {{var}} or {{$dyn}}
---@param text string
---@param indent_str? string
---@return string
function M.format_json(text, indent_str)
  indent_str = indent_str or "  "
  local res = {}
  local level = 0
  local in_str = false
  local escape = false
  local i = 1
  local len = #text

  local function add_newline()
    table.insert(res, "\n" .. string.rep(indent_str, level))
  end

  while i <= len do
    local c = text:sub(i, i)
    local c2 = text:sub(i, i + 1)

    if not in_str and c2 == "{{" then
      local v_end = text:find("}}", i + 2, true)
      if v_end then
        table.insert(res, text:sub(i, v_end + 1))
        i = v_end + 2
      else
        table.insert(res, c)
        i = i + 1
      end
    elseif in_str then
      table.insert(res, c)
      if escape then
        escape = false
      elseif c == "\\" then
        escape = true
      elseif c == '"' then
        in_str = false
      end
      i = i + 1
    else
      if c == '"' then
        in_str = true
        table.insert(res, c)
      elseif c == "{" or c == "[" then
        table.insert(res, c)
        level = level + 1
        local next_non_ws = text:match("^%s*([%}%]])", i + 1)
        if not next_non_ws then
          add_newline()
        end
      elseif c == "}" or c == "]" then
        level = math.max(0, level - 1)
        local curr = table.concat(res)
        local prev_non_ws = curr:match("([^%s])%s*$")
        if prev_non_ws ~= "{" and prev_non_ws ~= "[" then
          add_newline()
        end
        table.insert(res, c)
      elseif c == "," then
        table.insert(res, c)
        add_newline()
      elseif c == ":" then
        table.insert(res, ": ")
      elseif not c:match("%s") then
        table.insert(res, c)
      end
      i = i + 1
    end
  end
  return table.concat(res):gsub("%s+\n", "\n"):gsub("\n%s*\n", "\n")
end

--- Canonical HTTP method set
local HTTP_METHODS = {
  GET = true,
  POST = true,
  PUT = true,
  DELETE = true,
  PATCH = true,
  HEAD = true,
  OPTIONS = true,
  CONNECT = true,
  TRACE = true,
}

--- Format entire .http document lines
---@param lines string[]
---@param tab_size? integer
---@return string[]
function M.format_lines(lines, tab_size)
  tab_size = tab_size or 2
  local indent_str = string.rep(" ", tab_size)
  local formatted = {}

  local in_body = false
  local body_lines = {}
  local is_json_body = false

  local function flush_body()
    in_body = false
    if #body_lines == 0 then
      return
    end
    if is_json_body then
      local raw_text = table.concat(body_lines, "\n")
      local formatted_json = M.format_json(raw_text, indent_str)
      for j_line in (formatted_json .. "\n"):gmatch("(.-)\n") do
        table.insert(formatted, j_line)
      end
    else
      for _, bl in ipairs(body_lines) do
        table.insert(formatted, bl)
      end
    end
    body_lines = {}
    is_json_body = false
    in_body = false
  end

  for idx, line in ipairs(lines) do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")

    -- 1. Section delimiter
    if trimmed:match("^###") then
      flush_body()
      -- Ensure single blank line before ### (except at line 1)
      if #formatted > 0 and formatted[#formatted] ~= "" then
        table.insert(formatted, "")
      end
      local name = trimmed:match("^###%s*(.*)$") or ""
      if name ~= "" then
        table.insert(formatted, "### " .. name)
      else
        table.insert(formatted, "###")
      end

    -- 2. Blank line
    elseif trimmed == "" then
      if not in_body and #formatted > 0 and formatted[#formatted] ~= "" then
        in_body = true
        table.insert(formatted, "")
      elseif in_body then
        if is_json_body then
          -- ignore blank lines inside json
        else
          table.insert(body_lines, "")
        end
      end

    -- 3. In Body
    elseif in_body then
      if trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[" then
        is_json_body = true
      end
      table.insert(body_lines, line)

    -- 4. In Headers or Directives or Request line
    else
      -- Document variable: @var = val
      local v_name, v_val = trimmed:match("^@([A-Za-z0-9_%-]+)%s*=%s*(.*)$")
      if v_name then
        table.insert(formatted, "@" .. v_name .. " = " .. v_val)

      -- Metadata directive: # @name ...
      elseif trimmed:match("^#%s*@([A-Za-z0-9_%-]+)") then
        local tag, rest = trimmed:match("^#%s*@([A-Za-z0-9_%-]+)%s*(.*)$")
        if rest and rest ~= "" then
          table.insert(formatted, "# @" .. tag .. " " .. rest)
        else
          table.insert(formatted, "# @" .. tag)
        end

      -- Comments
      elseif trimmed:sub(1, 1) == "#" or trimmed:sub(1, 2) == "//" then
        table.insert(formatted, trimmed)

      -- HTTP Request Line (Method + URL)
      elseif trimmed:match("^([A-Za-z]+)%s+(%S+)") and HTTP_METHODS[trimmed:match("^([A-Za-z]+)"):upper()] then
        local m_word, url, rest = trimmed:match("^([A-Za-z]+)%s+(%S+)%s*(.*)$")
        m_word = m_word:upper()
        if rest and rest ~= "" then
          table.insert(formatted, m_word .. " " .. url .. " " .. rest)
        else
          table.insert(formatted, m_word .. " " .. url)
        end

      -- Header: Key: Value
      elseif trimmed:match("^([A-Za-z0-9_%-]+)%s*:%s*(.*)$") then
        local h_name, h_val = trimmed:match("^([A-Za-z0-9_%-]+)%s*:%s*(.*)$")
        if h_name:lower() == "content-type" and h_val:lower():find("application/json") then
          is_json_body = true
        end
        table.insert(formatted, h_name .. ": " .. h_val)

      -- Fallback line
      else
        table.insert(formatted, trimmed)
      end
    end
  end

  flush_body()

  -- Remove duplicate consecutive blank lines
  local cleaned = {}
  local last_blank = false
  for _, l in ipairs(formatted) do
    local is_blank = l == ""
    if not (is_blank and last_blank) then
      table.insert(cleaned, l)
    end
    last_blank = is_blank
  end

  -- Ensure trailing newline
  if #cleaned > 0 and cleaned[#cleaned] ~= "" then
    table.insert(cleaned, "")
  end

  return cleaned
end

--- LSP textDocument/formatting handler
---@param bufnr integer
---@param options? table LSP formatting options (tabSize, insertSpaces)
---@return table[]|nil List of LSP TextEdit objects
function M.format_document(bufnr, options)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  options = options or {}
  local tab_size = options.tabSize or 2

  local original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local formatted_lines = M.format_lines(original_lines, tab_size)

  local original_text = table.concat(original_lines, "\n")
  local formatted_text = table.concat(formatted_lines, "\n")

  if original_text == formatted_text then
    return {}
  end

  return {
    {
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = #original_lines, character = 0 },
      },
      newText = formatted_text,
    },
  }
end

return M
