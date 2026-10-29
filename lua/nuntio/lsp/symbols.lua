local Document = require("nuntio.parser.document")

local M = {}

local SymbolKind = {
  File = 1,
  Module = 2,
  Namespace = 3,
  Package = 4,
  Class = 5,
  Method = 6,
  Property = 7,
  Field = 8,
  Constructor = 9,
  Enum = 10,
  Interface = 11,
  Function = 12,
  Variable = 13,
  Constant = 14,
  String = 15,
  Number = 16,
  Boolean = 17,
  Array = 18,
  Object = 19,
  Key = 20,
  Null = 21,
  EnumMember = 22,
  Struct = 23,
  Event = 24,
  Operator = 25,
  TypeParameter = 26,
}

--- Format an LSP DocumentSymbol object
---@param name string
---@param kind integer
---@param detail string
---@param start_lnum integer 0-based
---@param end_lnum integer 0-based
---@param children? table[]
---@return table
local function make_symbol(name, kind, detail, start_lnum, end_lnum, children)
  return {
    name = name,
    detail = detail or "",
    kind = kind,
    range = {
      start = { line = math.max(0, start_lnum), character = 0 },
      ["end"] = { line = math.max(0, end_lnum), character = 0 },
    },
    selectionRange = {
      start = { line = math.max(0, start_lnum), character = 0 },
      ["end"] = { line = math.max(0, start_lnum), character = 0 },
    },
    children = children or {},
  }
end

--- Get all document symbols for buffer
---@param bufnr integer
---@return table[]
function M.get_symbols(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks, doc_vars = Document.parse_document(lines)

  local symbols = {}

  -- 1. Document variables module if any exist
  local var_keys = vim.tbl_keys(doc_vars or {})
  table.sort(var_keys)
  if #var_keys > 0 then
    local var_children = {}
    for _, k in ipairs(var_keys) do
      table.insert(var_children, make_symbol(
        "@" .. k,
        SymbolKind.Variable,
        tostring(doc_vars[k]),
        0,
        0
      ))
    end
    table.insert(symbols, make_symbol(
      "Document Variables",
      SymbolKind.Module,
      #var_keys .. " variables",
      0,
      #var_keys,
      var_children
    ))
  end

  -- 2. Request blocks
  for _, block in ipairs(blocks) do
    local s_line = (block.start_line or 1) - 1
    local e_line = (block.end_line or block.start_line or 1) - 1

    local title = ""
    local detail = block.url or ""

    if block.is_shared then
      title = "󰒘 Shared Defaults"
      detail = "Applied to all requests"
    else
      local req_name = block.name or (block.metadata and block.metadata.name)
      if req_name and req_name ~= "" then
        title = block.method .. " " .. req_name
      else
        local path = block.url:match("^https?://[^/]+(/.*)$") or block.url
        title = block.method .. " " .. path
      end
    end

    local children = {}

    -- Add Method child
    if block.method and not block.is_shared then
      table.insert(children, make_symbol(
        block.method,
        SymbolKind.Method,
        "HTTP Verb",
        s_line,
        s_line
      ))
    end

    -- Add URL child
    if block.url and block.url ~= "" then
      table.insert(children, make_symbol(
        block.url,
        SymbolKind.String,
        "Target URL",
        s_line,
        s_line
      ))
    end

    -- Add Headers
    if block.headers and #block.headers > 0 then
      for _, h in ipairs(block.headers) do
        table.insert(children, make_symbol(
          h.key,
          SymbolKind.Property,
          h.value,
          s_line,
          e_line
        ))
      end
    end

    -- Add Metadata / Directives
    if block.metadata then
      for k, v in pairs(block.metadata) do
        if v == true then
          table.insert(children, make_symbol("# @" .. k, SymbolKind.TypeParameter, "Flag", s_line, e_line))
        elseif type(v) == "string" then
          table.insert(children, make_symbol("# @" .. k, SymbolKind.TypeParameter, v, s_line, e_line))
        end
      end
    end

    table.insert(symbols, make_symbol(
      title,
      block.is_shared and SymbolKind.Interface or SymbolKind.Function,
      detail,
      s_line,
      e_line,
      children
    ))
  end

  return symbols
end

return M
