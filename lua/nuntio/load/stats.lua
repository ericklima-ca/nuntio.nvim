local M = {}

--- Upper bounds (ms) of the latency histogram buckets
M.buckets = { 50, 100, 200, 400, 800, 1600, math.huge }

---@class NuntioLoadSample
---@field ok boolean Request succeeded (status 2xx/3xx, or all assertions passed)
---@field status? integer HTTP status, nil on transport errors
---@field error? string Transport error summary
---@field wall_ms number Spawn-to-exit time measured by Neovim
---@field total_ms? number curl's own time_total
---@field ttfb_ms? number curl's time_starttransfer
---@field assert_failed? boolean At least one # @assert failed
---@field failed_asserts? string[] Expressions of failed assertions

---@class NuntioLoadCollector
---@field samples NuntioLoadSample[]

--- Create an empty collector
---@return NuntioLoadCollector
function M.new()
  return { samples = {} }
end

---@param c NuntioLoadCollector
---@param sample NuntioLoadSample
function M.record(c, sample)
  table.insert(c.samples, sample)
end

--- Nearest-rank percentile of an ascending list
---@param sorted number[]
---@param p number 0-100
---@return number|nil
function M.percentile(sorted, p)
  local n = #sorted
  if n == 0 then return nil end
  local rank = math.ceil(p / 100 * n)
  return sorted[math.min(math.max(rank, 1), n)]
end

--- Summary statistics for a list of values
---@param values number[]
---@return table|nil { min, p50, p90, p95, p99, max, mean }
function M.distribution(values)
  if #values == 0 then return nil end
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  local sum = 0
  for _, v in ipairs(sorted) do
    sum = sum + v
  end
  return {
    min = sorted[1],
    p50 = M.percentile(sorted, 50),
    p90 = M.percentile(sorted, 90),
    p95 = M.percentile(sorted, 95),
    p99 = M.percentile(sorted, 99),
    max = sorted[#sorted],
    mean = sum / #sorted,
  }
end

---@class NuntioLoadReport
---@field total integer
---@field succeeded integer
---@field failed integer
---@field assert_failed integer
---@field success_rate number 0-100
---@field elapsed_ms number
---@field rps number
---@field statuses table<string, integer> "200" / "error" -> count
---@field errors table<string, integer> Transport error summary -> count
---@field assert_errors table<string, integer> Failed assertion expression -> count
---@field latency? table Distribution of curl time_total (or wall time)
---@field ttfb? table Distribution of time to first byte
---@field histogram { le: number, count: integer }[]
---@field overhead_ratio number Share of wall time spent outside curl's transfer
---@field client_bound boolean

--- Aggregate samples into a report
---@param c NuntioLoadCollector
---@param elapsed_ms number
---@param client_bound_threshold? number
---@return NuntioLoadReport
function M.summarize(c, elapsed_ms, client_bound_threshold)
  local report = {
    total = #c.samples,
    succeeded = 0,
    failed = 0,
    assert_failed = 0,
    statuses = {},
    errors = {},
    assert_errors = {},
    elapsed_ms = elapsed_ms,
    histogram = {},
  }

  local latencies, ttfbs = {}, {}
  local wall_sum, overhead_sum = 0, 0
  for _, b in ipairs(M.buckets) do
    table.insert(report.histogram, { le = b, count = 0 })
  end

  for _, s in ipairs(c.samples) do
    if s.ok then
      report.succeeded = report.succeeded + 1
    else
      report.failed = report.failed + 1
    end
    if s.assert_failed then
      report.assert_failed = report.assert_failed + 1
    end
    for _, expr in ipairs(s.failed_asserts or {}) do
      report.assert_errors[expr] = (report.assert_errors[expr] or 0) + 1
    end

    local key = s.status and tostring(s.status) or "error"
    report.statuses[key] = (report.statuses[key] or 0) + 1
    if s.error then
      report.errors[s.error] = (report.errors[s.error] or 0) + 1
    end

    -- Latency stats only cover requests that got a response
    if s.status then
      local latency = s.total_ms or s.wall_ms
      table.insert(latencies, latency)
      if s.ttfb_ms then
        table.insert(ttfbs, s.ttfb_ms)
      end
      for _, bucket in ipairs(report.histogram) do
        if latency < bucket.le then
          bucket.count = bucket.count + 1
          break
        end
      end
      if s.total_ms then
        wall_sum = wall_sum + s.wall_ms
        overhead_sum = overhead_sum + math.max(0, s.wall_ms - s.total_ms)
      end
    end
  end

  report.success_rate = report.total > 0 and (report.succeeded / report.total * 100) or 0
  report.rps = elapsed_ms > 0 and (report.total / (elapsed_ms / 1000)) or 0
  report.latency = M.distribution(latencies)
  report.ttfb = M.distribution(ttfbs)
  report.overhead_ratio = wall_sum > 0 and (overhead_sum / wall_sum) or 0
  report.client_bound = report.overhead_ratio >= (client_bound_threshold or 0.3)

  return report
end

return M
