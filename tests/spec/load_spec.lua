local Config = require("nuntio.config")
local Data = require("nuntio.load.data")
local Diagnostics = require("nuntio.lsp.diagnostics")
local Document = require("nuntio.parser.document")
local Load = require("nuntio.load")
local Report = require("nuntio.load.report")
local Request = require("nuntio.request")
local Stats = require("nuntio.load.stats")
local Utils = require("nuntio.utils")

--- Write a file into a fresh temp directory and return both paths
local function temp_file(name, content)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, name)
  Utils.write_file(path, content)
  return path, dir
end

local function block_with(lines)
  local blocks = Document.parse_document(lines)
  return blocks[1]
end

describe("Load: options and limits", function()
  it("parses durations", function()
    assert_eq(Load.parse_duration("30s"), 30000)
    assert_eq(Load.parse_duration("2m"), 120000)
    assert_eq(Load.parse_duration("500ms"), 500)
    assert_eq(Load.parse_duration("45"), 45000)
    assert_eq(Load.parse_duration("1.5s"), 1500)
    assert_nil(Load.parse_duration("soon"))
    assert_nil(Load.parse_duration("10h"))
  end)

  it("parses key=value options with aliases", function()
    local opts = Load.parse_options({ "n=500", "c=20", "duration=30s", "timeout=5000" })
    assert_eq(opts.requests, 500)
    assert_eq(opts.concurrency, 20)
    assert_eq(opts.duration, 30000)
    assert_eq(opts.timeout, 5000, "plain timeout values are milliseconds")
    assert_eq(Load.parse_options({ "timeout=2s" }).timeout, 2000)

    local _, err = Load.parse_options({ "rps=10" })
    assert_true(err:find("unknown option", 1, true) ~= nil)
    _, err = Load.parse_options({ "requests=0" })
    assert_true(err:find("invalid value", 1, true) ~= nil)
    _, err = Load.parse_options({ "concurrency=many" })
    assert_true(err:find("invalid value", 1, true) ~= nil)
  end)

  it("merges # @load directives with command arguments and applies defaults", function()
    local block = block_with({
      "# @load requests=200 concurrency=5",
      "# @load timeout=3000",
      "GET https://api.example.com/search",
    })
    local opts = Load.collect_options(block, { "concurrency=8" })
    assert_eq(opts.requests, 200)
    assert_eq(opts.concurrency, 8, "arguments override directives")
    assert_eq(opts.timeout, 3000)

    local plain = block_with({ "GET https://api.example.com/search" })
    local defaults = Load.collect_options(plain, {})
    assert_eq(defaults.requests, Config.get().load.defaults.requests)
    assert_eq(defaults.concurrency, Config.get().load.defaults.concurrency)

    local timed = Load.collect_options(plain, { "duration=10s" })
    assert_nil(timed.requests, "duration-only runs have no request count")

    local clamped = Load.collect_options(plain, { "requests=3", "concurrency=10" })
    assert_eq(clamped.concurrency, 3, "concurrency never exceeds the request count")
  end)

  it("refuses runs above the curl backend limits with an explanation", function()
    assert_nil(Load.validate({ requests = 100, concurrency = 10 }))

    local err = Load.validate({ requests = 10000, concurrency = 200, duration = 3600000 })
    assert_true(err:find("concurrency 200 > 50", 1, true) ~= nil, err)
    assert_true(err:find("requests 10000 > 5000", 1, true) ~= nil, err)
    assert_true(err:find("duration 3600s > 300s", 1, true) ~= nil, err)
    assert_true(err:find("oha, vegeta, k6", 1, true) ~= nil, "points to dedicated tools")

    local limits = Config.get().load.curl
    local saved = limits.max_concurrency
    limits.max_concurrency = 500
    assert_nil(Load.validate({ requests = 100, concurrency = 200 }), "limits are configurable")
    limits.max_concurrency = saved
  end)
end)

describe("Load: statistics", function()
  it("computes nearest-rank percentiles", function()
    local sorted = {}
    for i = 1, 100 do sorted[i] = i end
    assert_eq(Stats.percentile(sorted, 50), 50)
    assert_eq(Stats.percentile(sorted, 95), 95)
    assert_eq(Stats.percentile(sorted, 99), 99)
    assert_eq(Stats.percentile({ 7 }, 99), 7)
    assert_nil(Stats.percentile({}, 50))
  end)

  it("summarizes throughput, statuses, latency, histogram and failures", function()
    local c = Stats.new()
    for i = 1, 8 do
      Stats.record(c, { ok = true, status = 200, wall_ms = i * 10 + 5, total_ms = i * 10, ttfb_ms = i * 8 })
    end
    Stats.record(c, { ok = false, status = 503, wall_ms = 300, total_ms = 290 })
    Stats.record(c, { ok = false, status = 200, wall_ms = 60, total_ms = 55, assert_failed = true, failed_asserts = { "body $.ok == true" } })
    Stats.record(c, { ok = false, error = "curl: (7) Failed to connect", wall_ms = 5 })

    local r = Stats.summarize(c, 2000)
    assert_eq(r.total, 11)
    assert_eq(r.succeeded, 8)
    assert_eq(r.failed, 3)
    assert_eq(r.assert_failed, 1)
    assert_eq(r.statuses["200"], 9)
    assert_eq(r.statuses["503"], 1)
    assert_eq(r.statuses["error"], 1)
    assert_eq(r.errors["curl: (7) Failed to connect"], 1)
    assert_eq(r.assert_errors["body $.ok == true"], 1)
    assert_eq(r.rps, 5.5)
    assert_eq(r.latency.min, 10)
    assert_eq(r.latency.max, 290)
    assert_eq(r.ttfb.min, 8)

    local in_histogram = 0
    for _, b in ipairs(r.histogram) do in_histogram = in_histogram + b.count end
    assert_eq(in_histogram, 10, "transport errors are excluded from latency")
    assert_eq(r.histogram[1].count, 4, "<50ms bucket")
    assert_true(not r.client_bound, "server time dominates")
  end)

  it("flags runs dominated by local overhead as client-bound", function()
    local c = Stats.new()
    for _ = 1, 10 do
      Stats.record(c, { ok = true, status = 200, wall_ms = 12, total_ms = 2 })
    end
    local r = Stats.summarize(c, 100)
    assert_true(r.overhead_ratio > 0.8)
    assert_true(r.client_bound)
    assert_true(not Stats.summarize(c, 100, 0.95).client_bound, "threshold is configurable")
  end)
end)

describe("Load: data files", function()
  it("parses CSV with quoting, CRLF and empty fields", function()
    local rows = Data.parse_csv('sku,name,price\r\nA1,"Guitar, nylon",10\r\nB2,"Bass ""5-string""",\r\n\r\n')
    assert_eq(#rows, 2)
    assert_eq(rows[1].sku, "A1")
    assert_eq(rows[1].name, "Guitar, nylon")
    assert_eq(rows[1].price, "10")
    assert_eq(rows[2].name, 'Bass "5-string"')
    assert_eq(rows[2].price, "")

    local _, err = Data.parse_csv("sku,name\n")
    assert_true(err:find("no rows", 1, true) ~= nil)
  end)

  it("loads CSV and JSON files and reports bad ones", function()
    local csv = temp_file("p.csv", "sku\nA1\nB2\n")
    assert_eq(#Data.load(csv), 2)

    local json = temp_file("p.json", '[{"sku":"A1","qty":2},{"sku":"B2","qty":1}]')
    local rows = Data.load(json)
    assert_eq(rows[2].sku, "B2")
    assert_eq(rows[1].qty, 2)

    local bad = temp_file("bad.json", '{"sku":"A1"}')
    local none, err = Data.load(bad)
    assert_nil(none)
    assert_true(err:find("array of objects", 1, true) ~= nil)

    local _, missing = Data.load("/definitely/not/here.csv")
    assert_true(missing:find("not found", 1, true) ~= nil)
  end)

  it("parses # @data directives", function()
    local spec = Data.parse_directive("./products.csv")
    assert_eq(spec.path, "./products.csv")
    assert_eq(spec.mode, "circular", "default mode")
    assert_eq(Data.parse_directive("./p.json mode=unique").mode, "unique")

    local _, err = Data.parse_directive("./p.csv mode=shuffle")
    assert_true(err:find("unknown mode", 1, true) ~= nil)
    _, err = Data.parse_directive("./p.csv order=random")
    assert_true(err:find("unknown option", 1, true) ~= nil)
    _, err = Data.parse_directive("")
    assert_true(err:find("missing", 1, true) ~= nil)
  end)

  it("feeds rows in each mode", function()
    local rows = { { id = 1 }, { id = 2 }, { id = 3 } }

    local seq = Data.feeder(rows, "sequential")
    assert_eq(seq.next().id, 1)
    assert_eq(seq.next().id, 2)
    assert_eq(seq.next().id, 3)
    assert_nil(seq.next(), "sequential stops when rows run out")

    local circ = Data.feeder(rows, "circular")
    local ids = {}
    for _ = 1, 5 do table.insert(ids, circ.next().id) end
    assert_eq(table.concat(ids, ","), "1,2,3,1,2")

    local uniq = Data.feeder(rows, "unique")
    local seen = {}
    for _ = 1, 3 do seen[uniq.next().id] = true end
    assert_true(seen[1] and seen[2] and seen[3], "unique yields every row once")
    assert_nil(uniq.next())

    local rand = Data.feeder(rows, "random")
    for _ = 1, 20 do
      local id = rand.next().id
      assert_true(id >= 1 and id <= 3)
    end
  end)
end)

describe("Load: per-iteration resolution", function()
  it("resolves data columns and load dynamic variables per call", function()
    local block = block_with({
      "# @assert body $.sku == {{data.sku}}",
      "GET https://api.example.com/items/{{data.sku}}?i={{$iteration}}&vu={{$vu}}&n={{$vuIteration}}",
      "X-Store: {{data.store}}",
    })
    local function resolve(row, it, vu, n)
      return Request.resolve(block, {}, vim.uv.cwd(), nil, nil, {
        env = { vars = { region = "amazon" }, default_headers = {} },
        extra_env = { data = row },
        dynamic = {
          ["$iteration"] = function() return it end,
          ["$vu"] = function() return vu end,
          ["$vuIteration"] = function() return n end,
        },
      })
    end

    local a = resolve({ sku = "A1", store = "MAO-01" }, 1, 1, 1)
    local b = resolve({ sku = "B2", store = "MAO-02" }, 2, 2, 1)
    assert_eq(a.url, "https://api.example.com/items/A1?i=1&vu=1&n=1")
    assert_eq(b.url, "https://api.example.com/items/B2?i=2&vu=2&n=1")
    assert_eq(a.headers["X-Store"], "MAO-01")
    assert_eq(b.assertions[1], "body $.sku == B2", "assertions see the same row")
  end)
end)

describe("Load: report and diagnostics", function()
  local function sample_report(client_bound)
    local c = Stats.new()
    for i = 1, 20 do
      Stats.record(c, { ok = true, status = 200, wall_ms = client_bound and 40 or (i * 10 + 1), total_ms = client_bound and 2 or i * 10 })
    end
    Stats.record(c, { ok = false, error = "request timed out after 5000ms", wall_ms = 5000 })
    return Stats.summarize(c, 1000)
  end

  it("formats the finished report", function()
    local lines = Report.format(sample_report(false), {
      title = "GET https://api.example.com/search",
      state = "done",
      plan = "21 requests · concurrency 4",
      data = "products.csv (random, 3 rows)",
    })
    local text = table.concat(lines, "\n")
    assert_true(text:find("Load test · GET https://api.example.com/search", 1, true) ~= nil)
    assert_true(text:find("✘ done in 1.00s", 1, true) ~= nil, "a failed request marks the run as failed")
    assert_true(text:find("backend: curl", 1, true) ~= nil)
    assert_true(text:find("data: products.csv (random, 3 rows)", 1, true) ~= nil)
    assert_true(text:find("Throughput   21.0 req/s", 1, true) ~= nil)
    assert_true(text:find("Success      20 / 21  (95.2%)", 1, true) ~= nil)
    assert_true(text:find("Status       200 ×20   error ×1", 1, true) ~= nil)
    assert_true(text:find("Latency (ms)", 1, true) ~= nil)
    assert_true(text:find("×1     request timed out after 5000ms", 1, true) ~= nil)
    assert_true(text:find("Client-bound", 1, true) == nil)
  end)

  it("warns about client-bound runs only once finished", function()
    local report = sample_report(true)
    local done = table.concat(Report.format(report, { title = "GET /", state = "done", plan = "" }), "\n")
    assert_true(done:find("⚠ Client-bound", 1, true) ~= nil)
    local running = table.concat(Report.format(report, { title = "GET /", state = "running", plan = "" }), "\n")
    assert_true(running:find("Client-bound", 1, true) == nil)
    assert_true(Report.short(report):find("rps · 20/21 ok · p95", 1, true) ~= nil)
  end)

  it("validates # @load and # @data lines and allows {{data.*}} with @data", function()
    local csv, dir = temp_file("rows.csv", "sku\nA1\n")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(dir, "load_diag.http"))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# @load requests=100 concurrency=10",
      "# @data ./" .. vim.fs.basename(csv) .. " mode=random",
      "GET https://api.example.com/items/{{data.sku}}?i={{$iteration}}",
      "",
      "###",
      "# @load rps=10",
      "# @data ./missing.csv",
      "GET https://api.example.com/other",
    })
    Diagnostics.check(buf)
    local diags = vim.diagnostic.get(buf)
    local messages = {}
    for _, d in ipairs(diags) do
      table.insert(messages, d.lnum .. ":" .. d.message)
    end
    local all = table.concat(messages, "\n")
    assert_eq(#diags, 2, all)
    assert_true(all:find("5:Invalid @load: unknown option 'rps=10'", 1, true) ~= nil, all)
    assert_true(all:find("6:Invalid @data: data file not found: './missing.csv'", 1, true) ~= nil, all)
    vim.api.nvim_buf_delete(buf, { force = true })

    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(plain, 0, -1, false, { "GET https://api.example.com/items/{{data.sku}}" })
    Diagnostics.check(plain)
    assert_eq(#vim.diagnostic.get(plain), 1, "data.* is undefined without # @data")
    vim.api.nvim_buf_delete(plain, { force = true })
  end)
end)
