-- Minimal test runner for nuntio.nvim
-- Add project root to package.path and rtp
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.opt.rtp:prepend(root)

local passed = 0
local failed = 0
local errors = {}

local function describe(suite_name, fn)
  print(string.format("\n=== %s ===", suite_name))
  fn()
end

local function it(test_name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print(string.format("  ✔ %s", test_name))
  else
    failed = failed + 1
    table.insert(errors, string.format("✘ %s: %s", test_name, tostring(err)))
    print(string.format("  ✘ %s", test_name))
  end
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%sexpected %s (%s), got %s (%s)",
      msg and (msg .. ": ") or "",
      vim.inspect(expected), type(expected),
      vim.inspect(actual), type(actual)), 2)
  end
end

local function assert_true(cond, msg)
  if not cond then
    error(msg or "expected condition to be true", 2)
  end
end

local function assert_nil(val, msg)
  if val ~= nil then
    error(msg or ("expected nil, got " .. vim.inspect(val)), 2)
  end
end

local function assert_not_nil(val, msg)
  if val == nil then
    error(msg or "expected non-nil value", 2)
  end
end

-- Export globals for test specs
_G.describe = describe
_G.it = it
_G.assert_eq = assert_eq
_G.assert_equal = assert_eq
_G.assert_true = assert_true
_G.assert_nil = assert_nil
_G.assert_not_nil = assert_not_nil

-- Load test suites
local test_files = {
  "tests/spec/document_spec.lua",
  "tests/spec/jsonpath_spec.lua",
  "tests/spec/vars_spec.lua",
  "tests/spec/env_spec.lua",
  "tests/spec/curl_spec.lua",
  "tests/spec/curl_import_spec.lua",
  "tests/spec/ui_spec.lua",
  "tests/spec/integration_spec.lua",
  "tests/spec/lsp_spec.lua",
}

for _, file in ipairs(test_files) do
  local full_path = root .. "/" .. file
  dofile(full_path)
end

print("\n==========================================")
print(string.format("Test Results: %d passed, %d failed", passed, failed))
if #errors > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print("  " .. e)
  end
  print("==========================================")
  vim.cmd("cquit 1")
else
  print("All tests passed successfully!")
  print("==========================================")
  vim.cmd("qall!")
end
