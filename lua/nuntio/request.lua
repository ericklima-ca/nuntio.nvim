local Env = require("nuntio.env")
local Utils = require("nuntio.utils")
local Vars = require("nuntio.parser.vars")

local M = {}

---@class NuntioResolvedRequest
---@field name? string
---@field method string
---@field url string
---@field http_version? string
---@field headers table<string, string>
---@field body string
---@field metadata table<string, string[]>
---@field assertions string[] Interpolated `# @assert` expressions (shared block first)
---@field redirect? { file: string, overwrite: boolean }
---@field icon_line integer
---@field start_line integer
---@field end_line integer
---@field buffer_dir string
---@field raw_block NuntioBlock

--- Resolve an NuntioBlock into a ready-to-execute request
---@param block NuntioBlock
---@param doc_vars table<string, string>
---@param buffer_dir string
---@param bufnr? integer
---@param shared_block? NuntioBlock
---@return NuntioResolvedRequest
function M.resolve(block, doc_vars, buffer_dir, bufnr, shared_block)
  local env_vars, default_headers = Env.resolve(buffer_dir, bufnr)

  -- Merge variables: doc_vars -> shared_vars -> block_vars
  local merged_vars = {}
  for k, v in pairs(doc_vars or {}) do
    merged_vars[k] = v
  end
  if shared_block and shared_block.variables then
    for k, v in pairs(shared_block.variables) do
      merged_vars[k] = v
    end
  end
  for k, v in pairs(block.variables or {}) do
    merged_vars[k] = v
  end

  -- Interpolate URL
  local resolved_url = Vars.interpolate(block.url, merged_vars, env_vars)
  -- Escape unencoded spaces in URL for curl compatibility
  resolved_url = resolved_url:gsub(" ", "%%20")

  -- Merge headers case-insensitively: default_headers -> shared_headers -> block_headers
  local raw_headers = {}
  local header_case_map = {} -- lowercase -> original key

  local function add_headers(src)
    for k, v in pairs(src or {}) do
      local lk = k:lower()
      local prev_key = header_case_map[lk]
      if prev_key and prev_key ~= k then
        raw_headers[prev_key] = nil
      end
      header_case_map[lk] = k
      raw_headers[k] = v
    end
  end

  add_headers(default_headers)
  if shared_block and shared_block.headers then
    add_headers(shared_block.headers)
  end
  add_headers(block.headers)

  -- Interpolate headers
  local resolved_headers = {}
  for k, v in pairs(raw_headers) do
    local hk = Vars.interpolate(k, merged_vars, env_vars)
    local hv = Vars.interpolate(v, merged_vars, env_vars)
    resolved_headers[hk] = hv
  end

  -- Resolve body
  local body_text = block.body or ""
  local is_binary_file = false

  if block.body_file and block.body_file ~= "" then
    local target_path = block.body_file
    local is_raw = false
    if target_path:sub(1, 1) == "@" then
      is_raw = true
      target_path = Utils.trim(target_path:sub(2))
    end
    if not vim.fs.normalize(target_path):match("^/") then
      target_path = vim.fs.joinpath(buffer_dir, target_path)
    end

    local file_content = Utils.read_file(target_path)
    if file_content then
      if is_raw then
        body_text = file_content
        is_binary_file = true
      else
        body_text = Vars.interpolate(file_content, merged_vars, env_vars)
      end
    else
      vim.notify("nuntio: could not read body file: " .. target_path, vim.log.levels.WARN)
    end

    -- Infer Content-Type from file extension if not explicitly set
    if not resolved_headers["Content-Type"] and not resolved_headers["content-type"] then
      local ext = target_path:match("%.([%w]+)$")
      if ext then
        ext = ext:lower()
        local mime_types = {
          json = "application/json",
          xml = "application/xml",
          html = "text/html",
          txt = "text/plain",
          png = "image/png",
          jpg = "image/jpeg",
          jpeg = "image/jpeg",
          pdf = "application/pdf",
          zip = "application/zip",
          csv = "text/csv",
        }
        if mime_types[ext] then
          resolved_headers["Content-Type"] = mime_types[ext]
        end
      end
    end
  else
    -- Resolve embedded file inclusions in multipart/form-data or multiline bodies: lines starting with "< " or "<@ "
    if body_text:find("\n<") or body_text:find("^<") then
      local lines = Utils.split_lines(body_text)
      local new_lines = {}
      for _, l in ipairs(lines) do
        local is_raw_inc, inc_path = l:match("^<(@?)%s*(.-)$")
        if inc_path and inc_path ~= "" and not inc_path:match("^%s*{%%") then
          local full_inc = inc_path
          if not vim.fs.normalize(full_inc):match("^/") then
            full_inc = vim.fs.joinpath(buffer_dir, full_inc)
          end
          local inc_content = Utils.read_file(full_inc)
          if inc_content then
            if is_raw_inc ~= "@" then
              inc_content = Vars.interpolate(inc_content, merged_vars, env_vars)
            end
            table.insert(new_lines, inc_content)
          else
            table.insert(new_lines, l)
          end
        else
          table.insert(new_lines, l)
        end
      end
      body_text = table.concat(new_lines, "\n")
    end

    if not is_binary_file then
      body_text = Vars.interpolate(body_text, merged_vars, env_vars)
    end
  end

  local resolved_body = body_text

  -- Auto-infer Content-Type if missing and body exists
  local has_content_type = false
  for k, _ in pairs(resolved_headers) do
    if k:lower() == "content-type" then
      has_content_type = true
      break
    end
  end

  if not has_content_type and resolved_body ~= "" then
    local trimmed_body = Utils.trim(resolved_body)
    if (trimmed_body:sub(1, 1) == "{" and trimmed_body:sub(-1) == "}") or
       (trimmed_body:sub(1, 1) == "[" and trimmed_body:sub(-1) == "]") then
      resolved_headers["Content-Type"] = "application/json"
    elseif trimmed_body:find("=") and not trimmed_body:find("\n") then
      resolved_headers["Content-Type"] = "application/x-www-form-urlencoded"
    end
  end

  -- Interpolate assertions: ### Shared asserts apply to every request
  local assertions = {}
  local assert_sources = {
    shared_block and shared_block.metadata and shared_block.metadata["assert"] or {},
    block.metadata and block.metadata["assert"] or {},
  }
  for _, list in ipairs(assert_sources) do
    for _, expr in ipairs(list) do
      table.insert(assertions, Vars.interpolate(expr, merged_vars, env_vars))
    end
  end

  return {
    name = block.name,
    method = block.method:upper(),
    url = resolved_url,
    http_version = block.http_version,
    headers = resolved_headers,
    body = resolved_body,
    metadata = block.metadata or {},
    assertions = assertions,
    redirect = block.redirect,
    icon_line = block.icon_line,
    start_line = block.start_line,
    end_line = block.end_line,
    buffer_dir = buffer_dir,
    raw_block = block,
  }
end

return M
