local Document = require("nuntio.parser.document")
local Load = require("nuntio.load")
local Runner = require("nuntio.runner")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")
local View = require("nuntio.ui.view")

describe("End-to-End Integration with Local HTTP Server", function()
  -- Start a background python HTTP server on 127.0.0.1:19877
  local py_code = [[
import http.server, socketserver, threading, time, json

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Server", "nuntio-test-server")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok", "user_id": 99, "path": self.path,
                                     "cookie": self.headers.get("Cookie")}).encode("utf-8"))

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = self.rfile.read(length).decode("utf-8")
        try:
            user = json.loads(body).get("user")
        except Exception:
            user = None
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        if user:
            self.send_header("Set-Cookie", "sid=" + user + "; Path=/")
        self.end_headers()
        self.wfile.write(json.dumps({"created": True, "token": "session_tok_777", "body": body,
                                     "user": user}).encode("utf-8"))

    def log_message(self, format, *args):
        pass

class ReusableServer(socketserver.TCPServer):
    allow_reuse_address = True

server = ReusableServer(("127.0.0.1", 19877), Handler)
server.serve_forever()
]]
  local srv_job = vim.system({ "python3", "-c", py_code })
  -- Wait until server is listening
  local started = false
  for _ = 1, 30 do
    local test_conn = vim.uv.new_tcp()
    test_conn:connect("127.0.0.1", 19877, function(err)
      if not err then started = true end
      test_conn:close()
    end)
    vim.wait(50, function() return started end)
    if started then break end
  end

  it("executes GET request and captures response", function()
    local text = [[
# @name get_user
GET http://127.0.0.1:19877/user
Accept: application/json
]]
    local lines = Utils.split_lines(text)
    local blocks, doc_vars = Document.parse_document(lines)
    assert_eq(#blocks, 1)

    local done = false
    local result_resp = nil

    Runner.run_block(blocks[1], doc_vars, 0, vim.uv.cwd(), nil, function(success, resp)
      done = true
      result_resp = resp
    end)

    vim.wait(3000, function() return done end, 50)
    assert_true(done, "request finished")
    assert_true(result_resp ~= nil, "response received")
    assert_eq(result_resp.status, 200)
    assert_eq(result_resp.headers["x-server"], "nuntio-test-server")
    assert_true(result_resp.json ~= nil)
    assert_eq(result_resp.json.user_id, 99)
  end)

  it("chains POST request referencing prior GET response variable", function()
    local text = [[
# @env-json-key saved_token = $.token
POST http://127.0.0.1:19877/session
Content-Type: application/json

{
  "target_user": {{get_user.response.body.$.user_id}}
}
]]
    local lines = Utils.split_lines(text)
    local blocks, doc_vars = Document.parse_document(lines)
    assert_eq(#blocks, 1)

    local done = false
    local result_resp = nil

    Runner.run_block(blocks[1], doc_vars, 0, vim.uv.cwd(), nil, function(success, resp)
      done = true
      result_resp = resp
    end)

    vim.wait(3000, function() return done end, 50)
    assert_true(done, "post request finished")
    assert_true(result_resp ~= nil, "response received")
    assert_eq(result_resp.status, 201)
    assert_eq(Store.get_global("saved_token"), "session_tok_777")
  end)

  it("automatically resolves and executes unexecuted prerequisite requests", function()
    -- Clear Store to simulate fresh session without prior runs
    Store.responses = {}
    Store.requests = {}

    local text = [[
### Request A: Prerequisite (Not run yet)
# @name auto_init
GET http://127.0.0.1:19877/user
Accept: application/json

### Request B: Dependent
# @name auto_dependent
POST http://127.0.0.1:19877/session
Content-Type: application/json

{
  "user_from_prereq": {{auto_init.response.body.$.user_id}}
}
]]
    local lines = Utils.split_lines(text)
    local blocks, doc_vars = Document.parse_document(lines)
    assert_eq(#blocks, 2)

    local target_block = blocks[2]
    local done = false
    local result_resp = nil

    -- Run target_block directly, passing blocks as all_blocks
    Runner.run_block(target_block, doc_vars, 0, vim.uv.cwd(), nil, function(success, resp)
      done = true
      result_resp = resp
    end, blocks)

    vim.wait(4000, function() return done end, 50)
    assert_true(done, "dependent request finished")
    assert_true(result_resp ~= nil, "response received")
    assert_eq(result_resp.status, 201)

    -- Verify that auto_init was executed into Store automatically
    local prereq_resp = Store.get_by_name("auto_init")
    assert_true(prereq_resp ~= nil, "prerequisite response was captured")
    assert_eq(prereq_resp.json.user_id, 99)

    -- Verify that target request payload received the resolved value
    local sent_body = vim.json.decode(result_resp.raw_body)
    local parsed_inner = vim.json.decode(sent_body.body)
    assert_eq(parsed_inner.user_from_prereq, 99)
  end)

  it("evaluates # @assert directives (with ### Shared asserts) against a live response", function()
    local text = [[
@expectedId = 99

### Shared
# @assert status < 500

### Assert user
# @assert status == 200
# @assert header Content-Type contains application/json
# @assert body $.user_id == {{expectedId}}
# @assert body $.status == "ok"
# @assert body $.missing exists
# @assert duration < 5000
GET http://127.0.0.1:19877/user
]]
    local blocks, doc_vars = Document.parse_document(Utils.split_lines(text))
    local shared, target
    for _, b in ipairs(blocks) do
      if b.is_shared then shared = b else target = b end
    end

    local done = false
    local result_resp = nil
    Runner.run_block(target, doc_vars, 0, vim.uv.cwd(), shared, function(_, resp)
      done = true
      result_resp = resp
    end)

    vim.wait(3000, function() return done end, 50)
    assert_true(result_resp ~= nil, "response received")
    local summary = result_resp.assertions
    assert_not_nil(summary, "assertion summary attached to response")
    assert_eq(summary.total, 7)
    assert_eq(summary.passed, 6)
    assert_eq(summary.failed, 1)
    assert_eq(summary.results[1].expr, "status < 500", "shared assertion runs first")
    assert_eq(summary.results[4].expr, "body $.user_id == 99", "variables interpolated")
    assert_eq(summary.results[6].ok, false, "missing field fails")
  end)

  --- Start a load test for the first request in `text` and wait for it to finish
  local function run_load(text, buffer_dir, args)
    local blocks, doc_vars = Document.parse_document(Utils.split_lines(text))
    local state, err = Load.start({
      block = blocks[1],
      doc_vars = doc_vars,
      bufnr = 0,
      buffer_dir = buffer_dir or vim.uv.cwd(),
      args = args,
    })
    if not state then return nil, err end
    vim.wait(15000, function() return state.finished end, 20)
    return state
  end

  it("load test: sends N requests with per-iteration data and assertions", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    Utils.write_file(vim.fs.joinpath(dir, "skus.csv"), "sku\nA1\nB2\nC3\n")

    local state = run_load([[
# @load requests=12 concurrency=3
# @data ./skus.csv mode=circular
# @assert status == 200
# @assert body $.path matches ^/item/%u%d%?i=%d+&vu=%d$
GET http://127.0.0.1:19877/item/{{data.sku}}?i={{$iteration}}&vu={{$vu}}
]], dir)
    assert_true(state.finished, "load test finished")
    local r = state.report
    assert_eq(r.total, 12)
    assert_eq(r.succeeded, 12, vim.inspect(r.assert_errors) .. vim.inspect(r.errors))
    assert_eq(r.statuses["200"], 12)
    assert_eq(next(r.errors), nil)
    assert_true(r.latency ~= nil and r.latency.p95 > 0, "latency measured from curl stats")
    assert_eq(state.dispatched, 12)
    assert_nil(Load.active, "no load test left running")
    assert_true(Load.last == state)
  end)

  it("load test: sequential data stops when rows run out", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    Utils.write_file(vim.fs.joinpath(dir, "two.csv"), "sku\nA1\nB2\n")
    local state = run_load([[
# @load requests=10 concurrency=2
# @data ./two.csv mode=sequential
GET http://127.0.0.1:19877/item/{{data.sku}}
]], dir)
    assert_eq(state.report.total, 2)
    assert_true(state.exhausted)
  end)

  it("load test: failing assertions count as failures", function()
    local state = run_load([[
# @assert status == 201
GET http://127.0.0.1:19877/user
]], nil, { "requests=4", "concurrency=2" })
    assert_eq(state.report.total, 4)
    assert_eq(state.report.succeeded, 0)
    assert_eq(state.report.assert_errors["status == 201"], 4)
  end)

  it("load test: duration mode runs until the deadline", function()
    local state = run_load("GET http://127.0.0.1:19877/user", nil, { "duration=1s", "concurrency=2" })
    assert_true(state.report.total > 0)
    assert_true(state.report.elapsed_ms >= 1000, "ran for the whole duration")
    assert_eq(state.report.failed, 0)
  end)

  it("load test: refuses runs above the curl backend limits", function()
    local state, err = run_load("GET http://127.0.0.1:19877/user", nil, { "requests=100", "concurrency=500" })
    assert_nil(state)
    assert_true(err:find("exceeds curl backend limits", 1, true) ~= nil, err)
    assert_nil(Load.active)
  end)

  it("load test: cancel keeps partial results", function()
    local blocks, doc_vars = Document.parse_document({ "GET http://127.0.0.1:19877/user" })
    local state = Load.start({
      block = blocks[1],
      doc_vars = doc_vars,
      bufnr = 0,
      buffer_dir = vim.uv.cwd(),
      args = { "duration=30s", "concurrency=2" },
    })
    vim.wait(5000, function() return state.completed >= 3 end, 20)
    assert_true(Load.cancel(), "cancel reports a running test")
    assert_true(state.finished and state.cancelled)
    assert_true(state.report.total >= 3)
    assert_nil(Load.active)
    assert_true(not Load.cancel(), "nothing left to cancel")
  end)

  --- Start a scenario/mix plan block named `plan_name` from `text` and wait for it
  local function run_plan(text, plan_index, args)
    local blocks, doc_vars, plans = Document.parse_document(Utils.split_lines(text))
    local state, err = Load.start({
      block = plans[plan_index or 1],
      blocks = blocks,
      plans = plans,
      doc_vars = doc_vars,
      bufnr = 0,
      buffer_dir = vim.uv.cwd(),
      args = args,
    })
    if not state then return nil, err end
    vim.wait(15000, function() return state.finished end, 20)
    return state
  end

  local scenario_doc = [[
### Login
# @name login
# @assert status == 201
POST http://127.0.0.1:19877/login
Content-Type: application/json

{ "user": "u{{$vu}}-{{$iteration}}" }

### Profile
# @name profile
# @assert body $.path == "/profile/u{{$vu}}-{{$iteration}}"
# @assert body $.cookie == "sid=u{{$vu}}-{{$iteration}}"
GET http://127.0.0.1:19877/profile/{{login.response.body.$.user}}

### Browse
# @name browse
GET http://127.0.0.1:19877/browse

### Scenario: session
# @scenario session weight=3
# @steps login -> profile
# @load iterations=12 concurrency=4

### Scenario: anonymous
# @scenario anonymous weight=1
# @steps browse
# @think 50ms

### Mix
# @load-mix session anonymous
# @load iterations=40 concurrency=4
]]

  it("scenario: chains and cookies stay isolated per virtual user and iteration", function()
    local state, err = run_plan(scenario_doc, 1)
    assert_true(state ~= nil, err)
    local r = state.report
    assert_eq(r.total, 24, "12 iterations × 2 steps")
    assert_eq(r.succeeded, 24, vim.inspect(r.assert_errors) .. vim.inspect(r.errors))
    local steps = {}
    for _, s in ipairs(r.breakdown.steps) do steps[s.name] = s.report end
    assert_eq(steps.login.total, 12)
    assert_eq(steps.profile.total, 12)
    assert_eq(r.breakdown.scenarios[1].iterations, 12)
    assert_eq(r.breakdown.scenarios[1].ok, 12)
    -- Scenario runs must not leak into the global history used by normal chaining
    assert_true(Store.get_by_name("login") == nil, "login response stayed out of Store")
  end)

  it("scenario: mix picks scenarios by weight", function()
    math.randomseed(42) -- weighted picks are random; keep the test deterministic
    local state, err = run_plan(scenario_doc, 3)
    assert_true(state ~= nil, err)
    local by_name = {}
    for _, sc in ipairs(state.report.breakdown.scenarios) do by_name[sc.name] = sc end
    assert_eq(by_name.session.iterations + by_name.anonymous.iterations, 40)
    assert_true(by_name.session.iterations > by_name.anonymous.iterations, "weight 3 beats weight 1")
    assert_eq(state.report.failed, 0, vim.inspect(state.report.assert_errors))
  end)

  it("scenario: a failed step ends the iteration and think time is applied", function()
    local doc = [[
### Gate
# @name gate
# @assert status == 418
GET http://127.0.0.1:19877/gate

### After
# @name after
GET http://127.0.0.1:19877/after

### Scenario: blocked
# @scenario blocked
# @steps gate -> after
# @load iterations=3 concurrency=1

### Scenario: slow
# @scenario slow
# @steps after -> after
# @think 60ms
# @load iterations=2 concurrency=1
]]
    local blocked = run_plan(doc, 1)
    local steps = {}
    for _, s in ipairs(blocked.report.breakdown.steps) do steps[s.name] = s.report end
    assert_eq(steps.gate.total, 3)
    assert_eq(steps.after.total, 0, "steps after a failure are skipped")
    assert_eq(blocked.report.breakdown.scenarios[1].ok, 0)

    local slow = run_plan(doc, 2)
    local d = slow.report.breakdown.scenarios[1].duration
    assert_true(d.min >= 60, "think time between steps: " .. tostring(d.min))
    assert_eq(slow.report.total, 4)
  end)

  it("scenario: refuses unknown steps before sending anything", function()
    local state, err = run_plan([[
### Scenario: broken
# @scenario broken
# @steps nowhere
]], 1)
    assert_nil(state)
    assert_true(err:find("unknown request 'nowhere'", 1, true) ~= nil, err)
    assert_nil(Load.active)
  end)

  -- Terminate background server
  pcall(function() srv_job:kill("sigterm") end)
end)
