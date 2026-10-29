local Env = require("nuntio.env")
local Utils = require("nuntio.utils")

describe("Environment Resolver", function()
  local test_dir = vim.fn.tempname()
  vim.fn.mkdir(test_dir, "p")

  -- Create .env
  local dotenv_content = "API_KEY=key_dotenv\nPORT=3000\n# comment\n"
  Utils.write_file(vim.fs.joinpath(test_dir, ".env"), dotenv_content)

  -- Create http-client.env.json
  local env_json_content = [[
{
  "$shared": {
    "BASE_URL": "https://api.example.com",
    "$default_headers": {
      "X-Custom-Shared": "shared_header"
    }
  },
  "dev": {
    "ENV_NAME": "development",
    "API_KEY": "key_dev_json"
  },
  "prod": {
    "ENV_NAME": "production"
  }
}
]]
  Utils.write_file(vim.fs.joinpath(test_dir, "http-client.env.json"), env_json_content)

  -- Create http-client.private.env.json (overrides dev API_KEY)
  local priv_json_content = [[
{
  "dev": {
    "API_KEY": "secret_private_key"
  }
}
]]
  Utils.write_file(vim.fs.joinpath(test_dir, "http-client.private.env.json"), priv_json_content)

  -- Create .env.staging and .env.local
  Utils.write_file(vim.fs.joinpath(test_dir, ".env.staging"), "STAGING_VAR=stage_123\n")
  Utils.write_file(vim.fs.joinpath(test_dir, ".env.local"), "LOCAL_OVERRIDE=local_val\n")

  it("lists available environments including .env.<env>", function()
    local envs = Env.list_available_envs(test_dir)
    assert_true(vim.tbl_contains(envs, "dev"), "contains dev")
    assert_true(vim.tbl_contains(envs, "prod"), "contains prod")
    assert_true(vim.tbl_contains(envs, "staging"), "contains staging from .env.staging")
  end)

  it("resolves hierarchy: private > env.json > .env.<env> > .env", function()
    Env.set_env("staging", 2)
    local vars, _ = Env.resolve(test_dir, 2)

    assert_eq(vars["STAGING_VAR"], "stage_123") -- from .env.staging
    assert_eq(vars["LOCAL_OVERRIDE"], "local_val") -- from .env.local
    assert_eq(vars["PORT"], "3000") -- from .env
  end)

  it("resolves hierarchy: private > env.json > .env", function()
    Env.set_env("dev", 1)
    local vars, headers = Env.resolve(test_dir, 1)

    assert_eq(vars["BASE_URL"], "https://api.example.com")
    assert_eq(vars["ENV_NAME"], "development")
    assert_eq(vars["PORT"], "3000") -- from .env
    assert_eq(vars["API_KEY"], "secret_private_key") -- private overrides env.json & .env
    assert_eq(headers["X-Custom-Shared"], "shared_header")
  end)

  it("supports alternative private env files (.env.local, .env.<env>.local, .env.private)", function()
    local alt_dir = vim.fn.tempname()
    vim.fn.mkdir(alt_dir, "p")
    Utils.write_file(vim.fs.joinpath(alt_dir, ".env"), "VAL=base\n")
    Utils.write_file(vim.fs.joinpath(alt_dir, ".env.dev.local"), "DEV_LOCAL=dev_secret\n")
    Utils.write_file(vim.fs.joinpath(alt_dir, ".env.private"), "PRIVATE_VAL=private_secret\n")

    Env.set_env("dev", 10)
    local vars, _ = Env.resolve(alt_dir, 10)
    assert_eq(vars["VAL"], "base")
    assert_eq(vars["DEV_LOCAL"], "dev_secret")
    assert_eq(vars["PRIVATE_VAL"], "private_secret")

    pcall(vim.fn.delete, alt_dir, "rf")
  end)

  -- Clean up
  pcall(vim.fn.delete, test_dir, "rf")
end)
