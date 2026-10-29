local CodeActions = require("nuntio.lsp.code_actions")
local Completion = require("nuntio.lsp.completion")
local Hover = require("nuntio.lsp.hover")
local Symbols = require("nuntio.lsp.symbols")

local M = {}

--- Resolve URI to valid buffer number, supporting unnamed/scratch buffers
---@param uri string|nil
---@return integer
local function resolve_bufnr(uri)
  if not uri or uri == "file://" or uri:match("^file:///?$") then
    return vim.api.nvim_get_current_buf()
  end
  local b = vim.uri_to_bufnr(uri)
  if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_line_count(b) > 0 then
    return b
  end
  -- Check if any loaded buffer matches this URI
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.uri_from_bufnr(buf) == uri then
      return buf
    end
  end
  return b
end

--- Create a new in-process LSP RPC server dispatcher
---@return fun(dispatchers: table): table
function M.create_server()
  local handlers = {
    ["initialize"] = function(params)
      return {
        serverInfo = {
          name = "nuntio-lsp",
          version = "1.0.0",
        },
        capabilities = {
          completionProvider = {
            triggerCharacters = { "@", "#", "{", "$", ":", "<", "/", ".", "-" },
            resolveProvider = false,
          },
          hoverProvider = true,
          documentSymbolProvider = true,
          codeActionProvider = true,
          documentFormattingProvider = true,
          executeCommandProvider = {
            commands = {
              "nuntio.run",
              "nuntio.run_all",
              "nuntio.copy_curl",
              "nuntio.inspect",
              "nuntio.select_env",
              "nuntio.cookies",
              "nuntio.history",
            },
          },
        },
      }
    end,

    ["textDocument/completion"] = function(params)
      local uri = params.textDocument and params.textDocument.uri
      local bufnr = resolve_bufnr(uri)
      local lnum = params.position and params.position.line or 0
      local col = params.position and params.position.character or 0
      return Completion.get_completions(bufnr, lnum, col)
    end,

    ["textDocument/hover"] = function(params)
      local uri = params.textDocument and params.textDocument.uri
      local bufnr = resolve_bufnr(uri)
      local lnum = params.position and params.position.line or 0
      local col = params.position and params.position.character or 0
      return Hover.get_hover(bufnr, lnum, col)
    end,

    ["textDocument/documentSymbol"] = function(params)
      local uri = params.textDocument and params.textDocument.uri
      local bufnr = resolve_bufnr(uri)
      return Symbols.get_symbols(bufnr)
    end,

    ["textDocument/codeAction"] = function(params)
      local uri = params.textDocument and params.textDocument.uri
      local bufnr = resolve_bufnr(uri)
      local lnum = params.range and params.range.start and params.range.start.line or 0
      return CodeActions.get_code_actions(bufnr, lnum)
    end,

    ["textDocument/formatting"] = function(params)
      local uri = params.textDocument and params.textDocument.uri
      local bufnr = resolve_bufnr(uri)
      local Formatter = require("nuntio.lsp.formatter")
      return Formatter.format_document(bufnr, params.options)
    end,

    ["workspace/executeCommand"] = function(params)
      if params.command then
        CodeActions.execute_command(params.command)
      end
      return nil
    end,

    ["shutdown"] = function()
      return nil
    end,
  }

  return function(dispatchers)
    local closing = false
    local req_seq = 0
    local srv = {}

    function srv.request(method, params, handler, notify_reply_callback)
      req_seq = req_seq + 1
      local req_id = req_seq

      local function dispatch()
        if closing then return end

        local ok, res = pcall(function()
          local h = handlers[method]
          if h then
            return h(params)
          end
          return nil
        end)

        if not ok then
          vim.notify("nuntio-lsp error in " .. method .. ": " .. tostring(res), vim.log.levels.ERROR)
          handler(tostring(res), nil)
        else
          handler(nil, res)
        end

        if notify_reply_callback then
          notify_reply_callback(req_id)
        end
      end

      if method == "initialize" then
        dispatch()
      else
        vim.schedule(dispatch)
      end

      return true, req_id
    end

    function srv.notify(method, _)
      if method == "exit" then
        dispatchers.on_exit(0, 15)
      end
    end

    function srv.is_closing()
      return closing
    end

    function srv.terminate()
      closing = true
    end

    return srv
  end
end

return M
