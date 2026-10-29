local Config = require("nuntio.config")

local M = {}

function M.check()
  vim.health.start("nuntio.nvim")

  -- 1. Neovim version check
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok(string.format("Neovim version: %s (>= 0.10 supported)", vim.version()))
  else
    vim.health.error("nuntio.nvim requires Neovim >= 0.10")
  end

  -- 2. curl executable check
  local curl_bin = Config.get().curl_path or "curl"
  if vim.fn.executable(curl_bin) == 1 then
    local curl_ver = vim.fn.system({ curl_bin, "--version" }):match("curl ([%d%.]+)")
    vim.health.ok(string.format("curl executable found: %s (%s)", curl_bin, curl_ver or "version unknown"))
  else
    vim.health.error(string.format("curl executable not found at '%s'. Required to make HTTP requests.", curl_bin))
  end

  -- 3. jq executable check (optional but recommended)
  if vim.fn.executable("jq") == 1 then
    vim.health.ok("jq executable found (used for response JSON formatting and # @jq filters)")
  else
    vim.health.warn("jq executable not found. JSON formatting will use fallback vim.json and # @jq directive will be disabled.")
  end

  -- 4. Tree-sitter http grammar check
  local has_ts, _ = pcall(vim.treesitter.get_parser, 0, "http")
  local ts_installed = false
  for _, path in ipairs(vim.api.nvim_get_runtime_file("parser/http.so", true)) do
    if path and path ~= "" then
      ts_installed = true
      break
    end
  end
  if ts_installed then
    vim.health.ok("Tree-sitter 'http' grammar parser is installed for syntax highlighting.")
  else
    vim.health.warn("Tree-sitter 'http' grammar parser not found. Run ':TSInstall http' to enable full highlighting.")
  end

  -- 5. Load testing backends
  local limits = Config.get().load.curl
  vim.health.info(string.format(
    "Load tests use the curl backend: one process per request, limits concurrency=%d, requests=%d, duration=%ds (opts.load.curl)",
    limits.max_concurrency, limits.max_requests, limits.max_duration))
  local tools = {}
  for _, tool in ipairs({ "oha", "vegeta", "k6" }) do
    if vim.fn.executable(tool) == 1 then
      table.insert(tools, tool)
    end
  end
  if #tools > 0 then
    vim.health.ok("Dedicated load tools available for high-throughput tests: " .. table.concat(tools, ", "))
  else
    vim.health.info("No dedicated load tool found (oha, vegeta, k6). Install one for tests beyond a few hundred req/s.")
  end

  -- 6. In-process LSP Server check
  local lsp_cfg = Config.get().lsp or {}
  if lsp_cfg.enable ~= false then
    local active_clients = vim.lsp.get_clients({ name = "nuntio-lsp" })
    vim.health.ok(string.format("In-process LSP server 'nuntio-lsp' enabled (%d active client sessions)", #active_clients))
  else
    vim.health.info("In-process LSP server disabled via config (opts.lsp.enable = false)")
  end
end

return M
