local M = {}

---@class NuntioThink
---@field min integer Milliseconds
---@field max integer Milliseconds

---@class NuntioScenario
---@field name string
---@field weight integer
---@field step_names string[]
---@field steps NuntioBlock[] Resolved request blocks, in order
---@field think? NuntioThink Pause between steps

---@class NuntioPlan
---@field kind "scenario"|"mix"
---@field title string
---@field scenarios NuntioScenario[]
---@field owns table<string, boolean> Every step name (resolved per virtual user, never from history)
---@field max_steps integer
---@field total_weight integer

--- Parse a single duration with unit (`200ms`, `1s`, `1.5s`); bare numbers are milliseconds
---@param s string
---@return integer|nil
local function parse_ms(s)
  local num, unit = s:match("^(%d+%.?%d*)(%a*)$")
  num = tonumber(num)
  local factor = ({ [""] = 1, ms = 1, s = 1000 })[unit or ""]
  if not num or not factor then return nil end
  return math.floor(num * factor)
end

--- Parse `# @think` values: `500ms`, `1s`, `200..800ms`, `1s..2s`
---@param value string
---@return NuntioThink|nil think, string|nil err
function M.parse_think(value)
  value = vim.trim(value or "")
  local lo, hi = value:match("^(%S-)%.%.(%S+)$")
  if lo then
    -- A shared unit may be written once at the end: 200..800ms
    local unit = hi:match("%a+$") or ""
    if not lo:match("%a$") then lo = lo .. unit end
  else
    lo, hi = value, value
  end
  local min, max = parse_ms(lo), parse_ms(hi)
  if not min or not max then
    return nil, string.format("invalid think time '%s' (e.g. 500ms, 1s, 200..800ms)", value)
  end
  if min > max then
    return nil, string.format("think time range is reversed: '%s'", value)
  end
  return { min = min, max = max }
end

--- Split a list of names separated by `->`, commas or spaces
---@param value string
---@return string[]
function M.split_names(value)
  local names = {}
  for name in (value or ""):gsub("%->", " "):gsub(",", " "):gmatch("%S+") do
    table.insert(names, name)
  end
  return names
end

--- Parse the `# @scenario <name> [weight=N]` line
---@param value string
---@return { name: string, weight: integer }|nil header, string|nil err
function M.parse_header(value)
  local name, rest = vim.trim(value or ""):match("^([%w_%-]+)%s*(.*)$")
  if not name then
    return nil, "missing scenario name (e.g. # @scenario checkout weight=30)"
  end
  local header = { name = name, weight = 1 }
  for token in rest:gmatch("%S+") do
    local w = token:match("^weight=(%d+)$")
    if not w or tonumber(w) < 1 then
      return nil, string.format("invalid option '%s' (expected weight=<positive integer>)", token)
    end
    header.weight = tonumber(w)
  end
  return header
end

--- Index request blocks by name
---@param blocks NuntioBlock[]
---@return table<string, NuntioBlock>
local function index_by_name(blocks)
  local by_name = {}
  for _, b in ipairs(blocks) do
    if b.name and b.name ~= "" and not b.is_shared then
      by_name[b.name] = b
    end
  end
  return by_name
end

--- Build one scenario from its plan block
---@param plan NuntioBlock
---@param by_name table<string, NuntioBlock>
---@return NuntioScenario|nil scenario, string|nil err
local function build_scenario(plan, by_name)
  local header, err = M.parse_header(plan.metadata["scenario"][1])
  if not header then return nil, err end

  local steps_line = plan.metadata["steps"] and plan.metadata["steps"][1]
  local step_names = M.split_names(steps_line)
  if #step_names == 0 then
    return nil, string.format("scenario '%s' has no steps (add # @steps login -> browse)", header.name)
  end

  local steps = {}
  for _, name in ipairs(step_names) do
    local block = by_name[name]
    if not block then
      return nil, string.format("scenario '%s': unknown request '%s' (name it with # @name %s)", header.name, name, name)
    end
    table.insert(steps, block)
  end

  local think
  if plan.metadata["think"] and plan.metadata["think"][1] then
    think, err = M.parse_think(plan.metadata["think"][1])
    if not think then
      return nil, string.format("scenario '%s': %s", header.name, err)
    end
  end

  return { name = header.name, weight = header.weight, step_names = step_names, steps = steps, think = think }
end

--- Build a runnable plan from a scenario or mix block
---@param plan NuntioBlock The block under the cursor
---@param blocks NuntioBlock[] All request blocks in the document
---@param plans NuntioBlock[] All plan blocks in the document
---@return NuntioPlan|nil plan, string|nil err
function M.build(plan, blocks, plans)
  local by_name = index_by_name(blocks)
  local scenarios = {}

  if plan.metadata["scenario"] then
    local sc, err = build_scenario(plan, by_name)
    if not sc then return nil, err end
    table.insert(scenarios, sc)
  else
    local wanted = M.split_names(plan.metadata["load-mix"][1])
    if #wanted == 0 then
      return nil, "# @load-mix needs scenario names (e.g. # @load-mix browse checkout)"
    end
    local available = {}
    for _, p in ipairs(plans) do
      if p.metadata["scenario"] then
        local header = M.parse_header(p.metadata["scenario"][1])
        if header then available[header.name] = p end
      end
    end
    for _, name in ipairs(wanted) do
      if not available[name] then
        return nil, string.format("# @load-mix: unknown scenario '%s'", name)
      end
      local sc, err = build_scenario(available[name], by_name)
      if not sc then return nil, err end
      table.insert(scenarios, sc)
    end
  end

  local owns, max_steps, total_weight = {}, 0, 0
  local labels = {}
  for _, sc in ipairs(scenarios) do
    for _, name in ipairs(sc.step_names) do
      owns[name] = true
    end
    max_steps = math.max(max_steps, #sc.steps)
    total_weight = total_weight + sc.weight
  end
  for _, sc in ipairs(scenarios) do
    table.insert(labels, string.format("%s %.0f%%", sc.name, sc.weight / total_weight * 100))
  end

  local title
  if plan.metadata["scenario"] then
    title = string.format("scenario %s (%s)", scenarios[1].name, table.concat(scenarios[1].step_names, " → "))
  else
    title = "mix " .. table.concat(labels, " · ")
  end

  return {
    kind = plan.metadata["scenario"] and "scenario" or "mix",
    title = title,
    scenarios = scenarios,
    owns = owns,
    max_steps = max_steps,
    total_weight = total_weight,
  }
end

--- Pick a scenario by weight
---@param plan NuntioPlan
---@param rand? fun(m: integer, n: integer): integer
---@return NuntioScenario
function M.pick(plan, rand)
  rand = rand or math.random
  local roll = rand(1, plan.total_weight)
  for _, sc in ipairs(plan.scenarios) do
    roll = roll - sc.weight
    if roll <= 0 then
      return sc
    end
  end
  return plan.scenarios[#plan.scenarios]
end

--- Wrap a single request as a one-step plan (plain `:Nuntio load` on a request)
---@param block NuntioBlock
---@return NuntioPlan
function M.single(block)
  return {
    kind = "single",
    title = string.format("%s %s", block.method or "GET", block.url),
    scenarios = { { name = block.name or "request", weight = 1, step_names = { block.name or "request" }, steps = { block } } },
    owns = {},
    max_steps = 1,
    total_weight = 1,
  }
end

return M
