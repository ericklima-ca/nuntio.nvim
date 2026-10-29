local Document = require("nuntio.parser.document")
local Env = require("nuntio.env")
local Sources = require("nuntio.lsp.sources")
local Store = require("nuntio.store")

local M = {}

--- Format an item into an LSP CompletionItem
---@param label string
---@param kind integer
---@param detail? string
---@param doc? string
---@param insert_text? string
---@param is_snippet? boolean
---@return table
local function make_completion_item(label, kind, detail, doc, insert_text, is_snippet)
  local item = {
    label = label,
    kind = kind,
    detail = detail or "",
    insertText = insert_text or label,
    insertTextFormat = is_snippet and 2 or 1, -- 2 is Snippet, 1 is PlainText
  }
  if doc and doc ~= "" then
    item.documentation = {
      kind = "markdown",
      value = doc,
    }
  end
  return item
end

--- Get completions for template variables {{...}}
---@param var_prefix string
---@param bufnr integer
---@param lines string[]
---@return table[]
local function get_variable_completions(var_prefix, bufnr, lines)
  local items = {}

  -- 1. Dynamic variables if typing $ or empty
  if var_prefix == "" or var_prefix:sub(1, 1) == "$" then
    for _, dyn in ipairs(Sources.dynamic_vars) do
      table.insert(items, make_completion_item(
        dyn.name,
        Sources.kinds.Variable,
        dyn.detail,
        dyn.doc,
        dyn.insert_text
      ))
    end
  end

  -- 2. Document variables (@var = value)
  local _, doc_vars = Document.parse_document(lines)
  for k, v in pairs(doc_vars or {}) do
    table.insert(items, make_completion_item(
      k,
      Sources.kinds.Variable,
      "Document Variable",
      ("**@" .. k .. "** = `" .. tostring(v) .. "`\n\n*Defined at top of file*"),
      k
    ))
  end

  -- 3. Environment variables (active environment)
  local buf_dir = vim.api.nvim_buf_get_name(bufnr)
  if buf_dir and buf_dir ~= "" then
    buf_dir = vim.fs.dirname(buf_dir)
  else
    buf_dir = vim.uv.cwd()
  end

  local cur_env = Env.get_current_env(bufnr)
  local env_vars = Env.resolve(buf_dir, bufnr)
  for k, v in pairs(env_vars or {}) do
    -- Skip internal keys
    if not k:match("^%$") and not doc_vars[k] then
      table.insert(items, make_completion_item(
        k,
        Sources.kinds.Variable,
        "Env: " .. cur_env,
        ("**" .. k .. "** = `" .. tostring(v) .. "`\n\n*From active environment: `" .. cur_env .. "`*"),
        k
      ))
    end
  end

  -- 4. Chained request response variables and metadata exports
  local blocks = Document.parse_document(lines)
  for _, block in ipairs(blocks) do
    local req_name = block.name or (block.metadata and block.metadata.name)
    if req_name and req_name ~= "" and not block.is_shared then
      -- Base request response templates
      table.insert(items, make_completion_item(
        req_name .. ".response.body.$.",
        Sources.kinds.Reference,
        "Response Body JSON",
        "Reference JSON property from request **" .. req_name .. "**",
        req_name .. ".response.body.$."
      ))
      table.insert(items, make_completion_item(
        req_name .. ".response.headers.",
        Sources.kinds.Reference,
        "Response Header",
        "Reference header from request **" .. req_name .. "**",
        req_name .. ".response.headers."
      ))
      table.insert(items, make_completion_item(
        req_name .. ".response.status",
        Sources.kinds.Reference,
        "Response HTTP Status",
        "Reference HTTP status code from request **" .. req_name .. "**",
        req_name .. ".response.status"
      ))
    end

    -- Add metadata-declared variables (# @prompt, # @secret, # @env-json-key, # @env-header-key)
    if block.metadata then
      for _, meta_type in ipairs({ "prompt", "secret", "env-json-key", "env-header-key" }) do
        if block.metadata[meta_type] then
          for _, item in ipairs(block.metadata[meta_type]) do
            local vname = item:match("^([%w_%-]+)")
            if vname and vname ~= "" and not doc_vars[vname] then
              table.insert(items, make_completion_item(
                vname,
                Sources.kinds.Variable,
                "Metadata: " .. meta_type,
                "Declared by `# @" .. meta_type .. " " .. item .. "`",
                vname
              ))
            end
          end
        end
      end
    end
  end

  return items
end

--- Get list of local file completions for `< ./`
---@param bufnr integer
---@return table[]
local function get_file_completions(bufnr)
  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  local dir = (buf_path and buf_path ~= "") and vim.fs.dirname(buf_path) or vim.uv.cwd()
  local items = {}

  local handle = vim.uv.fs_scandir(dir)
  if handle then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if ftype == "file" and not name:match("^%.") then
        table.insert(items, make_completion_item(
          "./" .. name,
          Sources.kinds.File,
          "External payload file",
          "Include `" .. name .. "` as request body",
          "./" .. name
        ))
      end
    end
  end

  return items
end

--- Compute completion items for a position in buffer
---@param bufnr integer
---@param lnum integer 0-based line number
---@param col integer 0-based character column
---@return table
function M.get_completions(bufnr, lnum, col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line = lines[lnum + 1] or ""
  local prefix = line:sub(1, col)

  local items = {}

  -- 1. Check for template variable {{...}}
  local var_match = prefix:match("{{([%w_%.%-%$]*)$")
  if var_match then
    items = get_variable_completions(var_match, bufnr, lines)
    return { isIncomplete = false, items = items }
  end

  -- 2. Check for directive / metadata # @...
  if prefix:match("^%s*#%s*@?[%w_%-]*$") then
    local has_at = prefix:match("@")
    for _, dir in ipairs(Sources.directives) do
      local label = has_at and dir.name:gsub("^@", "") or dir.name
      local insert = has_at and dir.insert_text:gsub("^@", "") or dir.name
      table.insert(items, make_completion_item(
        label,
        Sources.kinds.Keyword,
        dir.detail,
        dir.doc,
        insert
      ))
    end
    return { isIncomplete = false, items = items }
  end

  -- 3. Check for external file include: < ./
  if prefix:match("^%s*<%s*%.?/?") then
    items = get_file_completions(bufnr)
    return { isIncomplete = false, items = items }
  end

  -- 4. Check for header value context
  local header_name, header_val_prefix = prefix:match("^%s*([%w_%-]+)%s*:%s*(.*)$")
  if header_name then
    local h_lower = header_name:lower()
    if h_lower == "content-type" or h_lower == "accept" then
      for _, mime in ipairs(Sources.mime_types) do
        table.insert(items, make_completion_item(
          mime.name,
          Sources.kinds.EnumMember,
          "MIME Media Type",
          mime.doc,
          mime.name
        ))
      end
      return { isIncomplete = false, items = items }
    elseif h_lower == "authorization" then
      for _, auth in ipairs(Sources.auth_schemes) do
        table.insert(items, make_completion_item(
          auth.name,
          Sources.kinds.EnumMember,
          "Auth Scheme",
          auth.doc,
          auth.insert_text
        ))
      end
      return { isIncomplete = false, items = items }
    end
  end

  -- 5. Determine if cursor is before request body (method or header line)
  -- Find the start of the current block
  local in_headers = false
  local is_method_line = false

  for i = lnum, 0, -1 do
    local l = lines[i + 1] or ""
    if l:match("^###") then
      if i == lnum then
        -- On the ### delimiter line itself
        return { isIncomplete = false, items = items }
      end
      break
    end
    local method_word = l:match("^%s*([A-Za-z]+)%s")
    local is_valid_m = method_word and (method_word == "GET" or method_word == "POST" or method_word == "PUT" or method_word == "PATCH" or method_word == "DELETE" or method_word == "HEAD" or method_word == "OPTIONS")
    if is_valid_m then
      if i == lnum then
        is_method_line = true
      else
        in_headers = true
      end
      break
    end
    if l:match("^%s*$") and i < lnum then
      -- Empty line after method line means we are in the body
      in_headers = false
      break
    end
  end

  -- 6. In headers section: offer header names
  if in_headers and not prefix:find(":") then
    for _, h in ipairs(Sources.headers) do
      table.insert(items, make_completion_item(
        h.name,
        Sources.kinds.Property,
        "HTTP Request Header",
        h.doc,
        h.insert_text
      ))
    end
    return { isIncomplete = false, items = items }
  end

  -- 7. At beginning of block / method line: offer HTTP methods & snippets
  if is_method_line or prefix:match("^%s*([A-Za-z]*)$") then
    for _, m in ipairs(Sources.methods) do
      table.insert(items, make_completion_item(
        m.name,
        Sources.kinds.Method,
        m.detail,
        m.doc,
        m.insert_text
      ))
    end

    -- Add block delimiter snippet
    table.insert(items, make_completion_item(
      "### New Request",
      Sources.kinds.Snippet,
      "Request Block Delimiter",
      "Creates a new request section with ### delimiter",
      "### ${1:Request Name}\n${2:GET} ${3:https://api.example.com}\n\n",
      true
    ))

    -- Add variable definition snippet
    table.insert(items, make_completion_item(
      "@var = value",
      Sources.kinds.Snippet,
      "Document Variable",
      "Declare an in-file variable at the top of the document",
      "@${1:variable} = ${2:value}\n",
      true
    ))
  end

  return { isIncomplete = false, items = items }
end

return M
