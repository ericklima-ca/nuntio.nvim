local Document = require("nuntio.parser.document")
local Utils = require("nuntio.utils")

describe("Document Parser", function()
  it("parses a simple GET request", function()
    local text = [[
GET https://api.example.com/users
Accept: application/json
]]
    local blocks, doc_vars = Document.parse_document(Utils.split_lines(text))
    assert_eq(#blocks, 1, "block count")
    assert_eq(blocks[1].method, "GET", "method")
    assert_eq(blocks[1].url, "https://api.example.com/users", "url")
    assert_eq(blocks[1].headers["accept"], "application/json", "headers")
  end)

  it("defaults method to GET if omitted", function()
    local text = [[
https://api.example.com/users
User-Agent: test
]]
    local blocks, _ = Document.parse_document(Utils.split_lines(text))
    assert_eq(#blocks, 1)
    assert_eq(blocks[1].method, "GET")
    assert_eq(blocks[1].url, "https://api.example.com/users")
  end)

  it("parses multiple blocks with ### separators and names", function()
    local text = [[
@baseUrl = https://api.example.com

### First Request
GET {{baseUrl}}/one
Header-One: 1

### Second Request
POST {{baseUrl}}/two
Content-Type: application/json

{
  "hello": "world"
}
]]
    local blocks, doc_vars = Document.parse_document(Utils.split_lines(text))
    assert_eq(#blocks, 2)
    assert_eq(blocks[1].name, "First Request")
    assert_eq(blocks[1].method, "GET")
    assert_eq(blocks[2].name, "Second Request")
    assert_eq(blocks[2].method, "POST")
    assert_true(blocks[2].body:find('"hello": "world"') ~= nil, "body contains payload")
    assert_eq(doc_vars["baseUrl"], "https://api.example.com")
  end)

  it("parses all HTTP methods: PUT, PATCH, DELETE, HEAD, OPTIONS", function()
    local text = [[
### Put Request
PUT https://api.com/items/1
Content-Type: application/json

{"updated": true}

### Patch Request
PATCH https://api.com/items/1

### Delete Request
DELETE https://api.com/items/1?force=true

### Head Request
HEAD https://api.com/items/1

### Options Request
OPTIONS https://api.com/items/1
]]
    local blocks = Document.parse_document(Utils.split_lines(text))
    assert_eq(#blocks, 5)
    assert_eq(blocks[1].method, "PUT")
    assert_eq(blocks[2].method, "PATCH")
    assert_eq(blocks[3].method, "DELETE")
    assert_eq(blocks[4].method, "HEAD")
    assert_eq(blocks[5].method, "OPTIONS")
  end)

  it("handles # @name, # @curl-*, and # @jq metadata", function()
    local text = [[
# @name create_item
# @curl-location
# @curl-connect-timeout 5
# @jq .items[0]
POST https://api.example.com/items
Content-Type: application/json

{"name": "test"}
]]
    local blocks, _ = Document.parse_document(Utils.split_lines(text))
    assert_eq(#blocks, 1)
    assert_eq(blocks[1].name, "create_item")
    assert_true(blocks[1].metadata["curl-location"] ~= nil, "curl-location present")
    assert_eq(blocks[1].metadata["curl-connect-timeout"][1], "5", "timeout val")
    assert_eq(blocks[1].metadata["jq"][1], ".items[0]", "jq val")
  end)

  it("merges multiple Cookie headers", function()
    local text = [[
GET https://api.example.com
Cookie: a=1
Cookie: b=2
]]
    local blocks, _ = Document.parse_document(Utils.split_lines(text))
    assert_eq(blocks[1].headers["cookie"], "a=1; b=2")
  end)

  it("parses body file inclusion and response redirect", function()
    local text = [[
POST https://api.example.com
Content-Type: text/plain

< ./payload.json
>>! ./out.txt
]]
    local blocks, _ = Document.parse_document(Utils.split_lines(text))
    assert_true(blocks[1] ~= nil)
    assert_eq(blocks[1].body_file, "./payload.json")
    assert_true(blocks[1].redirect ~= nil)
    assert_eq(blocks[1].redirect.file, "./out.txt")
    assert_eq(blocks[1].redirect.overwrite, true)
  end)

  it("resolves external body files and multipart file embeds via Request.resolve", function()
    local Request = require("nuntio.request")
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")

    local json_file = vim.fs.joinpath(tmp_dir, "sample.json")
    Utils.write_file(json_file, '{\n  "greeting": "hello {{name}}"\n}')

    -- Test 1: Direct body file < ./sample.json
    local block1 = {
      method = "POST",
      url = "https://example.com/test",
      headers = {},
      headers_list = {},
      body = "",
      body_file = "./sample.json",
      start_line = 1,
      end_line = 5,
      icon_line = 1,
    }
    local res1 = Request.resolve(block1, { name = "Alice" }, tmp_dir)
    assert_true(res1.body:find('"greeting": "hello Alice"') ~= nil)
    assert_eq(res1.headers["Content-Type"], "application/json")

    -- Test 2: Multipart body with embedded < ./sample.json
    local block2 = {
      method = "POST",
      url = "https://example.com/multipart",
      headers = { ["Content-Type"] = "multipart/form-data; boundary=Boundary123" },
      headers_list = {},
      body = "--Boundary123\nContent-Disposition: form-data; name=\"file\"\n\n< ./sample.json\n--Boundary123--",
      start_line = 1,
      end_line = 8,
      icon_line = 1,
    }
    local res2 = Request.resolve(block2, { name = "Bob" }, tmp_dir)
    assert_true(res2.body:find('"greeting": "hello Bob"') ~= nil)
    assert_true(res2.body:find("--Boundary123") ~= nil)

    vim.fn.delete(tmp_dir, "rf")
  end)

  it("identifies ### Shared blocks", function()
    local text = [[
### Shared
@commonHeader = test

### My Request
GET https://api.com
]]
    local blocks, _ = Document.parse_document(Utils.split_lines(text))
    assert_eq(#blocks, 2)
    assert_eq(blocks[1].is_shared, true)
    assert_eq(blocks[2].is_shared, false)
  end)
end)
