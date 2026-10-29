local JsonPath = require("nuntio.parser.jsonpath")

local M = {}

---@class NuntioAssertion
---@field raw string Original expression
---@field subject "status"|"header"|"body"|"duration"
---@field arg? string Header name or JSONPath
---@field op string
---@field expected any
---@field expected_raw? string

---@class NuntioAssertionResult
---@field expr string
---@field ok boolean
---@field actual? string Display form of the actual value
---@field expected? string Display form of the expected value
---@field message? string Failure reason or parse error

---@class NuntioAssertionSummary
---@field total integer
---@field passed integer
---@field failed integer
---@field results NuntioAssertionResult[]

--- Sentinel for a JSON `null` literal in expected values
M.NULL = setmetatable({}, { __tostring = function() return "null" end })

M.subjects = { "status", "header", "body", "duration" }

M.operators = { "==", "!=", ">=", "<=", ">", "<", "contains", "!contains", "matches", "exists", "!exists" }

local operator_set = {}
for _, op in ipairs(M.operators) do
  operator_set[op] = true
end

local unary_ops = { ["exists"] = true, ["!exists"] = true }

--- Split the next whitespace-delimited token, honoring single/double quotes
---@param s string
---@param pos integer
---@return string|nil token, integer next_pos
local function next_token(s, pos)
  pos = s:find("%S", pos)
  if not pos then return nil, #s + 1 end
  local ch = s:sub(pos, pos)
  if ch == '"' or ch == "'" then
    local close = s:find(ch, pos + 1, true)
    if close then
      return s:sub(pos, close), close + 1
    end
  end
  local stop = s:find("%s", pos) or (#s + 1)
  return s:sub(pos, stop - 1), stop
end

--- Convert a literal from an assertion into a typed Lua value
---@param raw string
---@return any
local function parse_literal(raw)
  local first, last = raw:sub(1, 1), raw:sub(-1)
  if #raw >= 2 and (first == '"' or first == "'") and first == last then
    return raw:sub(2, -2)
  end
  if raw == "true" then return true end
  if raw == "false" then return false end
  if raw == "null" then return M.NULL end
  local num = tonumber(raw)
  if num ~= nil then return num end
  return raw
end

--- Parse an assertion expression, e.g. `body $.id == 42`
---@param expr string
---@return NuntioAssertion|nil assertion, string|nil err
function M.parse(expr)
  expr = vim.trim(expr or "")
  if expr == "" then
    return nil, "empty assertion"
  end

  local subject, pos = next_token(expr, 1)
  subject = subject:lower()

  local arg
  if subject == "status" or subject == "duration" then
    -- no argument
  elseif subject == "header" then
    arg, pos = next_token(expr, pos)
    if not arg or operator_set[arg] then
      return nil, "missing header name (e.g. `header Content-Type contains json`)"
    end
  elseif subject == "body" then
    local tok, tok_end = next_token(expr, pos)
    if tok and not operator_set[tok] then
      arg, pos = tok, tok_end
    end
  else
    return nil, string.format("unknown subject '%s' (expected status, header, body or duration)", subject)
  end

  local op
  op, pos = next_token(expr, pos)
  if not op then
    return nil, "missing operator (" .. table.concat(M.operators, ", ") .. ")"
  end
  if not operator_set[op] then
    return nil, string.format("unknown operator '%s' (expected %s)", op, table.concat(M.operators, ", "))
  end

  local rest = vim.trim(expr:sub(pos))
  local assertion = { raw = expr, subject = subject, arg = arg, op = op }

  if unary_ops[op] then
    if rest ~= "" then
      return nil, string.format("operator '%s' takes no value", op)
    end
    return assertion
  end

  if rest == "" then
    return nil, string.format("missing expected value after '%s'", op)
  end

  assertion.expected_raw = rest
  if op == "contains" or op == "!contains" or op == "matches" then
    -- Substring/pattern operators always compare text
    local v = parse_literal(rest)
    assertion.expected = (type(v) == "string") and v or rest
  else
    assertion.expected = parse_literal(rest)
  end

  if op == "matches" and not pcall(string.find, "", assertion.expected) then
    return nil, string.format("invalid Lua pattern '%s'", assertion.expected)
  end

  return assertion
end

--- Render any value for display in results
---@param v any
---@return string
local function display(v)
  if v == nil then return "<missing>" end
  if v == vim.NIL or v == M.NULL then return "null" end
  if type(v) == "table" then
    local ok, encoded = pcall(vim.json.encode, v)
    return ok and encoded or vim.inspect(v)
  end
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

--- Plain text form of a value for string comparisons
---@param v any
---@return string|nil
local function as_text(v)
  if v == nil then return nil end
  if v == vim.NIL then return "null" end
  if type(v) == "table" then
    local ok, encoded = pcall(vim.json.encode, v)
    return ok and encoded or nil
  end
  return tostring(v)
end

--- Loose equality between an actual response value and a typed expected literal
---@param actual any
---@param expected any
---@return boolean
local function equals(actual, expected)
  if expected == M.NULL then
    return actual == vim.NIL
  end
  if actual == nil then
    return false
  end
  if type(expected) == "boolean" then
    return actual == expected
  end
  if type(expected) == "number" then
    return tonumber(actual) == expected
  end
  return as_text(actual) == expected
end

--- Resolve the actual value an assertion refers to
---@param a NuntioAssertion
---@param response NuntioStoredResponse
---@return any
local function resolve_actual(a, response)
  if a.subject == "status" then
    return response.status
  elseif a.subject == "duration" then
    return response.time
  elseif a.subject == "header" then
    local want = a.arg:lower()
    for k, v in pairs(response.headers or {}) do
      if k:lower() == want then
        return v
      end
    end
    return nil
  end

  -- body
  local raw_body = response.raw_body or response.body or ""
  if not a.arg then
    return raw_body
  end
  local source = response.json
  if source == nil then
    source = raw_body
  end
  return JsonPath.extract(source, a.arg)
end

--- Evaluate a parsed assertion against a response
---@param a NuntioAssertion
---@param response NuntioStoredResponse
---@return boolean ok, any actual, string|nil message
function M.evaluate(a, response)
  local actual = resolve_actual(a, response)
  local op = a.op

  if op == "exists" then
    return actual ~= nil, actual, actual == nil and "value does not exist" or nil
  elseif op == "!exists" then
    return actual == nil, actual, actual ~= nil and "value exists" or nil
  end

  if actual == nil then
    return false, actual, "value does not exist"
  end

  if op == "==" then
    return equals(actual, a.expected), actual
  elseif op == "!=" then
    return not equals(actual, a.expected), actual
  elseif op == ">" or op == "<" or op == ">=" or op == "<=" then
    local x, y = tonumber(actual), tonumber(a.expected)
    if x == nil or y == nil then
      return false, actual, "operands are not numeric"
    end
    if op == ">" then return x > y, actual end
    if op == "<" then return x < y, actual end
    if op == ">=" then return x >= y, actual end
    return x <= y, actual
  elseif op == "contains" or op == "!contains" then
    local found
    if type(actual) == "table" and vim.islist(actual) then
      found = false
      for _, item in ipairs(actual) do
        if equals(item, parse_literal(a.expected_raw)) then
          found = true
          break
        end
      end
    else
      found = (as_text(actual) or ""):find(a.expected, 1, true) ~= nil
    end
    if op == "contains" then return found, actual end
    return not found, actual
  elseif op == "matches" then
    local ok, res = pcall(string.find, as_text(actual) or "", a.expected)
    if not ok then
      return false, actual, "invalid Lua pattern: " .. tostring(res)
    end
    return res ~= nil, actual
  end

  return false, actual, "unsupported operator " .. op
end

--- Parse and evaluate a list of assertion expressions
---@param exprs string[]
---@param response NuntioStoredResponse
---@return NuntioAssertionSummary
function M.run(exprs, response)
  local summary = { total = 0, passed = 0, failed = 0, results = {} }

  for _, expr in ipairs(exprs or {}) do
    local result
    local a, err = M.parse(expr)
    if not a then
      result = { expr = vim.trim(expr or ""), ok = false, message = "syntax error: " .. err }
    else
      local ok, actual, message = M.evaluate(a, response)
      result = {
        expr = a.raw,
        ok = ok,
        actual = display(actual),
        expected = a.expected ~= nil and display(a.expected) or nil,
        message = message,
      }
    end

    summary.total = summary.total + 1
    if result.ok then
      summary.passed = summary.passed + 1
    else
      summary.failed = summary.failed + 1
    end
    table.insert(summary.results, result)
  end

  return summary
end

return M
