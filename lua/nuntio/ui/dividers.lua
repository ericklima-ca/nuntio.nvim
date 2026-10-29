local Config = require("nuntio.config")
local Highlights = require("nuntio.ui.highlights")
local Utils = require("nuntio.utils")

local M = {}

local ns_id = vim.api.nvim_create_namespace("nuntio_dividers")
local header_ns_id = vim.api.nvim_create_namespace("nuntio_shared_headers")

--- Render visible divider decorations on all `###` request lines
---@param bufnr? integer
function M.render(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local cfg = Config.get().dividers or { enabled = true, icon = "󰖟", shared_icon = "󰒘", hint = true, style = "above" }
  if cfg.enabled == false then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, header_ns_id, 0, -1)
    return
  end

  Highlights.setup()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, header_ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local icon = cfg.icon or "󰖟"
  local shared_icon = cfg.shared_icon or "󰒘"
  local style = cfg.style or "above"
  local show_hint = cfg.hint ~= false

  for lnum = 0, #lines - 1 do
    local text = lines[lnum + 1]
    if text:match("^%s*###") then
      local is_shared = text:match("^%s*###%s*[Ss]hared") ~= nil
      local virt_lines = nil
      local virt_text = nil
      local virt_text_pos = "right_align"

      -- 1. Virtual line above (for "above" and "both" styles)
      if style == "above" or style == "both" then
        local line_chunks = {}
        if is_shared then
          table.insert(line_chunks, { "── ", "NuntioDivider" })
          table.insert(line_chunks, { shared_icon .. " SHARED DEFAULTS ", "NuntioSharedKeyword" })
          table.insert(line_chunks, { string.rep("─", 56), "NuntioDivider" })
        else
          table.insert(line_chunks, { "── ", "NuntioDivider" })
          if icon and icon ~= "" then
            table.insert(line_chunks, { icon .. " ", "NuntioDividerIcon" })
          end
          table.insert(line_chunks, { string.rep("─", 74), "NuntioDivider" })
        end
        virt_lines = { line_chunks }
      end

      -- 2. Virtual text on the `###` line
      if is_shared then
        local badge_text = " [" .. shared_icon .. " Auto-injected into all requests]"
        if style == "above" then
          virt_text = {
            { badge_text, "NuntioSharedBadge" },
          }
          virt_text_pos = "right_align"
        elseif style == "eol" or style == "both" then
          local title_width = vim.fn.strdisplaywidth(text)
          local remaining = math.max(4, 45 - title_width)
          local eol_rule = " " .. string.rep("─", remaining)
          virt_text = {
            { eol_rule, "NuntioDivider" },
            { badge_text, "NuntioSharedBadge" },
          }
          virt_text_pos = "eol"
        end
      else
        if style == "above" then
          if show_hint then
            virt_text = {
              { " [", "NuntioRunHint" },
              { "▶", "NuntioStatus2xx" },
              { " <CR>]", "NuntioRunHint" },
            }
            virt_text_pos = "right_align"
          end
        elseif style == "eol" or style == "both" then
          local title_width = vim.fn.strdisplaywidth(text)
          local remaining = math.max(4, 70 - title_width)
          local eol_rule = " " .. string.rep("─", remaining)

          virt_text = {
            { eol_rule, "NuntioDivider" },
          }
          if show_hint then
            table.insert(virt_text, { " [", "NuntioRunHint" })
            table.insert(virt_text, { "▶", "NuntioStatus2xx" })
            table.insert(virt_text, { " <CR>]", "NuntioRunHint" })
          end
          virt_text_pos = "eol"
        end
      end

      local extmark_opts = {
        hl_mode = "combine",
      }
      if virt_lines then
        extmark_opts.virt_lines_above = true
        extmark_opts.virt_lines = virt_lines
      end
      if virt_text then
        extmark_opts.virt_text = virt_text
        extmark_opts.virt_text_pos = virt_text_pos
      end

      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, lnum, 0, extmark_opts)

      -- Fix Tree-sitter URL misclassification for headers in ### Shared blocks
      if is_shared then
        local cur = lnum + 1
        while cur < #lines do
          local cur_line = lines[cur + 1]
          if cur_line:match("^%s*###") then
            break
          end
          if not cur_line:match("^%s*[@#%/]") then
            local h_key, h_val = cur_line:match("^([A-Za-z0-9_%-]+)%s*:(.*)$")
            if h_key then
              local key_len = #h_key
              pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, cur, 0, {
                end_col = key_len,
                hl_group = "NuntioHeaderKey",
                priority = 130,
              })
              local colon_pos = cur_line:find(":")
              if colon_pos then
                pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, cur, colon_pos - 1, {
                  end_col = colon_pos,
                  hl_group = "NuntioHeaderDelim",
                  priority = 130,
                })
                if #cur_line > colon_pos then
                  pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, cur, colon_pos, {
                    end_col = #cur_line,
                    hl_group = "NuntioHeaderVal",
                    priority = 130,
                  })
                end
              end
              for v_start, v_end in cur_line:gmatch("(){{%s*[%w_%-$.]+%s*}}()") do
                pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, cur, v_start - 1, {
                  end_col = v_end - 1,
                  hl_group = "NuntioVariable",
                  priority = 135,
                })
              end
            end
          end
          cur = cur + 1
        end
      end
    end
  end

  -- Decorate body syntax (multipart forms, MIME boundaries, sub-headers, file includes, variables)
  local in_body = false
  for lnum = 0, #lines - 1 do
    local line = lines[lnum + 1]
    if line:match("^%s*###") then
      in_body = false
    elseif not in_body and line:match("^%s*$") then
      in_body = true
    elseif in_body then
      -- 1. MIME Boundary
      if line:match("^%s*%-%-%S+") then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, 0, {
          end_col = #line,
          hl_group = "NuntioBannerDoubleDivider",
          priority = 130,
        })
      -- 2. Embedded Multipart Header
      elseif line:match("^%s*[A-Za-z0-9_%-]+%s*:") and not line:match("^%s*[@#%/]") then
        local key = line:match("^%s*([A-Za-z0-9_%-]+)%s*:")
        local colon_idx = line:find(":")
        pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, 0, {
          end_col = #key,
          hl_group = "NuntioHeaderKey",
          priority = 130,
        })
        pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, colon_idx - 1, {
          end_col = colon_idx,
          hl_group = "NuntioHeaderDelim",
          priority = 130,
        })
        if #line > colon_idx then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, colon_idx, {
            end_col = #line,
            hl_group = "NuntioHeaderVal",
            priority = 125,
          })
          for p_start, p_key, p_end in line:gmatch("()([A-Za-z0-9_%-]+)=()") do
            if p_start > colon_idx then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, p_start - 1, {
                end_col = p_end - 1,
                hl_group = "NuntioDocVar",
                priority = 132,
              })
            end
          end
          for q_start, q_val, q_end in line:gmatch("()(\"[^\"]*\")()") do
            if q_start > colon_idx then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, q_start - 1, {
                end_col = q_end - 1,
                hl_group = "NuntioHeaderVal",
                priority = 132,
              })
            end
          end
        end
      -- 3. Simplified form-data (field = value or file = < ...)
      elseif line:match("^%s*([A-Za-z0-9_%-]+)%s*=(.*)$") and not line:match("^%s*@") then
        local key = line:match("^%s*([A-Za-z0-9_%-]+)%s*=")
        local eq_idx = line:find("=")
        pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, 0, {
          end_col = #key,
          hl_group = "NuntioDocVar",
          priority = 130,
        })
        pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, eq_idx - 1, {
          end_col = eq_idx,
          hl_group = "NuntioOperator",
          priority = 130,
        })
        local file_arrow = line:find("<", eq_idx)
        if file_arrow then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, file_arrow - 1, {
            end_col = file_arrow,
            hl_group = "NuntioOperator",
            priority = 130,
          })
          local path_str = line:match("<%s*([^%s;]+)", eq_idx)
          if path_str then
            local path_start = line:find(path_str, file_arrow, true)
            pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, path_start - 1, {
              end_col = path_start - 1 + #path_str,
              hl_group = "NuntioUrl",
              priority = 130,
            })
          end
        end
        local type_start = line:find(";%s*type=")
        if type_start then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, type_start - 1, {
            end_col = type_start,
            hl_group = "NuntioHeaderDelim",
            priority = 130,
          })
          local type_kw_start = line:find("type=", type_start)
          pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, type_kw_start - 1, {
            end_col = type_kw_start + 4,
            hl_group = "NuntioDocVar",
            priority = 130,
          })
          local mime = line:match("type=([^%s;]+)", type_start)
          if mime then
            local mime_start = line:find(mime, type_kw_start + 4, true)
            pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, mime_start - 1, {
              end_col = mime_start - 1 + #mime,
              hl_group = "NuntioHeaderVal",
              priority = 130,
            })
          end
        end
      -- 4. Standalone file inclusion: < ./file
      elseif line:match("^%s*<[@%s]") then
        local path = line:match("^%s*<[@%s]%s*(%S+)")
        if path then
          local p_idx = line:find(path, 1, true)
          pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, 0, {
            end_col = p_idx - 1,
            hl_group = "NuntioOperator",
            priority = 130,
          })
          pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, p_idx - 1, {
            end_col = p_idx - 1 + #path,
            hl_group = "NuntioUrl",
            priority = 130,
          })
        end
      end

      -- Always highlight {{variables}} in body
      for v_start, v_end in line:gmatch("(){{%s*[%w_%-$.]+%s*}}()") do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, header_ns_id, lnum, v_start - 1, {
          end_col = v_end - 1,
          hl_group = "NuntioVariable",
          priority = 135,
        })
      end
    end
  end
end

--- Clear divider extmarks
---@param bufnr? integer
function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, header_ns_id, 0, -1)
  end
end

--- Setup autocmds to auto-render dividers on .http buffers
function M.setup()
  local group = vim.api.nvim_create_augroup("nuntio_dividers", { clear = true })

  vim.api.nvim_create_autocmd({ "FileType", "BufEnter", "BufWinEnter", "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(args)
      if vim.bo[args.buf].filetype == "http" then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(args.buf) then
            M.render(args.buf)
          end
        end)
      end
    end,
  })
end

return M
