local Config = require("nuntio.config")
local Diagnostics = require("nuntio.lsp.diagnostics")
local Server = require("nuntio.lsp.server")

local M = {}

M.SERVER_NAME = "nuntio-lsp"

--- Check if nuntio-lsp is attached to buffer
---@param bufnr integer
---@return integer|nil client_id
function M.get_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = M.SERVER_NAME })
  if #clients > 0 then
    return clients[1].id
  end
  return nil
end

--- Attach in-process LSP client to buffer
---@param bufnr? integer
---@return integer|nil client_id
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end

  local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if ft ~= "http" and ft ~= "rest" then return nil end

  local cfg = Config.get()
  local lsp_cfg = cfg.lsp or {}
  if lsp_cfg.enable == false then return nil end

  -- Avoid starting multiple instances on the same buffer
  local existing = M.get_client(bufnr)
  if existing then
    return existing
  end

  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  local root_dir = (buf_name and buf_name ~= "") and vim.fs.dirname(buf_name) or vim.uv.cwd()

  local client_id = vim.lsp.start({
    name = M.SERVER_NAME,
    cmd = Server.create_server(),
    root_dir = root_dir,
    bufnr = bufnr,
    on_attach = function(client, b)
      if lsp_cfg.diagnostics ~= false then
        Diagnostics.setup_buffer(b)
      end
    end,
  })

  return client_id
end

--- Restart LSP across all http buffers
function M.restart()
  local clients = vim.lsp.get_clients({ name = M.SERVER_NAME })
  for _, c in ipairs(clients) do
    c:stop()
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      if ft == "http" or ft == "rest" then
        M.attach(bufnr)
      end
    end
  end
  vim.notify("nuntio-lsp: restarted in-process language server", vim.log.levels.INFO)
end

--- Setup autocmds for automatic LSP attachment
function M.setup()
  local cfg = Config.get()
  local lsp_cfg = cfg.lsp or {}
  if lsp_cfg.enable == false then return end

  local group = vim.api.nvim_create_augroup("NuntioLspAutoAttach", { clear = true })
  vim.api.nvim_create_autocmd({ "FileType" }, {
    group = group,
    pattern = { "http", "rest" },
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })

  -- Attach to any currently open buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      if ft == "http" or ft == "rest" then
        M.attach(bufnr)
      end
    end
  end
end

return M
