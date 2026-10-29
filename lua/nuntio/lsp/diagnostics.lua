local Document = require("nuntio.parser.document")
local Env = require("nuntio.env")

local M = {}

local diag_ns = vim.api.nvim_create_namespace("nuntio_lsp_diagnostics")

--- Extract all defined prompt/secret/env-key variables declared in metadata
---@param blocks NuntioBlock[]
---@return table<string, boolean>
local function get_metadata_declared_vars(blocks)
  local declared = {}
  for _, b in ipairs(blocks) do
    if b.metadata then
      for _, meta_type in ipairs({ "prompt", "secret", "env-json-key", "env-header-key" }) do
        if b.metadata[meta_type] then
          for _, item in ipairs(b.metadata[meta_type]) do
            local var_name = item:match("^([%w_%-]+)")
            if var_name and var_name ~= "" then
              declared[var_name] = true
            end
          end
        end
      end
    end
  end
  return declared
end

--- Get all named requests declared in the document
---@param blocks NuntioBlock[]
---@return table<string, boolean>
local function get_named_requests(blocks)
  local names = {}
  for _, b in ipairs(blocks) do
    if b.metadata and b.metadata.name then
      names[b.metadata.name] = true
    end
    if b.name and b.name ~= "" then
      names[b.name] = true
    end
  end
  return names
end

--- Run diagnostic checks on a buffer
---@param bufnr integer
function M.check(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks, doc_vars = Document.parse_document(lines)

  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  local buf_dir = (buf_path and buf_path ~= "") and vim.fs.dirname(buf_path) or vim.uv.cwd()

  local env_vars = Env.resolve(buf_dir, bufnr)
  local meta_vars = get_metadata_declared_vars(blocks)
  local named_requests = get_named_requests(blocks)

  local diagnostics = {}

  for lnum, line in ipairs(lines) do
    local l_idx = lnum - 1 -- 0-based for LSP diagnostics

    -- Skip comment lines (lines starting with # or //)
    if not (line:match("^%s*#") or line:match("^%s*//")) then
      -- 1. Check for missing external body files: `< ./file.json` or `file = < ./file.pdf`
      -- Only check lines that look like a body include (< path) or multipart field (= < path)
      local start_c, rel_path, end_c = line:match("()<%s*([%w_%-%./]+)()")
      if rel_path then
        rel_path = rel_path:gsub(";.*$", ""):gsub("%s+$", "")
        -- Only treat as file path if it starts with ./ or / or has an extension
        if rel_path:match("^%./") or rel_path:match("^/") or rel_path:match("%.%w+$") then
          local abs_path = vim.fs.normalize(vim.fs.joinpath(buf_dir, rel_path))
          if not vim.uv.fs_stat(abs_path) then
            table.insert(diagnostics, {
              bufnr = bufnr,
              lnum = l_idx,
              end_lnum = l_idx,
              col = (start_c or 1) - 1,
              end_col = (end_c or #line) - 1,
              severity = vim.diagnostic.severity.ERROR,
              source = "nuntio",
              message = "External file not found: '" .. rel_path .. "'",
            })
          end
        end
      end

      -- 2. Check for undefined template variables `{{var}}`
      for start_c, var_name, end_c in line:gmatch("()%{%{([^{}]+)%}()") do
        local v = vim.trim(var_name)
        -- Allow dynamic variables (start with $)
        local is_dynamic = v:sub(1, 1) == "$"

        -- Allow document variables
        local is_doc = doc_vars and doc_vars[v] ~= nil

        -- Allow environment variables
        local is_env = env_vars and env_vars[v] ~= nil

        -- Allow metadata-declared variables (# @prompt, # @secret, # @env-json-key, # @env-header-key)
        local is_meta = meta_vars[v] == true

        -- Allow chained request references: <req_name>.response...
        local is_chain = false
        local req_prefix = v:match("^([%w_%-]+)%.response%.")
        if req_prefix and named_requests[req_prefix] then
          is_chain = true
        end

        if not (is_dynamic or is_doc or is_env or is_meta or is_chain) then
          table.insert(diagnostics, {
            bufnr = bufnr,
            lnum = l_idx,
            end_lnum = l_idx,
            col = start_c - 1,
            end_col = end_c - 1,
            severity = vim.diagnostic.severity.WARN,
            source = "nuntio",
            message = "Undefined variable '{{" .. v .. "}}'. Define it in http-client.env.json, .env, or @" .. v .. " = <val>",
          })
        end
      end

      -- 3. Check for empty request URL: line with method but nothing else
      local m_word = line:match("^%s*([A-Za-z]+)%s*$")
      local is_m = m_word and (m_word == "GET" or m_word == "POST" or m_word == "PUT" or m_word == "PATCH" or m_word == "DELETE" or m_word == "HEAD" or m_word == "OPTIONS")
      if is_m then
        table.insert(diagnostics, {
          bufnr = bufnr,
          lnum = l_idx,
          end_lnum = l_idx,
          col = 0,
          end_col = #line,
          severity = vim.diagnostic.severity.ERROR,
          source = "nuntio",
          message = "Missing target URL for HTTP " .. m_word .. " request",
        })
      end
    end
  end

  vim.diagnostic.set(diag_ns, bufnr, diagnostics, {})
end

--- Debounce timer table per buffer
local debounce_timers = {}

--- Setup diagnostics listeners on buffer
---@param bufnr integer
function M.setup_buffer(bufnr)
  -- Initial check
  M.check(bufnr)

  local group = vim.api.nvim_create_augroup("NuntioLspDiagnostics_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if debounce_timers[bufnr] then
        debounce_timers[bufnr]:stop()
        debounce_timers[bufnr]:close()
      end
      local timer = vim.uv.new_timer()
      debounce_timers[bufnr] = timer
      timer:start(300, 0, vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          M.check(bufnr)
        end
        if debounce_timers[bufnr] == timer then
          debounce_timers[bufnr] = nil
        end
      end))
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      if debounce_timers[bufnr] then
        debounce_timers[bufnr]:stop()
        debounce_timers[bufnr]:close()
        debounce_timers[bufnr] = nil
      end
    end,
  })
end

--- Clear diagnostics for buffer
---@param bufnr integer
function M.clear(bufnr)
  vim.diagnostic.reset(diag_ns, bufnr)
end

return M
