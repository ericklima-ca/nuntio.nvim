local Document = require("nuntio.parser.document")

local M = {}

--- Get available code actions for buffer position
---@param bufnr integer
---@param lnum integer 0-based
---@return table[]
function M.get_code_actions(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = Document.parse_document(lines)
  local block = Document.get_block_at_line(blocks, lnum + 1)

  local actions = {}

  if block and not block.is_shared then
    local target_name = block.name or (block.metadata and block.metadata.name) or block.method .. " " .. block.url
    table.insert(actions, {
      title = "▶ Nuntio: Run " .. target_name,
      kind = "quickfix",
      command = {
        title = "Run Request",
        command = "nuntio.run",
      },
    })
    table.insert(actions, {
      title = "📋 Nuntio: Copy as cURL",
      kind = "refactor",
      command = {
        title = "Copy cURL",
        command = "nuntio.copy_curl",
      },
    })
    table.insert(actions, {
      title = "🔍 Nuntio: Inspect resolved request",
      kind = "refactor",
      command = {
        title = "Inspect Request",
        command = "nuntio.inspect",
      },
    })
  end

  table.insert(actions, {
    title = "▶ Nuntio: Run all requests",
    kind = "source",
    command = {
      title = "Run All",
      command = "nuntio.run_all",
    },
  })
  table.insert(actions, {
    title = "🌐 Nuntio: Switch environment",
    kind = "source",
    command = {
      title = "Select Environment",
      command = "nuntio.select_env",
    },
  })
  table.insert(actions, {
    title = "🍪 Nuntio: Open cookie jar",
    kind = "source",
    command = {
      title = "Open Cookies",
      command = "nuntio.cookies",
    },
  })
  table.insert(actions, {
    title = "📜 Nuntio: Response history",
    kind = "source",
    command = {
      title = "Response History",
      command = "nuntio.history",
    },
  })

  return actions
end

--- Execute a code action command
---@param cmd string
function M.execute_command(cmd)
  if cmd == "nuntio.run" then
    require("nuntio").run()
  elseif cmd == "nuntio.run_all" then
    require("nuntio").run_all()
  elseif cmd == "nuntio.copy_curl" then
    require("nuntio").copy_as_curl()
  elseif cmd == "nuntio.inspect" then
    require("nuntio").inspect()
  elseif cmd == "nuntio.select_env" then
    require("nuntio").select_env()
  elseif cmd == "nuntio.cookies" then
    require("nuntio").cookies()
  elseif cmd == "nuntio.history" then
    require("nuntio.ui.history").open()
  end
end

return M
