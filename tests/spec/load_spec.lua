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

describe("Load: scenarios", function()
  local Scenario = require("nuntio.load.scenario")
  local RequestVars = require("nuntio.parser.request_vars")
  local Store = require("nuntio.store")

  local doc = {
    "### Login",
    "# @name login",
    "POST https://api.example.com/login",
    "",
    "### Browse",
    "# @name browse",
    "GET https://api.example.com/products",
    "",
    "### Checkout",
    "# @name checkout",
    "POST https://api.example.com/checkout",
    "",
    "### Scenario: buyer",
    "# @scenario buyer weight=30",
    "# @steps login -> browse -> checkout",
    "# @think 200..800ms",
    "# @load iterations=50 concurrency=5",
    "",
    "### Scenario: window shopper",
    "# @scenario shopper weight=70",
    "# @steps login, browse",
    "",
    "### Mix",
    "# @load-mix buyer shopper",
    "# @load duration=30s concurrency=10",
  }

  it("parses think times, headers and step lists", function()
    local t = Scenario.parse_think("200..800ms")
    assert_eq(t.min, 200)
    assert_eq(t.max, 800)
    t = Scenario.parse_think("1s..2s")
    assert_eq(t.min, 1000)
    assert_eq(t.max, 2000)
    t = Scenario.parse_think("500ms")
    assert_eq(t.min, 500)
    assert_eq(t.max, 500)
    assert_nil(Scenario.parse_think("soon"))
    local _, err = Scenario.parse_think("900..100ms")
    assert_true(err:find("reversed", 1, true) ~= nil)

    local h = Scenario.parse_header("checkout weight=30")
    assert_eq(h.name, "checkout")
    assert_eq(h.weight, 30)
    assert_eq(Scenario.parse_header("checkout").weight, 1)
    _, err = Scenario.parse_header("checkout weight=0")
    assert_true(err:find("weight", 1, true) ~= nil)

    assert_eq(table.concat(Scenario.split_names("login -> browse->checkout"), ","), "login,browse,checkout")
    assert_eq(table.concat(Scenario.split_names("a, b c"), ","), "a,b,c")
  end)

  it("keeps request-less scenario and mix blocks out of the request list", function()
    local blocks, _, plans = Document.parse_document(doc)
    assert_eq(#blocks, 3, "only real requests are runnable blocks")
    assert_eq(#plans, 3)
    assert_true(plans[1].is_plan)
    assert_eq(plans[1].metadata["scenario"][1], "buyer weight=30")
    assert_eq(plans[3].metadata["load-mix"][1], "buyer shopper")
    assert_eq(plans[1].icon_line, 13, "progress shows on the ### line")
  end)

  it("builds scenario and mix plans", function()
    local blocks, _, plans = Document.parse_document(doc)
    local buyer = Scenario.build(plans[1], blocks, plans)
    assert_eq(buyer.kind, "scenario")
    assert_eq(#buyer.scenarios[1].steps, 3)
    assert_eq(buyer.scenarios[1].steps[3].url, "https://api.example.com/checkout")
    assert_eq(buyer.scenarios[1].think.max, 800)
    assert_true(buyer.owns.login and buyer.owns.checkout)
    assert_eq(buyer.title, "scenario buyer (login → browse → checkout)")

    local mix = Scenario.build(plans[3], blocks, plans)
    assert_eq(mix.kind, "mix")
    assert_eq(#mix.scenarios, 2)
    assert_eq(mix.total_weight, 100)
    assert_eq(mix.max_steps, 3)
    assert_eq(mix.title, "mix buyer 30% · shopper 70%")

    -- Weighted pick: roll 1..30 -> buyer, 31..100 -> shopper
    assert_eq(Scenario.pick(mix, function() return 30 end).name, "buyer")
    assert_eq(Scenario.pick(mix, function() return 31 end).name, "shopper")
  end)

  it("reports unknown steps and scenarios", function()
    local blocks, _, plans = Document.parse_document({
      "# @name login",
      "GET https://api.example.com/login",
      "",
      "### Broken",
      "# @scenario broken",
      "# @steps login -> missing",
      "",
      "### Empty",
      "# @scenario empty",
      "",
      "### Mix",
      "# @load-mix broken ghost",
    })
    local _, err = Scenario.build(plans[1], blocks, plans)
    assert_true(err:find("unknown request 'missing'", 1, true) ~= nil, err)
    _, err = Scenario.build(plans[2], blocks, plans)
    assert_true(err:find("has no steps", 1, true) ~= nil, err)
    _, err = Scenario.build(plans[3], blocks, plans)
    assert_true(err:find("unknown request 'missing'", 1, true) ~= nil or err:find("unknown scenario 'ghost'", 1, true) ~= nil, err)
  end)

  it("resolves chained values from the virtual user's context, never from history", function()
    Store.add_response({ name = "login", status = 200, json = { token = "GLOBAL" }, body = '{"token":"GLOBAL"}', headers = {} },
      { url = "u", method = "POST", headers = {}, body = "" })
    local ctx = {
      responses = { login = { status = 200, json = { token = "VU-7" }, body = '{"token":"VU-7"}', headers = { ["X-Session"] = "s7" } } },
      requests = { login = { url = "https://api.example.com/login", method = "POST", headers = {}, body = "" } },
      owns = { login = true, browse = true },
    }
    assert_eq(RequestVars.resolve("login.response.body.$.token", ctx), "VU-7")
    assert_eq(RequestVars.resolve("login.response.headers.X-Session", ctx), "s7")
    assert_eq(RequestVars.resolve("login.request.url", ctx), "https://api.example.com/login")
    assert_nil(RequestVars.resolve("browse.response.body.$.id", ctx), "owned step not run yet: no fallback")
    assert_eq(RequestVars.resolve("login.response.body.$.token"), "GLOBAL", "normal runs still use history")

    local block = Document.parse_document({ "GET https://api.example.com/me?t={{login.response.body.$.token}}" })[1]
    local resolved = Request.resolve(block, {}, vim.uv.cwd(), nil, nil, { env = { vars = {}, default_headers = {} }, chain = ctx })
    assert_eq(resolved.url, "https://api.example.com/me?t=VU-7")

    -- Remove the planted entry so later specs see a clean history
    table.remove(Store.history)
    Store.by_name.login = nil
    Store.sent_requests.login = nil
  end)

  it("scales the request limit by scenario length and accepts iterations=", function()
    assert_eq(Load.parse_options({ "iterations=40" }).requests, 40)
    assert_eq(Load.parse_options({ "i=40" }).requests, 40)
    assert_nil(Load.validate({ requests = 1000, concurrency = 10 }, 5))
    local err = Load.validate({ requests = 2000, concurrency = 10 }, 3)
    assert_true(err:find("requests 6000 (2000 iterations × 3 steps) > 5000", 1, true) ~= nil, err)
  end)

  it("renders per-scenario and per-step tables", function()
    local c = Stats.new()
    Stats.record(c, { ok = true, status = 200, wall_ms = 30, total_ms = 25 })
    local step = Stats.summarize(c, 1000)
    local report = Stats.summarize(c, 1000)
    report.breakdown = {
      scenarios = { { name = "buyer", weight = 30, iterations = 4, ok = 3, duration = Stats.distribution({ 900, 1100, 1200, 2400 }) } },
      steps = { { name = "login", report = step } },
    }
    local text = table.concat(Report.format(report, { title = "scenario buyer", state = "done", plan = "" }), "\n")
    assert_true(text:find("Scenario           weight   iters", 1, true) ~= nil, text)
    assert_true(text:find("buyer", 1, true) ~= nil)
    assert_true(text:find("75.0%", 1, true) ~= nil, "scenario ok%")
    assert_true(text:find("1.10s", 1, true) ~= nil, "iteration p50")
    assert_true(text:find("login", 1, true) ~= nil and text:find("100.0%", 1, true) ~= nil, "step row")
  end)

  it("flags invalid scenario directives", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# @name login",
      "GET https://api.example.com/login",
      "",
      "### Good",
      "# @scenario good weight=2",
      "# @steps login",
      "# @think 100..300ms",
      "",
      "### Bad",
      "# @scenario bad weight=x",
      "# @steps login -> nope",
      "# @think later",
      "",
      "### Mix",
      "# @load-mix good ghost",
    })
    Diagnostics.check(buf)
    local messages = {}
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      table.insert(messages, d.lnum .. ":" .. d.message)
    end
    local all = table.concat(messages, "\n")
    assert_eq(#messages, 4, all)
    assert_true(all:find("9:Invalid @scenario", 1, true) ~= nil, all)
    assert_true(all:find("10:Invalid @steps: unknown request 'nope'", 1, true) ~= nil, all)
    assert_true(all:find("11:Invalid @think", 1, true) ~= nil, all)
    assert_true(all:find("14:Invalid @load-mix: unknown scenario 'ghost'", 1, true) ~= nil, all)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
