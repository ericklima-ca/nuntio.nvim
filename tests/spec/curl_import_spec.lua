local CurlImport = require("nuntio.parser.curl_import")

describe("Curl Import / Export", function()
  it("parses curl command into .http format", function()
    local curl_cmd = [[curl -X POST https://api.example.com/login -H "Content-Type: application/json" -d '{"user":"admin"}' -b "token=abc"]]
    local http_str = CurlImport.to_http(curl_cmd)

    assert_true(http_str:find("POST https://api.example.com/login") ~= nil, "request line")
    assert_true(http_str:find("Content%-Type: application/json") ~= nil, "header")
    assert_true(http_str:find("Cookie: token=abc") ~= nil, "cookie")
    assert_true(http_str:find('{"user":"admin"}') ~= nil, "body")
  end)

  it("converts resolved request into executable curl string", function()
    local req = {
      method = "POST",
      url = "https://api.example.com/data",
      headers = { ["Content-Type"] = "application/json" },
      body = '{"foo":"bar"}',
    }

    local curl_str = CurlImport.to_curl_string(req)
    assert_true(curl_str:find("curl %-i %-X POST") ~= nil)
    assert_true(curl_str:find("https://api.example.com/data") ~= nil)
    assert_true(curl_str:find("application/json") ~= nil)
    assert_true(curl_str:find('{"foo":"bar"}') ~= nil)
  end)
end)
