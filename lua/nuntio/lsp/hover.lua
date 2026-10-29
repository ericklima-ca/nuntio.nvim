local Document = require("nuntio.parser.document")
local Dynamic = require("nuntio.parser.dynamic")
local Env = require("nuntio.env")
local JsonPath = require("nuntio.parser.jsonpath")
local Sources = require("nuntio.lsp.sources")
local Store = require("nuntio.store")

local M = {}

--- Find if cursor (0-based col) falls inside {{...}} on the line
---@param line string
---@param col integer
---@return string|nil var_name
local function find_template_var_at_col(line, col)
  -- 1-based index for Lua strings
  local c = col + 1
  for start_idx, var_name, end_idx in line:gmatch("()%{%{([^{}]+)%}()") do
    if c >= start_idx and c <= end_idx then
      return vim.trim(var_name)
    end
  end
  return nil
end

--- Get hover tooltip for a position in buffer
---@param bufnr integer
---@param lnum integer 0-based
---@param col integer 0-based
---@return table|nil
function M.get_hover(bufnr, lnum, col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line = lines[lnum + 1] or ""
  local buf_dir = vim.api.nvim_buf_get_name(bufnr)
  if buf_dir and buf_dir ~= "" then
    buf_dir = vim.fs.dirname(buf_dir)
  else
    buf_dir = vim.uv.cwd()
  end

  -- 1. Check if hovering inside {{...}}
  local var_name = find_template_var_at_col(line, col)
  if var_name then
    -- 1a. Dynamic generator {{$...}}
    if var_name:sub(1, 1) == "$" then
      for _, dyn in ipairs(Sources.dynamic_vars) do
        if var_name:match("^" .. vim.pesc(dyn.name)) then
          local preview = Dynamic.eval(dyn.name)
          local sample = preview and tostring(preview) or "generated value"
          local doc = dyn.doc .. "\n\n- **Evaluated now**: `" .. sample .. "`"
          return {
            contents = {
              kind = "markdown",
              value = doc,
            },
          }
        end
      end
    end

    -- 1b. Chained request variable {{req.response.body.$.path}}
    local req_name, resp_prop, json_path = var_name:match("^([%w_%-]+)%.response%.body%s*%.?(.*)$")
    if req_name then
      local resp = Store.get_named_response(req_name)
      if resp then
        local val = nil
        if json_path and json_path ~= "" then
          val = JsonPath.query(resp.body, json_path)
        else
          val = resp.body
        end
        local val_str = type(val) == "table" and vim.json.encode(val) or tostring(val or "nil")
        local doc = table.concat({
          "### 󰌷 Request Chain Variable",
          "- **Producer Request**: `" .. req_name .. "` (" .. (resp.method or "HTTP") .. " " .. (resp.url or "") .. ")",
          "- **Execution Status**: `✔ " .. tostring(resp.status or 200) .. " OK`",
          "- **Path**: `" .. (json_path or "body") .. "`",
          "- **Current Value**: `" .. val_str .. "`",
        }, "\n")
        return { contents = { kind = "markdown", value = doc } }
      else
        local doc = table.concat({
          "### 󰌷 Request Chain Variable",
          "- **Producer Request**: `" .. req_name .. "`",
          "- **Status**: ⏳ *Pending execution (will automatically run when request is sent)*",
          "- **Target Path**: `" .. (json_path or "body") .. "`",
        }, "\n")
        return { contents = { kind = "markdown", value = doc } }
      end
    end

    -- 1c. Document Variable (@var = value)
    local _, doc_vars = Document.parse_document(lines)
    if doc_vars and doc_vars[var_name] ~= nil then
      local doc = table.concat({
        "### 󰖟 Document Variable: `" .. var_name .. "`",
        "- **Value**: `" .. tostring(doc_vars[var_name]) .. "`",
        "- **Source**: In-file declaration (`@" .. var_name .. "` at top of file)",
      }, "\n")
      return { contents = { kind = "markdown", value = doc } }
    end

    -- 1d. Environment Variable
    local cur_env = Env.get_current_env(bufnr)
    local env_vars = Env.resolve(buf_dir, bufnr)
    if env_vars and env_vars[var_name] ~= nil then
      local doc = table.concat({
        "### 󰖟 Environment Variable: `" .. var_name .. "`",
        "- **Value**: `" .. tostring(env_vars[var_name]) .. "`",
        "- **Active Environment**: `" .. cur_env .. "`",
        "- **Priority Hierarchy**: Merged from `http-client.env.json` / `http-client.private.env.json` / `.env`",
      }, "\n")
      return { contents = { kind = "markdown", value = doc } }
    end

    -- 1e. Metadata Declared Variable (# @prompt, # @secret, # @env-json-key, # @env-header-key)
    local blocks = Document.parse_document(lines)
    for _, b in ipairs(blocks) do
      if b.metadata then
        if b.metadata["env-json-key"] then
          for _, item in ipairs(b.metadata["env-json-key"]) do
            local vn, path = item:match("^([%w_%-]+)%s*=?%s*(.*)$")
            if vn == var_name then
              local req_title = b.name or (b.metadata and b.metadata.name) or b.method .. " " .. b.url
              local doc = table.concat({
                "### 󰖟 Dynamic Environment Variable: `" .. var_name .. "`",
                "- **Declared By**: `# @env-json-key " .. item .. "`",
                "- **Producer Request**: `" .. req_title .. "`",
                "- **Path**: `" .. path .. "`",
                "- **Behavior**: Automatically extracted from JSON response into session environment",
              }, "\n")
              return { contents = { kind = "markdown", value = doc } }
            end
          end
        end
        if b.metadata["env-header-key"] then
          for _, item in ipairs(b.metadata["env-header-key"]) do
            local vn, header = item:match("^([%w_%-]+)%s*=?%s*(.*)$")
            if vn == var_name then
              local req_title = b.name or (b.metadata and b.metadata.name) or b.method .. " " .. b.url
              local doc = table.concat({
                "### 󰖟 Dynamic Header Variable: `" .. var_name .. "`",
                "- **Declared By**: `# @env-header-key " .. item .. "`",
                "- **Producer Request**: `" .. req_title .. "`",
                "- **Header**: `" .. header .. "`",
                "- **Behavior**: Automatically extracted from response header into session environment",
              }, "\n")
              return { contents = { kind = "markdown", value = doc } }
            end
          end
        end
        if b.metadata["prompt"] then
          for _, item in ipairs(b.metadata["prompt"]) do
            local vn, prompt_text = item:match("^([%w_%-]+)%s*(.*)$")
            if vn == var_name then
              local doc = table.concat({
                "### 󰖟 Interactive Prompt Variable: `" .. var_name .. "`",
                "- **Prompt Message**: `" .. (prompt_text ~= "" and prompt_text or var_name) .. "`",
                "- **Behavior**: Prompts interactively in Neovim before request execution",
              }, "\n")
              return { contents = { kind = "markdown", value = doc } }
            end
          end
        end
        if b.metadata["secret"] then
          for _, item in ipairs(b.metadata["secret"]) do
            local vn, prompt_text = item:match("^([%w_%-]+)%s*(.*)$")
            if vn == var_name then
              local doc = table.concat({
                "### 󰖟 Interactive Secret Variable: `" .. var_name .. "`",
                "- **Prompt Message**: `" .. (prompt_text ~= "" and prompt_text or var_name) .. "`",
                "- **Behavior**: Prompts with masked password input before request execution (never stored on disk)",
              }, "\n")
              return { contents = { kind = "markdown", value = doc } }
            end
          end
        end
      end
    end

    -- Undefined variable
    local doc = table.concat({
      "### ⚠️ Undefined Variable: `" .. var_name .. "`",
      "No matching variable found in active environment `" .. cur_env .. "` or in-file `@` declarations.",
      "",
      "To resolve, define it in:",
      "1. `http-client.env.json` or `.env`",
      "2. Top of this file: `@`" .. var_name .. " = <value>",
      "3. Directives: `# @env-json-key " .. var_name .. " = <path>`",
    }, "\n")
    return { contents = { kind = "markdown", value = doc } }
  end

  -- 2. Check for ### Shared block
  if line:match("^###%s*Shared") then
    local doc = table.concat({
      "### 󰒘 Shared Configuration Block",
      "Headers and variables declared under `### Shared` are automatically merged into every request executed in this file.",
      "",
      "- **Headers**: Injected into all requests unless overridden on the individual request.",
      "- **Variables**: Merged into the document scope.",
      "- **Execution Guard**: This block cannot be run directly (does not send HTTP requests).",
    }, "\n")
    return { contents = { kind = "markdown", value = doc } }
  end

  -- 3. Check for directive # @...
  local directive_name = line:match("^%s*#%s*(@?[%w_%-]+)")
  if directive_name then
    if not directive_name:match("^@") then directive_name = "@" .. directive_name end
    for _, dir in ipairs(Sources.directives) do
      if dir.name == directive_name then
        return {
          contents = {
            kind = "markdown",
            value = "### Directive: `" .. dir.name .. "`\n\n" .. dir.doc,
          },
        }
      end
    end
  end

  -- 4. Check for HTTP Method at cursor
  local method = line:match("^%s*([A-Z]+)%s")
  if method then
    for _, m in ipairs(Sources.methods) do
      if m.name == method then
        return {
          contents = {
            kind = "markdown",
            value = "### HTTP Method: `" .. m.name .. "`\n\n" .. m.doc,
          },
        }
      end
    end
  end

  -- 5. Check for HTTP Header name
  local header = line:match("^%s*([%w_%-]+)%s*:")
  if header then
    for _, h in ipairs(Sources.headers) do
      if h.name:lower() == header:lower() then
        return {
          contents = {
            kind = "markdown",
            value = "### HTTP Header: `" .. h.name .. "`\n\n" .. h.doc,
          },
        }
      end
    end
  end

  return nil
end

return M
