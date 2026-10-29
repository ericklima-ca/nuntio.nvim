local Document = require("nuntio.parser.document")
local Env = require("nuntio.env")
local Highlights = require("nuntio.ui.highlights")

local M = {}

--- Open environment selector
---@param bufnr? integer
---@param on_select? fun(env: string)
function M.select_env(bufnr, on_select)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local dir = vim.fn.expand("%:p:h")
  local envs = Env.list_available_envs(dir)
  local current = Env.get_current_env(bufnr)

  local items = {}
  for _, e in ipairs(envs) do
    if e == current then
      table.insert(items, e .. " (current)")
    else
      table.insert(items, e)
    end
  end

  vim.ui.select(items, {
    prompt = "Select HTTP Environment:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not choice then return end
    local selected = choice:gsub("%s*%(current%)", "")
    Env.set_env(selected, bufnr)
    vim.notify(string.format("nuntio: environment set to '%s'", selected), vim.log.levels.INFO)
    if on_select then
      on_select(selected)
    end
  end)
end

--- Select request from document blocks to jump to (Legacy / basic vim.ui.select fallback)
---@param blocks NuntioBlock[]
---@param on_select fun(block: NuntioBlock)
function M.select_request(blocks, on_select)
  if not blocks or #blocks == 0 then
    vim.notify("nuntio: no requests found in document", vim.log.levels.WARN)
    return
  end

  local items = {}
  for _, b in ipairs(blocks) do
    local label = string.format("[%d] %s %s%s",
      b.start_line,
      b.method,
      b.url ~= "" and b.url or "(no url)",
      b.name and (" (" .. b.name .. ")") or ""
    )
    table.insert(items, { label = label, block = b })
  end

  vim.ui.select(items, {
    prompt = "Find Request:",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice and on_select then
      on_select(choice.block)
    end
  end)
end

--- Parse blocks and document variables from file or buffer
---@param filepath? string
---@param bufnr? integer
---@return NuntioBlock[] runnable_blocks, table<string, string> doc_vars, NuntioBlock|nil shared_block, string[] lines
local function parse_file_blocks(filepath, bufnr)
  local lines = {}
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  elseif filepath and filepath ~= "" and vim.fn.filereadable(filepath) == 1 then
    lines = vim.fn.readfile(filepath)
  else
    return {}, {}, nil, {}
  end

  local all_blocks, doc_vars = Document.parse_document(lines)
  local runnable_blocks = {}
  local shared_block = nil
  for _, b in ipairs(all_blocks) do
    if b.is_shared then
      shared_block = b
    else
      table.insert(runnable_blocks, b)
    end
  end
  return runnable_blocks, doc_vars, shared_block, lines
end

--- Build rich picker items from parsed blocks
---@param runnable_blocks NuntioBlock[]
---@param doc_vars table<string, string>
---@param shared_block? NuntioBlock
---@param lines string[]
---@param filepath? string
---@param bufnr? integer
---@return table[]
local function build_items_from_blocks(runnable_blocks, doc_vars, shared_block, lines, filepath, bufnr)
  local items = {}
  local rel_path = (filepath and filepath ~= "") and vim.fn.fnamemodify(filepath, ":.") or "buffer"

  for _, b in ipairs(runnable_blocks) do
    local preview_lines = {}
    local name_suffix = b.name and (" — " .. b.name) or ""
    table.insert(preview_lines, string.format("# ─── %s %s%s ───", b.method, b.url ~= "" and b.url or "(no url)", name_suffix))
    table.insert(preview_lines, string.format("# File: %s:%d", rel_path, b.start_line))
    table.insert(preview_lines, "# Keys: <CR> Jump  │  <C-r> Run  │  <Tab> Scope  │  <Esc> Quit")
    table.insert(preview_lines, "")

    for l = b.start_line, b.end_line do
      if lines[l] then
        table.insert(preview_lines, lines[l])
      end
    end

    local name_str = b.name and ("#" .. b.name) or ""
    local label = string.format("%-7s %-20s %s (%s:%d)",
      b.method,
      name_str,
      b.url ~= "" and b.url or "(no url)",
      rel_path,
      b.start_line
    )

    table.insert(items, {
      id = string.format("%s:%d", filepath or tostring(bufnr or 0), b.start_line),
      method = b.method,
      url = b.url,
      name = b.name,
      start_line = b.start_line,
      end_line = b.end_line,
      filepath = filepath or "",
      rel_path = rel_path,
      bufnr = bufnr,
      block = b,
      doc_vars = doc_vars,
      shared_block = shared_block,
      all_blocks = runnable_blocks,
      preview_lines = preview_lines,
      label = label,
    })
  end

  return items
end

--- Scan workspace for all .http and .rest files
---@return string[]
local function scan_workspace_files()
  local cwd = vim.uv.cwd()
  local seen = {}
  local files = {}

  -- 1. Check open buffers with filetype == "http"
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "http" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and not seen[name] then
        seen[name] = true
        table.insert(files, name)
      end
    end
  end

  -- 2. Find files in project directory, excluding noisy build/cache trees
  local found = vim.fs.find(function(name, path)
    if path:match("[/\\]%.git[/\\]")
      or path:match("[/\\]node_modules[/\\]")
      or path:match("[/\\]%.venv[/\\]")
      or path:match("[/\\]%.cargo[/\\]")
      or path:match("[/\\]dist[/\\]")
      or path:match("[/\\]build[/\\]")
      or path:match("[/\\]target[/\\]")
      or path:match("[/\\]vendor[/\\]")
    then
      return false
    end
    return name:match("%.http$") or name:match("%.rest$")
  end, {
    path = cwd,
    type = "file",
    limit = 200,
  })

  for _, f in ipairs(found) do
    local norm = vim.fs.normalize(f)
    if not seen[norm] then
      seen[norm] = true
      table.insert(files, norm)
    end
  end

  return files
end

--- Collect requests across buffer or workspace
---@param scope? "buffer"|"workspace"
---@param bufnr? integer
---@return table[] items
function M.collect_requests(scope, bufnr)
  scope = scope or "buffer"
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if scope == "workspace" then
    local files = scan_workspace_files()
    local all_items = {}

    -- Map open buffers by normalized path for live buffer content
    local buf_map = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        local bname = vim.api.nvim_buf_get_name(b)
        if bname ~= "" then
          buf_map[vim.fs.normalize(bname)] = b
        end
      end
    end

    for _, f in ipairs(files) do
      local b_id = buf_map[vim.fs.normalize(f)]
      local runnable, doc_vars, shared, lines = parse_file_blocks(f, b_id)
      local items = build_items_from_blocks(runnable, doc_vars, shared, lines, f, b_id)
      for _, it in ipairs(items) do
        table.insert(all_items, it)
      end
    end

    return all_items
  else
    -- Buffer scope
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local runnable, doc_vars, shared, lines = parse_file_blocks(filepath, bufnr)
    return build_items_from_blocks(runnable, doc_vars, shared, lines, filepath, bufnr)
  end
end

--- Jump cursor to request block location
---@param item table
function M.jump_to(item)
  if not item then return end
  if item.filepath and item.filepath ~= "" then
    local cur_name = vim.api.nvim_buf_get_name(0)
    if vim.fs.normalize(cur_name) ~= vim.fs.normalize(item.filepath) then
      vim.cmd("edit " .. vim.fn.fnameescape(item.filepath))
    end
  elseif item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
    vim.api.nvim_set_current_buf(item.bufnr)
  end

  pcall(vim.api.nvim_win_set_cursor, 0, { item.start_line, 0 })
  vim.cmd("normal! zz")
end

--- Execute request block directly from picker
---@param item table
function M.run_item(item)
  if not item then return end
  local Runner = require("nuntio.runner")

  local target_buf = item.bufnr
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    if item.filepath and item.filepath ~= "" then
      target_buf = vim.fn.bufadd(item.filepath)
      vim.fn.bufload(target_buf)
    else
      target_buf = vim.api.nvim_get_current_buf()
    end
  end

  local buffer_dir = ""
  if item.filepath and item.filepath ~= "" then
    buffer_dir = vim.fn.fnamemodify(item.filepath, ":h")
  else
    buffer_dir = vim.fn.expand("%:p:h")
  end
  if not buffer_dir or buffer_dir == "" then buffer_dir = vim.uv.cwd() end

  vim.notify(string.format("nuntio: executing [%s] %s", item.method, item.name or item.url), vim.log.levels.INFO)
  Runner.run_block(item.block, item.doc_vars, target_buf, buffer_dir, item.shared_block, nil, item.all_blocks)
end

--- Telescope picker integration
---@param items table[]
---@param opts table
---@return boolean success
function M.pick_telescope(items, opts)
  local ok, _ = pcall(require, "telescope")
  if not ok then return false end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")
  local entry_display = require("telescope.pickers.entry_display")

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 8 },        -- Method badge
      { width = 22 },       -- Name
      { remaining = true }, -- URL & location
    },
  })

  local function make_display(entry)
    local it = entry.value
    local method_hl = Highlights.get_method_hl(it.method)
    local name_str = it.name and ("#" .. it.name) or ""
    local url_str = (it.url ~= "" and it.url or "(no url)")
    if opts.scope == "workspace" and it.rel_path then
      url_str = string.format("%s  (%s:%d)", url_str, it.rel_path, it.start_line)
    end

    return displayer({
      { string.format("[%s]", it.method), method_hl },
      { name_str, "NuntioDocVar" },
      { url_str, "NuntioUrl" },
    })
  end

  local finder = finders.new_table({
    results = items,
    entry_maker = function(it)
      return {
        value = it,
        display = make_display,
        ordinal = string.format("%s %s %s %s", it.method, it.name or "", it.url, it.rel_path or ""),
        path = it.filepath,
        lnum = it.start_line,
      }
    end,
  })

  local previewer = previewers.new_buffer_previewer({
    title = "Request Preview",
    define_preview = function(self, entry)
      local it = entry.value
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, it.preview_lines or {})
      vim.bo[self.state.bufnr].filetype = "http"
    end,
  })

  pickers.new(opts or {}, {
    prompt_title = string.format("Nuntio Requests [%s]", opts.scope or "buffer"),
    finder = finder,
    sorter = conf.generic_sorter(opts or {}),
    previewer = previewer,
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection and selection.value then
          M.jump_to(selection.value)
        end
      end)

      local function run_selection()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection and selection.value then
          M.run_item(selection.value)
        end
      end

      map("i", "<C-r>", run_selection)
      map("n", "<C-r>", run_selection)
      map("i", "<C-e>", run_selection)
      map("n", "<C-e>", run_selection)
      return true
    end,
  }):find()

  return true
end

--- Snacks.picker integration
---@param items table[]
---@param opts table
---@return boolean success
function M.pick_snacks(items, opts)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then return false end

  local snack_items = {}
  for _, it in ipairs(items) do
    table.insert(snack_items, {
      text = string.format("%s %s %s %s", it.method, it.name or "", it.url, it.rel_path or ""),
      file = it.filepath,
      pos = { it.start_line, 0 },
      item = it,
    })
  end

  snacks.picker({
    title = string.format("Nuntio Requests [%s]", opts.scope or "buffer"),
    items = snack_items,
    format = function(entry)
      local it = entry.item
      local method_hl = Highlights.get_method_hl(it.method)
      local chunks = {
        { string.format("[%-6s] ", it.method), method_hl },
      }
      if it.name then
        table.insert(chunks, { "#" .. it.name .. " ", "NuntioDocVar" })
      end
      table.insert(chunks, { it.url ~= "" and it.url or "(no url)", "NuntioUrl" })
      if opts.scope == "workspace" and it.rel_path then
        table.insert(chunks, { string.format("  (%s:%d)", it.rel_path, it.start_line), "Comment" })
      end
      return chunks
    end,
    preview = function(ctx)
      local it = ctx.item.item
      ctx.preview:set_lines(it.preview_lines or {})
      ctx.preview:highlight({ ft = "http" })
    end,
    confirm = function(picker, entry)
      picker:close()
      if entry and entry.item then
        M.jump_to(entry.item)
      end
    end,
    actions = {
      run = function(picker, entry)
        picker:close()
        if entry and entry.item then
          M.run_item(entry.item)
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-r>"] = { "run", desc = "Run Request", mode = { "n", "i" } },
          ["<C-e>"] = { "run", desc = "Run Request", mode = { "n", "i" } },
        },
      },
    },
  })
  return true
end

--- FZF-Lua integration
---@param items table[]
---@param opts table
---@return boolean success
function M.pick_fzf(items, opts)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then return false end

  local entries = {}
  local map = {}
  for i, it in ipairs(items) do
    local key = string.format("%d: [%-6s] %s %s (%s:%d)",
      i,
      it.method,
      it.name and ("#" .. it.name) or "",
      it.url ~= "" and it.url or "(no url)",
      it.rel_path or "buffer",
      it.start_line
    )
    table.insert(entries, key)
    map[key] = it
  end

  fzf.fzf_exec(entries, {
    prompt = string.format("Nuntio Requests [%s]> ", opts.scope or "buffer"),
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] and map[selected[1]] then
          M.jump_to(map[selected[1]])
        end
      end,
      ["ctrl-r"] = function(selected)
        if selected and selected[1] and map[selected[1]] then
          M.run_item(map[selected[1]])
        end
      end,
    },
  })
  return true
end

--- Built-in standard vim.ui.select picker
---@param items table[]
---@param opts table
function M.pick_ui_select(items, opts)
  local formatted = {}
  for _, it in ipairs(items) do
    local name_str = it.name and (" #" .. it.name) or ""
    local label = string.format("[%-6s]%s %s (%s:%d)",
      it.method,
      name_str,
      it.url ~= "" and it.url or "(no url)",
      it.rel_path or "buffer",
      it.start_line
    )
    table.insert(formatted, { label = label, item = it })
  end

  vim.ui.select(formatted, {
    prompt = string.format("Nuntio Requests [%s]:", opts.scope or "buffer"),
    format_item = function(e) return e.label end,
  }, function(choice)
    if choice and choice.item then
      M.jump_to(choice.item)
    end
  end)
end

--- Pure-Lua built-in dual-pane interactive floating picker with live preview
---@param initial_items table[]
---@param opts table
function M.pick_builtin(initial_items, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local scope = opts.scope or "buffer"
  local all_items = initial_items

  if #all_items == 0 then
    vim.notify("nuntio: no requests found in " .. scope, vim.log.levels.WARN)
    return
  end

  local query = ""
  local filtered_items = vim.deepcopy(all_items)
  local selected_idx = 1

  -- Responsive geometry
  local cols = vim.o.columns
  local lines = vim.o.lines
  local total_w = math.min(150, math.max(70, math.floor(cols * 0.85)))
  local total_h = math.min(38, math.max(14, math.floor(lines * 0.75)))
  local row = math.floor((lines - total_h) / 2)
  local col = math.floor((cols - total_w) / 2)

  local left_w = math.floor(total_w * 0.44)
  local right_w = total_w - left_w - 2
  local list_h = total_h - 4

  -- Allocate Buffers
  local prompt_buf = vim.api.nvim_create_buf(false, true)
  local list_buf = vim.api.nvim_create_buf(false, true)
  local prev_buf = vim.api.nvim_create_buf(false, true)

  for _, b in ipairs({ prompt_buf, list_buf, prev_buf }) do
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
  end

  -- Prompt Window
  local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = left_w,
    height = 1,
    border = "rounded",
    title = string.format(" 󰈲 Nuntio Requests [%s] ", scope),
    title_pos = "left",
    footer = " <Tab> Scope ",
    footer_pos = "right",
  })

  -- List Window
  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative = "editor",
    row = row + 3,
    col = col,
    width = left_w,
    height = list_h,
    border = "rounded",
    title = string.format(" Requests (%d) ", #filtered_items),
    title_pos = "left",
  })

  -- Preview Window
  local prev_win = vim.api.nvim_open_win(prev_buf, false, {
    relative = "editor",
    row = row,
    col = col + left_w + 2,
    width = right_w,
    height = total_h,
    border = "rounded",
    title = " Request Preview ",
    title_pos = "left",
    footer = " [<CR> Jump │ <C-r> Run │ <Esc> Quit] ",
    footer_pos = "right",
  })

  for _, w in ipairs({ prompt_win, list_win, prev_win }) do
    vim.wo[w].wrap = false
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].cursorline = false
  end

  local is_closing = false
  local function close_all()
    if is_closing then return end
    is_closing = true
    vim.cmd("stopinsert")
    for _, w in ipairs({ prompt_win, list_win, prev_win }) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end

  local ns = vim.api.nvim_create_namespace("nuntio_picker_builtin")

  local function render_preview()
    if not vim.api.nvim_buf_is_valid(prev_buf) then return end
    vim.bo[prev_buf].modifiable = true
    if #filtered_items > 0 and filtered_items[selected_idx] then
      local cur = filtered_items[selected_idx]
      vim.api.nvim_buf_set_lines(prev_buf, 0, -1, false, cur.preview_lines)
      vim.bo[prev_buf].filetype = "http"
    else
      vim.api.nvim_buf_set_lines(prev_buf, 0, -1, false, { "", "  No requests matching filter", "" })
    end
    vim.bo[prev_buf].modifiable = false
  end

  local function render_list()
    if not vim.api.nvim_buf_is_valid(list_buf) then return end
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)

    local display_lines = {}
    for idx, it in ipairs(filtered_items) do
      local is_sel = (idx == selected_idx)
      local prefix = is_sel and "❯ " or "  "
      local name_part = it.name and ("#" .. it.name .. " ") or ""
      local line_text = string.format("%s[%-6s] %s%s", prefix, it.method, name_part, it.url ~= "" and it.url or "(no url)")
      if scope == "workspace" and it.rel_path then
        line_text = line_text .. " (" .. it.rel_path .. ":" .. it.start_line .. ")"
      end
      table.insert(display_lines, line_text)
    end

    if #display_lines == 0 then
      table.insert(display_lines, "  (No matching requests)")
    end

    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, display_lines)

    -- Apply highlights
    for idx, it in ipairs(filtered_items) do
      local line_idx = idx - 1
      local is_sel = (idx == selected_idx)
      local method_hl = Highlights.get_method_hl(it.method)

      pcall(vim.api.nvim_buf_set_extmark, list_buf, ns, line_idx, 2, {
        end_col = 10,
        hl_group = method_hl,
      })

      if is_sel then
        pcall(vim.api.nvim_buf_set_extmark, list_buf, ns, line_idx, 0, {
          end_col = 2,
          hl_group = "NuntioBadgeAmber",
        })
        pcall(vim.api.nvim_buf_set_extmark, list_buf, ns, line_idx, 0, {
          end_row = line_idx + 1,
          hl_group = "CursorLine",
          hl_eol = true,
        })
      end
    end

    if vim.api.nvim_win_is_valid(list_win) and #filtered_items > 0 then
      pcall(vim.api.nvim_win_set_cursor, list_win, { selected_idx, 0 })
      pcall(vim.api.nvim_win_set_config, list_win, {
        title = string.format(" Requests (%d) ", #filtered_items),
      })
    end

    vim.bo[list_buf].modifiable = false
    render_preview()
  end

  local function apply_filter(new_query)
    query = new_query or ""
    filtered_items = {}
    local q = query:lower()
    for _, it in ipairs(all_items) do
      if q == "" then
        table.insert(filtered_items, it)
      else
        local hay = string.format("%s %s %s %s", it.method, it.name or "", it.url, it.rel_path or ""):lower()
        if hay:find(q, 1, true) then
          table.insert(filtered_items, it)
        end
      end
    end
    selected_idx = 1
    render_list()
  end

  vim.api.nvim_buf_attach(prompt_buf, false, {
    on_lines = function()
      if is_closing then return end
      local cur_lines = vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)
      local cur_text = cur_lines[1] or ""
      if cur_text ~= query then
        apply_filter(cur_text)
      end
    end,
  })

  local function move_down()
    if #filtered_items > 0 then
      selected_idx = math.min(selected_idx + 1, #filtered_items)
      render_list()
    end
  end

  local function move_up()
    if #filtered_items > 0 then
      selected_idx = math.max(selected_idx - 1, 1)
      render_list()
    end
  end

  local function confirm_jump()
    local item = filtered_items[selected_idx]
    close_all()
    if item then
      M.jump_to(item)
    end
  end

  local function confirm_run()
    local item = filtered_items[selected_idx]
    close_all()
    if item then
      M.run_item(item)
    end
  end

  local function toggle_scope()
    scope = (scope == "buffer") and "workspace" or "buffer"
    all_items = M.collect_requests(scope, bufnr)
    if vim.api.nvim_win_is_valid(prompt_win) then
      pcall(vim.api.nvim_win_set_config, prompt_win, {
        title = string.format(" 󰈲 Nuntio Requests [%s] ", scope),
      })
    end
    apply_filter(query)
  end

  local keymaps = {
    ["<CR>"] = confirm_jump,
    ["<C-r>"] = confirm_run,
    ["<C-e>"] = confirm_run,
    ["<Down>"] = move_down,
    ["<C-j>"] = move_down,
    ["<C-n>"] = move_down,
    ["<Up>"] = move_up,
    ["<C-k>"] = move_up,
    ["<C-p>"] = move_up,
    ["<Tab>"] = toggle_scope,
    ["<Esc>"] = close_all,
    ["<C-c>"] = close_all,
  }

  for lhs, rhs in pairs(keymaps) do
    vim.keymap.set({ "i", "n" }, lhs, rhs, { buffer = prompt_buf, silent = true, nowait = true })
    vim.keymap.set("n", lhs, rhs, { buffer = list_buf, silent = true, nowait = true })
  end

  local group = vim.api.nvim_create_augroup("NuntioPickerBuiltin_" .. prompt_win, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(prompt_win),
    callback = function()
      close_all()
    end,
  })

  render_list()
  vim.cmd("startinsert!")
end

--- Main Entrypoint: Find and fuzzy-search requests
---@param opts? string|table "buffer"|"workspace" or configuration table
function M.find(opts)
  if type(opts) == "string" then
    opts = { scope = opts }
  else
    opts = opts or {}
  end

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local Config = require("nuntio.config")
  local cfg = Config.get()

  local scope = opts.scope or (cfg.ui and cfg.ui.find_scope) or "buffer"
  if scope ~= "workspace" and vim.bo[bufnr].filetype ~= "http" then
    scope = "workspace"
  end
  opts.scope = scope
  opts.bufnr = bufnr

  local items = M.collect_requests(scope, bufnr)
  if #items == 0 then
    vim.notify("nuntio: no requests found in " .. scope, vim.log.levels.WARN)
    return
  end

  local provider = (cfg.ui and cfg.ui.picker) or "auto"
  if provider == "telescope" then
    if M.pick_telescope(items, opts) then return end
  elseif provider == "snacks" then
    if M.pick_snacks(items, opts) then return end
  elseif provider == "fzf_lua" then
    if M.pick_fzf(items, opts) then return end
  elseif provider == "ui_select" then
    M.pick_ui_select(items, opts)
    return
  elseif provider == "builtin" then
    M.pick_builtin(items, opts)
    return
  end

  -- Auto detection in order of ecosystem integration
  if M.pick_telescope(items, opts) then return end
  if M.pick_snacks(items, opts) then return end
  if M.pick_fzf(items, opts) then return end
  M.pick_builtin(items, opts)
end

return M
