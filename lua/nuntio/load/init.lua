local Assertions = require("nuntio.assertions")
local Config = require("nuntio.config")
local Curl = require("nuntio.transport.curl")
local Data = require("nuntio.load.data")
local Env = require("nuntio.env")
local Inlay = require("nuntio.ui.inlay")
local Report = require("nuntio.load.report")
local Request = require("nuntio.request")
local Scenario = require("nuntio.load.scenario")
local Stats = require("nuntio.load.stats")

local M = {}

--- Currently running load test state, if any
M.active = nil

--- Last finished load test state (for rerun and inspection)
M.last = nil

local noticed_curl_backend = false

local option_aliases = {
  n = "requests",
  requests = "requests",
  i = "requests",
  iterations = "requests",
  c = "concurrency",
  concurrency = "concurrency",
  d = "duration",
  duration = "duration",
  timeout = "timeout",
}

---@class NuntioLoadOptions
---@field requests? integer Total requests to send
---@field concurrency? integer Requests in flight at once
---@field duration? integer Run time in milliseconds
---@field timeout? integer Per-request timeout in milliseconds

--- Parse a duration like `30s`, `2m`, `500ms` or `45` (seconds) into milliseconds
---@param s string
---@return integer|nil
function M.parse_duration(s)
  local num, unit = tostring(s):match("^(%d+%.?%d*)(%a*)$")
  num = tonumber(num)
  if not num then return nil end
  local factor = ({ [""] = 1000, s = 1000, ms = 1, m = 60000 })[unit]
  if not factor then return nil end
  return math.floor(num * factor)
end

--- Parse `key=value` tokens such as `requests=500 concurrency=20 duration=30s`
---@param tokens string[]
---@return NuntioLoadOptions|nil opts, string|nil err
function M.parse_options(tokens)
  local opts = {}
  for _, token in ipairs(tokens) do
    local key, val = token:match("^([%w_]+)=(.+)$")
    local name = key and option_aliases[key]
    if not name then
      return nil, string.format("unknown option '%s' (expected requests=/iterations=, concurrency=, duration=, timeout=)", token)
    end
    local parsed
    if name == "duration" then
      parsed = M.parse_duration(val)
    elseif name == "timeout" then
      -- Plain numbers are milliseconds, like the global `timeout` setting
      parsed = val:match("^%d+$") and tonumber(val) or M.parse_duration(val)
    else
      parsed = val:match("^%d+$") and tonumber(val) or nil
    end
    if not parsed or parsed <= 0 then
      return nil, string.format("invalid value for %s: '%s'", name, val)
    end
    opts[name] = parsed
  end
  return opts
end

--- Merge `# @load` directives with command arguments (arguments win), then apply defaults
---@param block NuntioBlock
---@param args? string[]
---@return NuntioLoadOptions|nil opts, string|nil err
function M.collect_options(block, args)
  local merged = {}
  local sources = {}
  for _, line in ipairs(block.metadata and block.metadata["load"] or {}) do
    table.insert(sources, vim.split(vim.trim(line), "%s+", { trimempty = true }))
  end
  table.insert(sources, args or {})

  for _, tokens in ipairs(sources) do
    local opts, err = M.parse_options(tokens)
    if not opts then
      return nil, err
    end
    for k, v in pairs(opts) do
      merged[k] = v
    end
  end

  local defaults = Config.get().load.defaults
  if not merged.requests and not merged.duration then
    merged.requests = defaults.requests
  end
  merged.concurrency = merged.concurrency or defaults.concurrency
  if merged.requests and merged.concurrency > merged.requests then
    merged.concurrency = merged.requests
  end
  return merged
end

--- Check options against the curl backend limits
---@param opts NuntioLoadOptions
---@param steps_per_iteration? integer Requests each iteration sends (scenario length)
---@return string|nil err Multi-line explanation when a limit is exceeded
function M.validate(opts, steps_per_iteration)
  steps_per_iteration = steps_per_iteration or 1
  local limits = Config.get().load.curl
  local problems = {}
  if opts.concurrency > limits.max_concurrency then
    table.insert(problems, string.format("concurrency %d > %d (load.curl.max_concurrency)", opts.concurrency, limits.max_concurrency))
  end
  local total = opts.requests and opts.requests * steps_per_iteration
  if total and total > limits.max_requests then
    if steps_per_iteration > 1 then
      table.insert(problems, string.format("requests %d (%d iterations × %d steps) > %d (load.curl.max_requests)",
        total, opts.requests, steps_per_iteration, limits.max_requests))
    else
      table.insert(problems, string.format("requests %d > %d (load.curl.max_requests)", total, limits.max_requests))
    end
  end
  if opts.duration and opts.duration > limits.max_duration * 1000 then
    table.insert(problems, string.format("duration %ds > %ds (load.curl.max_duration)", opts.duration / 1000, limits.max_duration))
  end
  if #problems == 0 then
    return nil
  end
  return table.concat({
    "nuntio: load test exceeds curl backend limits: " .. table.concat(problems, ", ") .. ".",
    "  curl spawns one process per request and cannot generate this load reliably;",
    "  results would measure your machine, not the server.",
    "  -> lower the numbers, use a dedicated tool (oha, vegeta, k6) for high load,",
    "  -> or raise the limits in setup({ load = { curl = { ... } } }) if you know what you're doing.",
  }, "\n")
end

--- Reduce a transport error (which may be a full verbose trace) to one line
---@param err? string
---@return string
local function summarize_error(err)
  err = err or ""
  local curl_err = err:match("curl: %(%d+%)[^\n]*")
  if curl_err then
    return curl_err
  end
  if err:match("^request timed out") then
    return err
  end
  for line in err:gmatch("[^\n]+") do
    if not line:match("^[%*<>{}]") then
      return vim.trim(line):sub(1, 100)
    end
  end
  return "transport error"
end

--- Build the report metadata block for rendering
---@param state table
---@return NuntioLoadReportMeta
local function report_meta(state)
  local opts = state.opts
  local unit = state.plan.kind == "single" and "requests" or "iterations"
  local plan = {}
  if opts.requests then table.insert(plan, string.format("%d %s", opts.requests, unit)) end
  if opts.duration then table.insert(plan, string.format("%gs", opts.duration / 1000)) end
  table.insert(plan, "concurrency " .. opts.concurrency)

  local progress
  if opts.requests then
    progress = string.format("%d/%d", state.completed, opts.requests)
  else
    progress = string.format("%d %s", state.completed, unit)
  end
  if state.plan.kind ~= "single" then
    progress = progress .. (opts.requests and " iterations" or "")
  end

  return {
    title = state.plan.title,
    state = state.finished and (state.cancelled and "cancelled" or "done") or "running",
    progress = progress,
    plan = table.concat(plan, " · "),
    data = state.data_label,
  }
end

--- Elapsed milliseconds since the test started
---@param state table
---@return number
local function elapsed_ms(state)
  return ((state.ended_at or vim.uv.hrtime()) - state.started_at) / 1e6
end

--- Current report for a state, with a per-scenario/per-step breakdown for scenario runs
---@param state table
---@return NuntioLoadReport
function M.snapshot(state)
  local threshold = Config.get().load.client_bound_threshold
  local elapsed = elapsed_ms(state)
  local report = Stats.summarize(state.collector, elapsed, threshold)
  if state.plan.kind ~= "single" then
    local scenarios, steps = {}, {}
    for _, sc in ipairs(state.plan.scenarios) do
      local it = state.iteration_stats[sc.name]
      table.insert(scenarios, {
        name = sc.name,
        weight = sc.weight,
        iterations = it.count,
        ok = it.ok,
        duration = Stats.distribution(it.durations),
      })
    end
    for _, name in ipairs(state.step_order) do
      table.insert(steps, { name = name, report = Stats.summarize(state.step_collectors[name], elapsed, threshold) })
    end
    report.breakdown = { scenarios = scenarios, steps = steps }
  end
  return report
end

--- Render report lines for a state
---@param state table
---@return string[]
function M.render_lines(state)
  return Report.format(M.snapshot(state), report_meta(state))
end

--- Push the current state to the report view and the request line
---@param state table
local function refresh(state)
  if state.on_update then
    state.on_update(state)
  end
  if not state.finished then
    local meta = report_meta(state)
    Inlay.set_text(state.bufnr, state.icon_line, string.format(" %s %s", Config.get().icons.loading or "⏳", meta.progress), "Comment")
  end
end

--- Finish a run (completion or cancel)
---@param state table
local function finish(state)
  if state.finished then return end
  state.finished = true
  state.ended_at = vim.uv.hrtime()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if M.active == state then
    M.active = nil
  end
  M.last = state
  pcall(vim.fn.delete, state.jar_dir, "rf")

  local report = M.snapshot(state)
  state.report = report
  local icons = Config.get().icons
  local ok = report.failed == 0 and not state.cancelled
  local prefix = state.cancelled and "cancelled · " or ""
  Inlay.set_text(state.bufnr, state.icon_line,
    string.format(" %s %s%s", ok and (icons.done or "✔") or (icons.error or "✘"), prefix, Report.short(report)),
    ok and "String" or "ErrorMsg")
  refresh(state)

  local msg = string.format("nuntio load: %s%s", prefix, Report.short(report))
  if report.client_bound then
    msg = msg .. " · ⚠ client-bound (see report)"
  end
  vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)

  if state.on_finish then
    state.on_finish(state)
  end
end

--- Has the run been cancelled or reached its deadline?
---@param state table
---@return boolean
local function time_up(state)
  return state.cancelled or (state.deadline ~= nil and vim.uv.hrtime() >= state.deadline)
end

--- Should the run stop starting new iterations?
---@param state table
---@return boolean
local function should_stop(state)
  if state.exhausted or time_up(state) then return true end
  return state.opts.requests ~= nil and state.dispatched >= state.opts.requests
end

--- Record one finished request
---@param state table
---@param step_name string
---@param resolved? NuntioResolvedRequest
---@param raw? NuntioRawResponse
---@param err? string
---@param wall_ms number
---@return NuntioLoadSample sample, table|nil json Decoded JSON body when it was needed
local function record(state, step_name, resolved, raw, err, wall_ms)
  ---@type NuntioLoadSample
  local sample = { ok = false, wall_ms = wall_ms }
  local json

  if err or not raw or raw.status == 0 then
    sample.error = raw and raw.status == 0 and "no HTTP response" or summarize_error(err)
  else
    sample.status = raw.status
    local stats = raw.stats or {}
    if tonumber(stats.time_total) then
      sample.total_ms = tonumber(stats.time_total) * 1000
    end
    if tonumber(stats.time_starttransfer) then
      sample.ttfb_ms = tonumber(stats.time_starttransfer) * 1000
    end

    local has_assertions = resolved and #resolved.assertions > 0
    -- Scenario steps keep the JSON so later steps can chain from it
    if raw.body ~= "" and (has_assertions or state.plan.kind ~= "single") then
      local ok, decoded = pcall(vim.json.decode, raw.body)
      if ok and type(decoded) == "table" then json = decoded end
    end

    if has_assertions then
      local summary = Assertions.run(resolved.assertions, {
        status = raw.status,
        headers = raw.headers,
        body = raw.body,
        raw_body = raw.body,
        json = json,
        time = raw.duration_ms,
      })
      sample.ok = summary.failed == 0
      if summary.failed > 0 then
        sample.assert_failed = true
        sample.failed_asserts = {}
        for _, r in ipairs(summary.results) do
          if not r.ok then table.insert(sample.failed_asserts, r.expr) end
        end
      end
    else
      sample.ok = raw.status >= 200 and raw.status < 400
    end
  end

  Stats.record(state.collector, sample)
  if state.step_collectors[step_name] then
    Stats.record(state.step_collectors[step_name], sample)
  end
  return sample, json
end

local start_iteration

--- Close an iteration and let the virtual user start the next one
---@param state table
---@param vu integer
---@param iter table
---@param ok boolean
---@param interrupted? boolean Stopped by the deadline or cancel: not counted
local function end_iteration(state, vu, iter, ok, interrupted)
  state.active_iterations = state.active_iterations - 1
  if state.finished then return end
  if not interrupted then
    local it = state.iteration_stats[iter.scenario.name]
    it.count = it.count + 1
    if ok then it.ok = it.ok + 1 end
    table.insert(it.durations, (vim.uv.hrtime() - iter.t0) / 1e6)
    state.completed = state.completed + 1
  end
  start_iteration(state, vu)
end

--- Send step `idx` of an iteration; continues with the next step when it succeeds
---@param state table
---@param vu integer
---@param iter table
---@param idx integer
local function run_step(state, vu, iter, idx)
  if state.finished then return end
  local scenario = iter.scenario
  local block = scenario.steps[idx]
  local step_name = scenario.step_names[idx]
  local t0 = vim.uv.hrtime()

  local ok, resolved = pcall(Request.resolve, block, state.doc_vars, state.buffer_dir, state.bufnr, state.shared_block, {
    env = state.env,
    extra_env = iter.row and { data = iter.row } or nil,
    chain = iter.chain,
    dynamic = {
      ["$iteration"] = function() return iter.number end,
      ["$vu"] = function() return vu end,
      ["$vuIteration"] = function() return iter.vu_iteration end,
    },
  })
  if not ok then
    record(state, step_name, nil, nil, "resolve error: " .. tostring(resolved), 0)
    -- Deferred so a request that never resolves cannot recurse synchronously
    vim.schedule(function() end_iteration(state, vu, iter, false) end)
    return
  end

  -- Each virtual user keeps its own cookie jar: sessions stay isolated and
  -- concurrent curl processes never write the same file
  resolved.metadata = vim.tbl_extend("force", resolved.metadata, { ["cookie-jar"] = { iter.jar } })
  resolved.timeout = state.opts.timeout

  local job_id
  job_id = Curl.execute(resolved, function(raw, err)
    state.jobs[job_id] = nil
    if state.finished then return end
    local sample, json = record(state, step_name, resolved, raw, err, (vim.uv.hrtime() - t0) / 1e6)

    if raw then
      iter.chain.responses[step_name] = { status = raw.status, headers = raw.headers, body = raw.body, json = json }
      iter.chain.requests[step_name] = { url = resolved.url, method = resolved.method, headers = resolved.headers, body = resolved.body }
    end

    -- A failed step ends the iteration: later steps usually depend on it
    if not sample.ok or idx == #scenario.steps then
      end_iteration(state, vu, iter, sample.ok)
      return
    end
    if time_up(state) then
      end_iteration(state, vu, iter, false, true)
      return
    end

    local think = scenario.think
    if think then
      vim.defer_fn(function()
        if state.finished then return end
        if time_up(state) then
          end_iteration(state, vu, iter, false, true)
          return
        end
        run_step(state, vu, iter, idx + 1)
      end, math.random(think.min, think.max))
    else
      run_step(state, vu, iter, idx + 1)
    end
  end)
  state.jobs[job_id] = true
end

--- Start the next iteration for a virtual user, or finish the run
---@param state table
---@param vu integer
start_iteration = function(state, vu)
  if state.finished then return end
  if should_stop(state) then
    if state.active_iterations == 0 then finish(state) end
    return
  end

  local row
  if state.feeder then
    row = state.feeder.next()
    if row == nil then
      state.exhausted = true
      if state.active_iterations == 0 then finish(state) end
      return
    end
  end

  state.dispatched = state.dispatched + 1
  state.vu_iterations[vu] = (state.vu_iterations[vu] or 0) + 1
  state.active_iterations = state.active_iterations + 1

  -- Fresh session per iteration
  local jar = vim.fs.joinpath(state.jar_dir, "vu" .. vu .. ".jar")
  os.remove(jar)

  local iter = {
    scenario = Scenario.pick(state.plan),
    row = row,
    number = state.dispatched,
    vu_iteration = state.vu_iterations[vu],
    jar = jar,
    t0 = vim.uv.hrtime(),
    chain = { responses = {}, requests = {}, owns = state.plan.owns },
  }
  run_step(state, vu, iter, 1)
end

---@class NuntioLoadContext
---@field block NuntioBlock Request block, or a `# @scenario` / `# @load-mix` plan block
---@field blocks? NuntioBlock[] All request blocks (needed to resolve scenario steps)
---@field plans? NuntioBlock[] All plan blocks (needed to resolve `# @load-mix`)
---@field doc_vars table<string, string>
---@field bufnr integer
---@field buffer_dir string
---@field shared_block? NuntioBlock
---@field args? string[] Command arguments overriding # @load
---@field on_update? fun(state: table) Called on progress ticks and at the end
---@field on_finish? fun(state: table)

--- Validate and start a load test
---@param ctx NuntioLoadContext
---@return table|nil state, string|nil err
function M.start(ctx)
  if M.active then
    return nil, "nuntio: a load test is already running (:Nuntio cancel to stop it)"
  end

  local plan, plan_err
  if ctx.block.is_plan then
    plan, plan_err = Scenario.build(ctx.block, ctx.blocks or {}, ctx.plans or {})
    if not plan then
      return nil, "nuntio: " .. plan_err
    end
  else
    plan = Scenario.single(ctx.block)
  end

  local opts, opt_err = M.collect_options(ctx.block, ctx.args)
  if not opts then
    return nil, "nuntio: invalid load options: " .. opt_err
  end
  local limit_err = M.validate(opts, plan.max_steps)
  if limit_err then
    return nil, limit_err
  end

  local feeder, data_label
  local data_lines = ctx.block.metadata and ctx.block.metadata["data"]
  if data_lines and data_lines[1] then
    local spec, spec_err = Data.parse_directive(data_lines[1])
    if not spec then
      return nil, "nuntio: invalid @data: " .. spec_err
    end
    local path = spec.path
    if not vim.fs.normalize(path):match("^/") then
      path = vim.fs.joinpath(ctx.buffer_dir, path)
    end
    local rows, data_err = Data.load(path)
    if not rows then
      return nil, "nuntio: " .. data_err
    end
    feeder = Data.feeder(rows, spec.mode)
    data_label = string.format("%s (%s, %d rows)", vim.fs.basename(path), spec.mode, #rows)
  end

  if not noticed_curl_backend then
    noticed_curl_backend = true
    vim.notify("nuntio: load tests use the curl backend (one process per request, a few hundred req/s at most). See :h nuntio-load", vim.log.levels.INFO)
  end

  local step_collectors, step_order, iteration_stats = {}, {}, {}
  for _, sc in ipairs(plan.scenarios) do
    iteration_stats[sc.name] = { count = 0, ok = 0, durations = {} }
    if plan.kind ~= "single" then
      for _, name in ipairs(sc.step_names) do
        if not step_collectors[name] then
          step_collectors[name] = Stats.new()
          table.insert(step_order, name)
        end
      end
    end
  end

  local jar_dir = vim.fn.tempname()
  vim.fn.mkdir(jar_dir, "p")

  local env_vars, default_headers = Env.resolve(ctx.buffer_dir, ctx.bufnr)
  local now = vim.uv.hrtime()
  local state = {
    block = ctx.block,
    blocks = ctx.blocks,
    plans = ctx.plans,
    plan = plan,
    doc_vars = ctx.doc_vars,
    bufnr = ctx.bufnr,
    buffer_dir = ctx.buffer_dir,
    shared_block = ctx.shared_block,
    args = ctx.args,
    env = { vars = env_vars, default_headers = default_headers },
    opts = opts,
    feeder = feeder,
    data_label = data_label,
    icon_line = ctx.block.icon_line,
    collector = Stats.new(),
    step_collectors = step_collectors,
    step_order = step_order,
    iteration_stats = iteration_stats,
    jar_dir = jar_dir,
    started_at = now,
    deadline = opts.duration and (now + opts.duration * 1e6) or nil,
    dispatched = 0,
    completed = 0,
    active_iterations = 0,
    vu_iterations = {},
    jobs = {},
    on_update = ctx.on_update,
    on_finish = ctx.on_finish,
  }
  -- First render before registering, so an error here cannot leave a phantom active run
  refresh(state)
  M.active = state

  state.timer = vim.uv.new_timer()
  state.timer:start(250, 250, vim.schedule_wrap(function()
    if not state.finished then
      refresh(state)
    end
  end))

  for vu = 1, opts.concurrency do
    vim.schedule(function() start_iteration(state, vu) end)
  end
  return state
end

--- Cancel the running load test, keeping the results collected so far
---@return boolean cancelled
function M.cancel()
  local state = M.active
  if not state then
    return false
  end
  state.cancelled = true
  for id in pairs(state.jobs) do
    Curl.cancel(id)
  end
  state.jobs = {}
  finish(state)
  return true
end

return M
