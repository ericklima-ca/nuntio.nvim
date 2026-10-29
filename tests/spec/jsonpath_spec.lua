local JsonPath = require("nuntio.parser.jsonpath")

describe("JSONPath Parser", function()
  local data = {
    token = "secret-xyz",
    user = {
      id = 123,
      profile = {
        name = "Alice",
      },
      tags = { "admin", "dev" },
    },
    items = {
      { id = 1, title = "Item 1" },
      { id = 2, title = "Item 2" },
    },
  }

  it("extracts root properties with $. and without $.", function()
    assert_eq(JsonPath.extract(data, "$.token"), "secret-xyz")
    assert_eq(JsonPath.extract(data, "token"), "secret-xyz")
  end)

  it("extracts nested properties", function()
    assert_eq(JsonPath.extract(data, "$.user.profile.name"), "Alice")
    assert_eq(JsonPath.extract(data, "user.id"), 123)
  end)

  it("extracts array elements (0-based and 1-based fallback)", function()
    assert_eq(JsonPath.extract(data, "$.user.tags[0]"), "admin")
    assert_eq(JsonPath.extract(data, "$.user.tags[1]"), "dev")
    assert_eq(JsonPath.extract(data, "$.items[1].title"), "Item 2")
  end)

  it("parses JSON string inputs directly", function()
    local json_str = '{"data": {"auth": {"token": "jwt123"}}}'
    assert_eq(JsonPath.extract(json_str, "$.data.auth.token"), "jwt123")
  end)

  it("returns nil on nonexistent paths", function()
    assert_eq(JsonPath.extract(data, "$.user.nonexistent"), nil)
    assert_eq(JsonPath.extract(data, "$.items[99].title"), nil)
  end)
end)
