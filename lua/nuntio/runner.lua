local Config = require("nuntio.config")
local Curl = require("nuntio.transport.curl")
local Document = require("nuntio.parser.document")
local Env = require("nuntio.env")
local Inlay = require("nuntio.ui.inlay")
local Processors = require("nuntio.processors")
local Request = require("nuntio.request")
local RequestVars = require("nuntio.parser.request_vars")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")
local View = require("nuntio.ui.view")

local M = {}

--- Prompt for interactive variables: # @prompt or # @secret
---@param block NuntioBlock
local function handle_prompts(block)
  if block.metadata["prompt"] then
    for _, item in ipairs(block.metadata["prompt"]) do
      local var_name, prompt_text = item:match("^([%w_%-]+)%s*(.*)$")
      if var_name then
        prompt_text = (prompt_text ~= "") and prompt_text or ("Enter " .. var_name .. ": ")
        local val = vim.fn.input(prompt_text)
        if val and val ~= "" then
          Store.set_global(var_name, val)
        end
      end
    end
  end

  if block.metadata["secret"] then
    for _, item in ipairs(block.metadata["secret"]) do
      local var_name, prompt_text = item:match("^([%w_%-]+)%s*(.*)$")
      if var_name then
        prompt_text = (prompt_text ~= "") and prompt_text or ("Enter secret " .. var_name .. ": ")
        local val = vim.fn.inputsecret(prompt_text)
        if val and val ~= "" then
          Store.set_global(var_name, val)
        end
      end
    end
  end
end

--- Execute a single request block
---@param block NuntioBlock
---@param doc_vars table<string, string>
---@param bufnr integer
---@param buffer_dir string
---@param shared_block? NuntioBlock
---@param on_complete? fun(success: boolean, resp: NuntioStoredResponse|nil)
---@param all_blocks? NuntioBlock[]
---@param chain_ctx? table
function M.run_block(block, doc_vars, bufnr, buffer_dir, shared_block, on_complete, all_blocks, chain_ctx)
  if block.is_shared and block.url == "" then
    if on_complete then on_complete(true, nil) end
    return
  end

  -- Check and resolve unexecuted dependencies if all_blocks provided
  if all_blocks and Config.get().auto_run_dependencies ~= false then
    local prereqs, err = RequestVars.resolve_dependency_order(block, all_blocks, buffer_dir)
    if err then
      vim.notify("nuntio: " .. err, vim.log.levels.WARN)
    elseif prereqs and #prereqs > 0 then
      local chain_id = "ch_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
      local total_steps = #prereqs + 1
      local chain_steps = {}

      local names = {}
      for _, p in ipairs(prereqs) do
        table.insert(names, "'" .. (p.name or ("line " .. p.start_line)) .. "'")
      end
      vim.notify("nuntio: auto-running prerequisite(s) " .. table.concat(names, ", ") .. "...", vim.log.levels.INFO)

      local function run_prereq_step(idx)
        if idx > #prereqs then
          local target_chain_ctx = {
            id = chain_id,
            step = total_steps,
            total = total_steps,
            steps = chain_steps,
          }
          M.run_block(block, doc_vars, bufnr, buffer_dir, shared_block, on_complete, nil, target_chain_ctx)
          return
        end

        local p_block = prereqs[idx]
        local p_chain_ctx = {
          id = chain_id,
          step = idx,
          total = total_steps,
          steps = chain_steps,
          is_prereq = true,
        }

        M.run_block(p_block, doc_vars, bufnr, buffer_dir, shared_block, function(success, resp)
          if not success or (resp and resp.status >= 400) then
            vim.notify(string.format("nuntio: prerequisite '%s' failed (status %s). Aborted chain.", p_block.name or "prereq", tostring(resp and resp.status or "err")), vim.log.levels.ERROR)
            if on_complete then on_complete(false, nil) end
            return
          end

          -- Record exported variables
          local exported = {}
          if p_block.name then
            local refs = RequestVars.get_block_variable_references(block, all_blocks, buffer_dir)
            local expr_list = refs[p_block.name] or {}
            for _, expr in ipairs(expr_list) do
              local val = RequestVars.resolve(expr)
              if val == nil then
                val = Store.get_global(expr)
              end
              if val ~= nil then
                exported[expr] = val
              end
            end
          end

          table.insert(chain_steps, {
            step = idx,
            name = p_block.name or ("step_" .. idx),
            method = p_block.method or "GET",
            url = p_block.url or "",
            status = resp and resp.status or 0,
            status_text = resp and resp.status_text or "",
            time = resp and resp.time or 0,
            size = resp and resp.stats and resp.stats.size_download or (resp and resp.body and #resp.body or 0),
            is_prereq = true,
            exported = exported,
          })

          if resp then
            resp.chain = {
              id = chain_id,
              step = idx,
              total = total_steps,
              steps = vim.deepcopy(chain_steps),
            }
          end

          run_prereq_step(idx + 1)
        end, nil, p_chain_ctx)
      end

      run_prereq_step(1)
      return
    end
  elseif Config.get().auto_run_dependencies == false then
    local deps = RequestVars.get_block_dependencies(block, buffer_dir)
    for _, d in ipairs(deps) do
      if not Store.get_by_name(d) and not Store.get_request_by_name(d) then
        vim.notify(string.format("nuntio: warning: referenced request '%s' has not been executed yet.", d), vim.log.levels.WARN)
      end
    end
  end

  handle_prompts(block)

  local resolved = Request.resolve(block, doc_vars, buffer_dir, bufnr, shared_block)

  -- Set loading inlay indicator
  Inlay.set_loading(bufnr, resolved.icon_line)

  -- Save last request for replay
  Store.last_request = {
    block = block,
    doc_vars = doc_vars,
    bufnr = bufnr,
    buffer_dir = buffer_dir,
    shared_block = shared_block,
  }

  Curl.execute(resolved, function(raw_res, err)
    if err or not raw_res then
      Inlay.set_error(bufnr, resolved.icon_line, err or "Request failed")
      vim.notify(string.format("nuntio error: %s", err or "unknown error"), vim.log.levels.ERROR)
      if on_complete then on_complete(false, nil) end
      return
    end

    -- Update inlay with status & duration
    Inlay.set_done(bufnr, resolved.icon_line, raw_res.status, raw_res.duration_ms)

    -- Build StoredResponse
    local decoded_json = nil
    if raw_res.body and raw_res.body ~= "" then
      local ok, j = pcall(vim.json.decode, raw_res.body)
      if ok and type(j) == "table" then
        decoded_json = j
      end
    end

    ---@type NuntioStoredResponse
    local stored = {
      id = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
      name = resolved.name,
      method = resolved.method,
      url = resolved.url,
      status = raw_res.status,
      status_text = raw_res.status_text,
      headers = raw_res.headers,
      raw_headers = raw_res.raw_headers,
      cookies = raw_res.cookies,
      body = raw_res.body,
      raw_body = raw_res.body,
      json = decoded_json,
      time = raw_res.duration_ms,
      stats = raw_res.stats,
      verbose = raw_res.verbose,
      timestamp = os.time(),
      env = Env.get_current_env(bufnr),
    }

    -- Record chain metadata if this execution was part of an auto-run chain
    if chain_ctx then
      local injected = {}
      if chain_ctx.step == chain_ctx.total then
        local refs = RequestVars.get_block_variable_references(block, all_blocks, buffer_dir)
        for _, expr_list in pairs(refs) do
          for _, expr in ipairs(expr_list) do
            local val = RequestVars.resolve(expr)
            if val == nil then
              val = Store.get_global(expr)
            end
            if val ~= nil then
              injected[expr] = val
            end
          end
        end

        table.insert(chain_ctx.steps, {
          step = chain_ctx.total,
          name = resolved.name or "target",
          method = resolved.method,
          url = resolved.url,
          status = raw_res.status,
          status_text = raw_res.status_text,
          time = raw_res.duration_ms,
          size = raw_res.stats and raw_res.stats.size_download or #raw_res.body,
          is_prereq = false,
          injected = injected,
        })
      end

      stored.chain = {
        id = chain_ctx.id,
        step = chain_ctx.step,
        total = chain_ctx.total,
        steps = vim.deepcopy(chain_ctx.steps),
      }
    else
      -- Check if current block references upstream requests in Store
      local refs = RequestVars.get_block_variable_references(block, all_blocks, buffer_dir)
      local upstream_steps = {}
      local total_injected = {}

      for dep_name, expr_list in pairs(refs) do
        local up_resp = Store.get_by_name(dep_name)
        if up_resp then
          local exported = {}
          for _, expr in ipairs(expr_list) do
            local val = RequestVars.resolve(expr)
            if val == nil then
              val = Store.get_global(expr)
            end
            if val ~= nil then
              exported[expr] = val
              total_injected[expr] = val
            end
          end

          table.insert(upstream_steps, {
            step = #upstream_steps + 1,
            name = up_resp.name or dep_name,
            method = up_resp.method,
            url = up_resp.url,
            status = up_resp.status,
            status_text = up_resp.status_text,
            time = up_resp.time,
            size = up_resp.stats and up_resp.stats.size_download or (up_resp.body and #up_resp.body or 0),
            is_prereq = true,
            exported = exported,
          })
        end
      end

      if #upstream_steps > 0 then
        local chain_id = "ch_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
        local all_steps = {}
        for _, s in ipairs(upstream_steps) do
          table.insert(all_steps, s)
        end
        table.insert(all_steps, {
          step = #all_steps + 1,
          name = resolved.name or "target",
          method = resolved.method,
          url = resolved.url,
          status = raw_res.status,
          status_text = raw_res.status_text,
          time = raw_res.duration_ms,
          size = raw_res.stats and raw_res.stats.size_download or #raw_res.body,
          is_prereq = false,
          injected = total_injected,
        })

        stored.chain = {
          id = chain_id,
          step = #all_steps,
          total = #all_steps,
          steps = all_steps,
        }

        -- Also link chain to upstream responses in Store
        for dep_name, _ in pairs(refs) do
          local up_resp = Store.get_by_name(dep_name)
          if up_resp then
            up_resp.chain = stored.chain
          end
        end
      end
    end

    -- Run metadata post-processors (@jq, @env-json-key, redirect >>)
    Processors.process(resolved, stored)

    -- Save in store
    Store.add_response(stored, {
      url = resolved.url,
      method = resolved.method,
      headers = resolved.headers,
      body = resolved.body,
    })

    -- Display in UI
    View.display(stored)

    if on_complete then
      on_complete(true, stored)
    end
  end)
end

--- Run queue of multiple blocks sequentially
---@param queue NuntioBlock[]
---@param doc_vars table<string, string>
---@param bufnr integer
---@param buffer_dir string
---@param shared_block? NuntioBlock
---@param on_finished? fun(results?: table[])
function M.run_queue(queue, doc_vars, bufnr, buffer_dir, shared_block, on_finished)
  local idx = 1
  local results = {}

  local function step()
    if idx > #queue then
      if #results > 1 then
        local succeeded = 0
        local total_time = 0
        for _, r in ipairs(results) do
          if r.ok and r.status >= 200 and r.status < 400 then
            succeeded = succeeded + 1
          end
          total_time = total_time + r.time
        end
        local level = (succeeded == #results) and vim.log.levels.INFO or vim.log.levels.WARN
        vim.notify(string.format("nuntio batch: %d/%d requests completed successfully (%dms total)", succeeded, #results, total_time), level)
      end
      if on_finished then on_finished(results) end
      return
    end

    local current = queue[idx]
    idx = idx + 1

    M.run_block(current, doc_vars, bufnr, buffer_dir, shared_block, function(success, resp)
      table.insert(results, {
        name = current.name or current.url,
        method = current.method,
        status = resp and resp.status or 0,
        time = resp and resp.time or 0,
        ok = success,
      })

      if not success then
        vim.notify("nuntio: stopped run queue on error", vim.log.levels.WARN)
        if on_finished then on_finished(results) end
        return
      end
      vim.schedule(step)
    end)
  end

  step()
end

return M
