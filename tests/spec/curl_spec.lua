local Curl = require("nuntio.transport.curl")

describe("Curl Argument Builder", function()
  it("builds basic curl arguments", function()
    local req = {
      method = "POST",
      url = "https://api.example.com/v1/users",
      headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer 123",
      },
      metadata = {},
    }

    local args = Curl.build_args(req, "/tmp/headers.txt", "/tmp/body.bin")
    assert_eq(args[1], "curl")
    assert_true(vim.tbl_contains(args, "-D"))
    assert_true(vim.tbl_contains(args, "/tmp/headers.txt"))
    assert_true(vim.tbl_contains(args, "-X"))
    assert_true(vim.tbl_contains(args, "POST"))
    assert_true(vim.tbl_contains(args, "-H"))
    assert_true(vim.tbl_contains(args, "Authorization: Bearer 123"))
    assert_true(vim.tbl_contains(args, "--data-binary"))
    assert_true(vim.tbl_contains(args, "@/tmp/body.bin"))
    assert_eq(args[#args], "https://api.example.com/v1/users")
  end)

  it("handles custom @curl-* flags and versions", function()
    local req = {
      method = "GET",
      url = "https://api.example.com",
      http_version = "HTTP/2",
      headers = {},
      metadata = {
        ["curl-location"] = { "" },
        ["curl-insecure"] = { "" },
        ["curl-connect-timeout"] = { "10" },
      },
    }

    local args = Curl.build_args(req, "/tmp/h.txt", nil)
    assert_true(vim.tbl_contains(args, "--http2"), "http2 flag")
    assert_true(vim.tbl_contains(args, "--location"), "location flag")
    assert_true(vim.tbl_contains(args, "--insecure"), "insecure flag")
    assert_true(vim.tbl_contains(args, "--connect-timeout"), "connect timeout flag")
    assert_true(vim.tbl_contains(args, "10"), "connect timeout val")
  end)

  it("handles @no-cookie-jar and parses Netscape cookie files", function()
    local Utils = require("nuntio.utils")
    -- 1. Without @no-cookie-jar: -b and -c should be present
    local req1 = {
      method = "GET",
      url = "https://api.example.com",
      headers = {},
      metadata = {},
    }
    local args1 = Curl.build_args(req1, "/tmp/h.txt", nil)
    assert_true(vim.tbl_contains(args1, "-b"))
    assert_true(vim.tbl_contains(args1, "-c"))

    -- 2. With @no-cookie-jar: -b and -c should not be present
    local req2 = {
      method = "GET",
      url = "https://api.example.com",
      headers = {},
      metadata = { ["no-cookie-jar"] = { "" } },
    }
    local args2 = Curl.build_args(req2, "/tmp/h.txt", nil)
    assert_true(not vim.tbl_contains(args2, "-b"))
    assert_true(not vim.tbl_contains(args2, "-c"))

    -- 3. Parse Netscape cookie format
    local tmp_cookie = vim.fn.tempname()
    local cookie_data = table.concat({
      "# Netscape HTTP Cookie File",
      ".example.com\tTRUE\t/\tTRUE\t1798761600\tsession_id\tabc_xyz_123",
      "example.com\tFALSE\t/api\tFALSE\t0\tpref\tdark_mode",
    }, "\n")
    Utils.write_file(tmp_cookie, cookie_data)

    local parsed = Curl.parse_cookie_file(tmp_cookie)
    assert_true(parsed["session_id"] ~= nil)
    assert_eq(parsed["session_id"].value, "abc_xyz_123")
    assert_eq(parsed["session_id"].domain, ".example.com")
    assert_eq(parsed["session_id"].secure, true)

    assert_true(parsed["pref"] ~= nil)
    assert_eq(parsed["pref"].value, "dark_mode")
    assert_eq(parsed["pref"].path, "/api")

    vim.fn.delete(tmp_cookie)
  end)

  it("handles simplified multipart form-data without manual boundaries", function()
    local req = {
      method = "POST",
      url = "https://httpbin.org/post",
      headers = { ["Content-Type"] = "multipart/form-data" },
      body = "title = My Upload\nfile = < ./test_file.json; type=application/json",
      buffer_dir = "/workspace/project",
      metadata = {},
    }

    local args = Curl.build_args(req, "/tmp/h.txt", nil)
    -- Should NOT pass bare -H "Content-Type: multipart/form-data" because curl must generate boundary
    local has_bare_ct = false
    for i, a in ipairs(args) do
      if a == "-H" and args[i + 1] and args[i + 1]:match("Content%-Type:%s*multipart/form%-data$") then
        has_bare_ct = true
      end
    end
    assert_true(not has_bare_ct, "omitted bare multipart content-type")

    -- Should pass -F title="My Upload"
    local has_title = false
    local has_file = false
    for i, a in ipairs(args) do
      if a == "-F" and args[i + 1] == "title=My Upload" then
        has_title = true
      end
      if a == "-F" and args[i + 1] == "file=@/workspace/project/test_file.json;type=application/json" then
        has_file = true
      end
    end
    assert_true(has_title, "parsed title field into -F")
    assert_true(has_file, "parsed file field into -F with path and type")
  end)
end)
