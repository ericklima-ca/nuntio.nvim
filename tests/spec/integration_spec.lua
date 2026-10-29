local Document = require("nuntio.parser.document")
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
        self.wfile.write(json.dumps({"status": "ok", "user_id": 99}).encode("utf-8"))

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = self.rfile.read(length).decode("utf-8")
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"created": True, "token": "session_tok_777", "body": body}).encode("utf-8"))

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

  -- Terminate background server
  pcall(function() srv_job:kill("sigterm") end)
end)
