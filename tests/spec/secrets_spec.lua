local Store = require("nuntio.store")
local Utils = require("nuntio.utils")
local Vars = require("nuntio.parser.vars")

local function globals_on_disk()
  return Utils.read_file(vim.fs.joinpath(vim.fn.stdpath("data"), "nuntio_globals.json")) or ""
end

describe("Secrets: # @secret values stay off disk", function()
  it("keeps secrets in memory and out of the globals file", function()
    Store.set_secret("spec_api_pass", "s3cr3t-memory-only")
    assert_eq(Store.get_global("spec_api_pass"), "s3cr3t-memory-only")
    assert_nil(Store.globals["spec_api_pass"], "not a persisted global")
    assert_true(not globals_on_disk():find("s3cr3t-memory-only", 1, true), "value never written to disk")
    assert_eq(Vars.interpolate("pw={{spec_api_pass}}"), "pw=s3cr3t-memory-only", "still usable in requests")
    Store.clear_global("spec_api_pass")
    assert_nil(Store.get_global("spec_api_pass"))
  end)

  it("scrubs a value persisted by an earlier version", function()
    Store.set_global("spec_legacy_pass", "leaked-by-old-version")
    assert_true(globals_on_disk():find("leaked-by-old-version", 1, true) ~= nil, "precondition: on disk")

    Store.set_secret("spec_legacy_pass", "fresh-secret")
    local disk = globals_on_disk()
    assert_true(not disk:find("leaked-by-old-version", 1, true), "old copy removed from disk")
    assert_true(not disk:find("fresh-secret", 1, true), "new secret not written")
    assert_eq(Store.get_global("spec_legacy_pass"), "fresh-secret")
    Store.clear_global("spec_legacy_pass")
  end)

  it("lets a persisted value replace a secret of the same name, and clears both", function()
    Store.set_secret("spec_shared_name", "secret-value")
    Store.set_global("spec_shared_name", "public-value")
    assert_eq(Store.get_global("spec_shared_name"), "public-value", "no stale secret shadows the new value")
    Store.clear_global("spec_shared_name")

    Store.set_secret("spec_wipe", "x")
    local saved_globals = vim.deepcopy(Store.globals)
    Store.clear_all_globals()
    assert_nil(Store.get_global("spec_wipe"), "clear_all_globals drops secrets too")
    for k, v in pairs(saved_globals) do
      Store.set_global(k, v)
    end
  end)
end)
