local M = {}

---@class NuntioUIConfig
---@field display_mode? "split"|"float"
---@field split_direction? "right"|"below"|"left"|"above"
---@field width? number Float width fraction (0-1) or column count
---@field height? number Float height fraction (0-1) or line count
---@field default_view? "body"|"headers"|"headers_body"|"verbose"|"stats"
---@field winbar? boolean
---@field max_response_size? number Max bytes to display before truncating
---@field picker? "auto"|"telescope"|"snacks"|"fzf_lua"|"builtin"|"ui_select"
---@field find_scope? "buffer"|"workspace"

---@class NuntioLspConfig
---@field enable? boolean Enable in-process LSP server
---@field diagnostics? boolean Enable buffer diagnostics (missing files, undefined variables)
---@field completion? boolean Enable autocompletion (headers, methods, env vars, dynamic vars)
---@field hover? boolean Enable hover inspection
---@field document_symbols? boolean Enable document symbol outlines

---@class NuntioConfig
---@field default_env? string
---@field environment_scope? "b"|"g"
---@field curl_path? string
---@field timeout? number Request timeout in milliseconds
---@field additional_curl_args? string[]
---@field auto_run_dependencies? boolean Automatically execute prerequisite requests if not in history
---@field inlay_icons? boolean
---@field icons? { loading: string, done: string, error: string }
---@field dividers? { enabled?: boolean, icon?: string, shared_icon?: string, hint?: boolean, style?: "above" | "eol" | "both" }
---@field lsp? NuntioLspConfig
---@field ui? NuntioUIConfig

---@type NuntioConfig
M.defaults = {
  default_env = "dev",
  environment_scope = "b",
  auto_run_dependencies = true,
  curl_path = "curl",
  timeout = 60000,
  additional_curl_args = {},
  inlay_icons = true,
  icons = {
    loading = "⏳",
    done = "✔",
    error = "✘",
  },
  dividers = {
    enabled = true,
    icon = "󰖟",
    shared_icon = "󰒘",
    hint = true,
    style = "above",
  },
  lsp = {
    enable = true,
    diagnostics = true,
    completion = true,
    hover = true,
    document_symbols = true,
  },
  ui = {
    display_mode = "split",
    split_direction = "right",
    width = 0.45,
    height = 0.45,
    default_view = "body",
    winbar = true,
    max_response_size = 1048576, -- 1MB
    picker = "auto",
    find_scope = "buffer",
  },
}

---@type NuntioConfig
M.values = vim.deepcopy(M.defaults)

--- Setup user options
---@param user_opts? NuntioConfig
function M.setup(user_opts)
  if user_opts then
    M.values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts)
  else
    M.values = vim.deepcopy(M.defaults)
  end
end

--- Get current configuration
---@return NuntioConfig
function M.get()
  return M.values
end

return M
