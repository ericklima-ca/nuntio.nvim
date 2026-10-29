local JsonPath = require("nuntio.parser.jsonpath")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")

local M = {}

--- Parse and resolve a request reference variable
--- e.g., "LOGIN.response.body.$.token"
---       "LOGIN.response.headers.Authorization"
---       "LOGIN.response.cookies.session.value"
---       "LOGIN.request.url"
---@param expr string
---@return string|nil
function M.resolve(expr)
  -- Lua patterns do not support (response|request) alternation
  local req_name, target = expr:match("^([%w_%-]+)%.response%.(.*)$")
  local part = "response"
  if not req_name then
    req_name, target = expr:match("^([%w_%-]+)%.request%.(.*)$")
    part = "request"
  end

  if not req_name or not target then
    return nil
  end

  local resp = Store.get_by_name(req_name)
  local sent = Store.get_request_by_name(req_name)

  if part == "request" then
    if not sent then return nil end
    if target == "url" then
      return sent.url and tostring(sent.url) or nil
    elseif target == "method" then
      return sent.method and tostring(sent.method) or nil
    elseif target == "body" then
      return sent.body and tostring(sent.body) or nil
    elseif target:match("^headers") then
      local hname = target:gsub("^headers%.?", "")
      hname = hname:gsub("^%['(.*)'%]$", "%1"):gsub('^%["(.*)"%]$', "%1")
      if sent.headers then
        for k, v in pairs(sent.headers) do
          if k:lower() == hname:lower() then
            return tostring(v)
          end
        end
      end
    end
    return nil
  end

  -- part == "response"
  if not resp then return nil end

  if target:match("^body") then
    local path = target:gsub("^body%.?", "")
    if path == "" or path == "*" then
      return resp.body
    end
    if not path:match("^%$") then
      path = "$." .. path
    end
    local val = JsonPath.extract(resp.json or resp.body, path)
    if val ~= nil then
      if type(val) == "table" then
        return vim.json.encode(val)
      end
      return tostring(val)
    end
    return nil
  elseif target:match("^headers") then
    local hname = target:gsub("^headers%.?", "")
    hname = hname:gsub("^%['(.*)'%]$", "%1"):gsub('^%["(.*)"%]$', "%1")
    if resp.headers then
      for k, v in pairs(resp.headers) do
        if k:lower() == hname:lower() then
          return tostring(v)
        end
      end
    end
    return nil
  elseif target:match("^cookies") then
    local cookie_name, field = target:match("^cookies%.([%w_%-]+)%.?([%w_%-]*)$")
    if cookie_name and resp.cookies and resp.cookies[cookie_name] then
      local c = resp.cookies[cookie_name]
      if field == "" or field == "value" then
        return c.value or ""
      elseif c[field] ~= nil then
        return tostring(c[field])
      end
    end
    return nil
  end

  return nil
end

--- Extract all request names referenced in a text string
--- e.g., "{{create_session.response.body.$.id}}" -> {"create_session"}
---@param text? string
---@return string[]
function M.extract_dependencies(text)
  if not text or type(text) ~= "string" or text == "" then
    return {}
  end
  local seen = {}
  local list = {}
  for name in text:gmatch("{{%s*([%w_%-]+)%.response%.") do
    if not seen[name] then
      seen[name] = true
      table.insert(list, name)
    end
  end
  for name in text:gmatch("{{%s*([%w_%-]+)%.request%.") do
    if not seen[name] then
      seen[name] = true
      table.insert(list, name)
    end
  end
  return list
end

--- Extract all exported variables from a block (via # @env-json-key or # @env-header-key)
---@param block NuntioBlock
---@return table<string, { type: string, path: string }>
function M.get_exported_variables(block)
  local vars = {}
  if not block or not block.metadata then return vars end

  if block.metadata["env-json-key"] then
    for _, item in ipairs(block.metadata["env-json-key"]) do
      local var_name, path = item:match("^([%w_%-]+)%s*=?%s*(.*)$")
      if var_name and var_name ~= "" then
        vars[var_name] = { type = "json", path = Utils.trim(path or "") }
      end
    end
  end

  if block.metadata["env-header-key"] then
    for _, item in ipairs(block.metadata["env-header-key"]) do
      local var_name, header = item:match("^([%w_%-]+)%s*=?%s*(.*)$")
      if var_name and var_name ~= "" then
        vars[var_name] = { type = "header", path = Utils.trim(header or "") }
      end
    end
  end

  return vars
end

--- Build a map of exported variable name -> producer block from all_blocks
---@param all_blocks? NuntioBlock[]
---@return table<string, NuntioBlock>
local function build_producer_map(all_blocks)
  local map = {}
  if not all_blocks then return map end
  for _, b in ipairs(all_blocks) do
    local exported = M.get_exported_variables(b)
    for var_name, _ in pairs(exported) do
      map[var_name] = b
    end
  end
  return map
end

--- Extract all request names referenced by a block (url, headers, body, body_file, variables)
---@param block NuntioBlock
---@param all_blocks? NuntioBlock[]|string
---@param buffer_dir? string
---@return string[]
function M.get_block_dependencies(block, all_blocks, buffer_dir)
  if type(all_blocks) == "string" and buffer_dir == nil then
    buffer_dir = all_blocks
    all_blocks = nil
  end

  local seen = {}
  local list = {}
  local producer_map = build_producer_map(all_blocks)

  local function add_dep(name)
    if name and name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(list, name)
    end
  end

  local function add_from(text)
    if not text or type(text) ~= "string" or text == "" then return end
    for _, name in ipairs(M.extract_dependencies(text)) do
      add_dep(name)
    end
    for raw in text:gmatch("{{%s*([%w_%-]+)%s*}}") do
      local trimmed = vim.trim(raw)
      local prod_block = producer_map[trimmed]
      if prod_block and prod_block.name and prod_block.name ~= block.name then
        add_dep(prod_block.name)
      end
    end
  end

  add_from(block.url)

  if block.headers then
    for k, v in pairs(block.headers) do
      add_from(k)
      add_from(tostring(v))
    end
  end

  if block.variables then
    for _, v in pairs(block.variables) do
      add_from(tostring(v))
    end
  end

  if block.body then
    add_from(block.body)
  end

  if block.body_file and block.body_file ~= "" and not block.body_file:match("^@") then
    local path = block.body_file
    if buffer_dir and not vim.fs.normalize(path):match("^/") then
      path = vim.fs.joinpath(buffer_dir, path)
    end
    local content = Utils.read_file(path)
    if content then
      add_from(content)
    end
  end

  return list
end

--- Resolve prerequisite execution order for a target block
--- Returns list of blocks to run prior to target_block, or nil and error message
---@param target_block NuntioBlock
---@param all_blocks NuntioBlock[]
---@param buffer_dir? string
---@return NuntioBlock[]|nil prereqs, string|nil err
function M.resolve_dependency_order(target_block, all_blocks, buffer_dir)
  local order = {}
  local visited = {}
  local in_order = {}

  local function dfs(block)
    local block_name = block.name or ("line_" .. tostring(block.start_line))
    if visited[block_name] == "visiting" then
      return false, string.format("circular dependency detected involving '%s'", block_name)
    end
    if visited[block_name] == "visited" then
      return true
    end

    visited[block_name] = "visiting"

    local deps = M.get_block_dependencies(block, all_blocks, buffer_dir)
    for _, dep_name in ipairs(deps) do
      local has_resp = Store.get_by_name(dep_name) ~= nil
      local has_req = Store.get_request_by_name(dep_name) ~= nil
      if not has_resp and not has_req then
        local dep_block = nil
        for _, b in ipairs(all_blocks) do
          if b.name == dep_name then
            dep_block = b
            break
          end
        end

        if not dep_block then
          return false, string.format("prerequisite request '%s' not found in buffer", dep_name)
        end

        local ok, err = dfs(dep_block)
        if not ok then return false, err end

        if not in_order[dep_name] then
          in_order[dep_name] = true
          table.insert(order, dep_block)
        end
      end
    end

    visited[block_name] = "visited"
    return true
  end

  local ok, err = dfs(target_block)
  if not ok then
    return nil, err
  end

  return order, nil
end

--- Find all request variable references in a block
--- Returns table mapping req_name -> list of full expression strings
---@param block NuntioBlock
---@param all_blocks? NuntioBlock[]|string
---@param buffer_dir? string
---@return table<string, string[]> references
function M.get_block_variable_references(block, all_blocks, buffer_dir)
  if type(all_blocks) == "string" and buffer_dir == nil then
    buffer_dir = all_blocks
    all_blocks = nil
  end

  local refs = {}
  local producer_map = build_producer_map(all_blocks)

  local function add_ref(req_name, expr)
    if req_name and expr then
      refs[req_name] = refs[req_name] or {}
      if not vim.tbl_contains(refs[req_name], expr) then
        table.insert(refs[req_name], expr)
      end
    end
  end

  local function add_from(text)
    if not text or type(text) ~= "string" or text == "" then return end
    for raw in text:gmatch("{{%s*(.-)%s*}}") do
      local trimmed = vim.trim(raw)
      local req_name = trimmed:match("^([%w_%-]+)%.response%.") or trimmed:match("^([%w_%-]+)%.request%.")
      if req_name then
        add_ref(req_name, trimmed)
      else
        local prod_block = producer_map[trimmed]
        local prod_info = Store.get_var_producer(trimmed)
        local prod_name = (prod_block and prod_block.name) or (prod_info and prod_info.req_name)
        if prod_name and prod_name ~= block.name then
          add_ref(prod_name, trimmed)
        end
      end
    end
  end

  add_from(block.url)
  if block.headers then
    for k, v in pairs(block.headers) do
      add_from(k)
      add_from(tostring(v))
    end
  end
  if block.variables then
    for _, v in pairs(block.variables) do
      add_from(tostring(v))
    end
  end
  if block.body then
    add_from(block.body)
  end
  if block.body_file and block.body_file ~= "" and not block.body_file:match("^@") then
    local path = block.body_file
    if buffer_dir and not vim.fs.normalize(path):match("^/") then
      path = vim.fs.joinpath(buffer_dir, path)
    end
    local content = Utils.read_file(path)
    if content then
      add_from(content)
    end
  end

  return refs
end

return M
