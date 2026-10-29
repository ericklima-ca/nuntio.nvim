if vim.g.loaded_nuntio then
  return
end
vim.g.loaded_nuntio = true

require("nuntio.ui.highlights").setup()
require("nuntio.ui.dividers").setup()
require("nuntio.lsp").setup()

local subcommands = {
  run = function() require("nuntio").run() end,
  run_all = function() require("nuntio").run_all() end,
  replay = function() require("nuntio").replay() end,
  inspect = function() require("nuntio").inspect() end,
  curl = function() require("nuntio").copy_as_curl() end,
  from_curl = function() require("nuntio").from_curl() end,
  env = function() require("nuntio").select_env() end,
  find = function(scope) require("nuntio").find_request(scope) end,
  next = function() require("nuntio").jump_next() end,
  prev = function() require("nuntio").jump_prev() end,
  scratchpad = function() require("nuntio").scratchpad() end,
  cookies = function() require("nuntio").cookies() end,
  history = function() require("nuntio.ui.history").open() end,
  diff = function() require("nuntio.ui.history").diff_previous() end,
  close = function() require("nuntio").close() end,
  toggle_view = function() require("nuntio").toggle_view() end,
  filter = function() require("nuntio").filter() end,
  filter_clear = function() require("nuntio").filter_clear() end,
  format = function() require("nuntio").format() end,
  clear_history = function() require("nuntio").clear_history() end,
  lsp_restart = function() require("nuntio.lsp").restart() end,
}

vim.api.nvim_create_user_command("Nuntio", function(opts)
  local arg = opts.fargs[1] or "run"
  local cmd = subcommands[arg]
  if cmd then
    local rest_args = {}
    for i = 2, #opts.fargs do
      table.insert(rest_args, opts.fargs[i])
    end
    cmd(unpack(rest_args))
  else
    vim.notify("nuntio: unknown subcommand: " .. arg, vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  complete = function(_, line)
    local words = vim.split(vim.trim(line), "%s+")
    if #words <= 1 or (#words == 2 and not line:match("%s$")) then
      return vim.tbl_keys(subcommands)
    elseif words[2] == "find" then
      return { "buffer", "workspace" }
    end
    return {}
  end,
  desc = "Nuntio HTTP Client",
})

vim.api.nvim_create_user_command("NuntioFormat", function(opts)
  local bufnr = opts.buf or vim.api.nvim_get_current_buf()
  require("nuntio").format(bufnr)
end, {
  desc = "Format .http document with Nuntio LSP formatter",
})
