local M = {}

local BAR_WIDTH = 30

---@param ms number
---@return string
local function fmt_secs(ms)
  return string.format("%.2fs", ms / 1000)
end

--- Sort status keys numerically, transport errors last
---@param statuses table<string, integer>
---@return string[]
local function sorted_status_keys(statuses)
  local keys = vim.tbl_keys(statuses)
  table.sort(keys, function(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    if na then return true end
    if nb then return false end
    return a < b
  end)
  return keys
end

--- Sort a `label -> count` map by descending count
---@param counts table<string, integer>
---@return { label: string, count: integer }[]
local function by_count(counts)
  local list = {}
  for label, count in pairs(counts) do
    table.insert(list, { label = label, count = count })
  end
  table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.label < b.label
  end)
  return list
end

---@class NuntioLoadReportMeta
---@field title string e.g. "GET https://api/search"
---@field state "running"|"done"|"cancelled"
---@field progress? string e.g. "213/500"
---@field plan string e.g. "500 requests · concurrency 20"
---@field data? string e.g. "products.csv (random, 120 rows)"
--- (report.breakdown, when present, adds per-scenario and per-step tables)

--- Render a load report into display lines
---@param report NuntioLoadReport
---@param meta NuntioLoadReportMeta
---@return string[]
function M.format(report, meta)
  local lines = {}
  local function add(s) table.insert(lines, s) end

  add(" 󰓅 Load test · " .. meta.title)
  add(" " .. string.rep("═", 78))

  local state_line
  if meta.state == "running" then
    state_line = string.format("  ⏳ running %s · %s elapsed", meta.progress or "", fmt_secs(report.elapsed_ms))
  elseif meta.state == "cancelled" then
    state_line = string.format("  ✘ cancelled after %s", fmt_secs(report.elapsed_ms))
  else
    local icon = report.failed == 0 and "✔" or "✘"
    state_line = string.format("  %s done in %s", icon, fmt_secs(report.elapsed_ms))
  end
  add(string.format("%s   ·   %s · backend: curl", state_line, meta.plan))
  if meta.data then
    add("  data: " .. meta.data)
  end
  add("")

  if report.total == 0 then
    add("  Waiting for the first responses...")
    return lines
  end

  add(string.format("  Throughput   %.1f req/s", report.rps))
  add(string.format("  Success      %d / %d  (%.1f%%)", report.succeeded, report.total, report.success_rate))
  local status_parts = {}
  for _, key in ipairs(sorted_status_keys(report.statuses)) do
    table.insert(status_parts, string.format("%s ×%d", key, report.statuses[key]))
  end
  add("  Status       " .. table.concat(status_parts, "   "))
  add("")

  if report.breakdown then
    add("  Scenario           weight   iters      ok%   iter p50   iter p95")
    for _, sc in ipairs(report.breakdown.scenarios) do
      local d = sc.duration
      add(string.format("  %-18s %6d %7d %7.1f%% %10s %10s", sc.name, sc.weight, sc.iterations,
        sc.iterations > 0 and sc.ok / sc.iterations * 100 or 0,
        d and fmt_secs(d.p50) or "-", d and fmt_secs(d.p95) or "-"))
    end
    add("")
    add("  Step                 reqs      ok%     p50     p95     p99      rps")
    for _, step in ipairs(report.breakdown.steps) do
      local r, l = step.report, step.report.latency
      add(string.format("  %-18s %6d %7.1f%% %7s %7s %7s %8.1f", step.name, r.total, r.success_rate,
        l and string.format("%.0f", l.p50) or "-", l and string.format("%.0f", l.p95) or "-",
        l and string.format("%.0f", l.p99) or "-", r.rps))
    end
    add("")
  end

  if report.latency then
    add("  Latency (ms)     min     p50     p90     p95     p99     max")
    for _, row in ipairs({ { "total", report.latency }, { "ttfb", report.ttfb } }) do
      local d = row[2]
      if d then
        add(string.format("  %-12s %7.0f %7.0f %7.0f %7.0f %7.0f %7.0f",
          row[1], d.min, d.p50, d.p90, d.p95, d.p99, d.max))
      end
    end
    add("")

    add("  Histogram (total ms)")
    local max_count = 0
    for _, b in ipairs(report.histogram) do
      max_count = math.max(max_count, b.count)
    end
    local lower = 0
    for _, b in ipairs(report.histogram) do
      local label = b.le == math.huge and string.format("%d+", lower) or string.format("%d-%d", lower, b.le)
      local width = max_count > 0 and math.floor(b.count / max_count * BAR_WIDTH + 0.5) or 0
      if b.count > 0 and width == 0 then width = 1 end
      -- Pad by display width: "█" is multi-byte, so %-Ns would misalign
      local bar = string.rep("█", width) .. string.rep(" ", BAR_WIDTH - width)
      add(string.format("  %10s  %s %d", label, bar, b.count))
      if b.le ~= math.huge then lower = b.le end
    end
    add("")
  end

  if next(report.errors) then
    add("  Errors")
    for _, e in ipairs(by_count(report.errors)) do
      add(string.format("    ×%-5d %s", e.count, e.label))
    end
    add("")
  end

  if next(report.assert_errors) then
    add("  Failed assertions")
    for _, e in ipairs(by_count(report.assert_errors)) do
      add(string.format("    ×%-5d %s", e.count, e.label))
    end
    add("")
  end

  if report.client_bound and meta.state ~= "running" then
    add(string.format("  ⚠ Client-bound: %.0f%% of request time was spent in local overhead", report.overhead_ratio * 100))
    add("    (process spawning, scheduling), not waiting on the server. Throughput is")
    add("    a lower bound. For higher load use a dedicated tool such as oha, vegeta or k6.")
  end

  return lines
end

--- One-line summary for the request line and notifications
---@param report NuntioLoadReport
---@return string
function M.short(report)
  local p95 = report.latency and report.latency.p95
  local s = string.format("%.0f rps · %d/%d ok", report.rps, report.succeeded, report.total)
  if p95 then
    s = s .. string.format(" · p95 %.0fms", p95)
  end
  return s
end


return M
