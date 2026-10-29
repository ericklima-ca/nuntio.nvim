local Config = require("nuntio.config")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")

local M = {}

--- Parse a .env file content
---@param content string
---@return table<string, string>
local function parse_dotenv(content)
  local res = {}
  local lines = Utils.split_lines(content)
  for _, line in ipairs(lines) do
    line = Utils.trim(line)
    if line ~= "" and not line:match("^#") then
      local k, v = line:match("^%s*([%w_%-%.]+)%s*=%s*(.*)$")
      if k and v then
        -- Strip quotes if wrapped
        if (v:sub(1, 1) == '"' and v:sub(-1) == '"') or
           (v:sub(1, 1) == "'" and v:sub(-1) == "'") then
          v = v:sub(2, -2)
        end
        res[k] = v
      end
    end
  end
  return res
end

--- Find all parent directories from start_dir up to root
---@param start_dir string
---@return string[]
local function get_parent_dirs(start_dir)
  local dirs = {}
  local curr = vim.fs.normalize(start_dir)
  while curr and curr ~= "" do
    table.insert(dirs, curr)
    local parent = vim.fs.dirname(curr)
    if not parent or parent == curr then break end
    curr = parent
  end
  return dirs
end

--- Discover and list available environment names in the directory tree
---@param start_dir? string
---@return string[]
function M.list_available_envs(start_dir)
  local dir = start_dir or vim.fn.expand("%:p:h")
  if not dir or dir == "" then dir = vim.uv.cwd() end
  local dirs = get_parent_dirs(dir)

  local env_set = {}
  for _, d in ipairs(dirs) do
    for _, fname in ipairs({ "http-client.env.json", "http-client.private.env.json", "http-client.env.private.json" }) do
      local file = vim.fs.joinpath(d, fname)
      if vim.uv.fs_stat(file) then
        local raw = Utils.read_file(file)
        if raw then
          local data = Utils.json_decode(raw)
          if type(data) == "table" then
            for k, _ in pairs(data) do
              if not k:match("^%$") then
                env_set[k] = true
              end
            end
          end
        end
      end
    end

    -- Discover .env.<env> files (e.g. .env.dev, .env.staging, .env.prod)
    local handle = vim.uv.fs_scandir(d)
    if handle then
      while true do
        local name, ftype = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if ftype == "file" or ftype == "link" then
          local env_suffix = name:match("^%.env%.([%w_%-]+)$")
          if env_suffix and env_suffix ~= "local" and env_suffix ~= "example" then
            env_set[env_suffix] = true
          end
        end
      end
    end
  end

  local list = vim.tbl_keys(env_set)
  table.sort(list)
  if #list == 0 then
    table.insert(list, Config.get().default_env or "dev")
  end
  return list
end

--- Get current active environment name
---@param bufnr? integer
---@return string
function M.get_current_env(bufnr)
  local cfg = Config.get()
  local scope = cfg.environment_scope or "b"
  if scope == "b" and bufnr and bufnr > 0 then
    if Store.selected_env[bufnr] then
      return Store.selected_env[bufnr]
    end
  end
  return Store.selected_env["__global__"] or cfg.default_env or "dev"
end

--- Set current active environment
---@param env string
---@param bufnr? integer
function M.set_env(env, bufnr)
  local cfg = Config.get()
  local scope = cfg.environment_scope or "b"
  if scope == "b" and bufnr and bufnr > 0 then
    Store.selected_env[bufnr] = env
  else
    Store.selected_env["__global__"] = env
  end
end

--- Resolve merged environment variables for the current context
--- Hierarchy (lowest to highest priority):
--- 1. OS environment variables
--- 2. .env files
--- 3. http-client.env.json ($shared / $kulalaShared then active env)
--- 4. http-client.private.env.json ($shared / $kulalaShared then active env)
--- Closer files in the directory tree override farther ones.
---@param start_dir? string
---@param bufnr? integer
---@return table<string, any> env_vars
---@return table<string, string> default_headers
function M.resolve(start_dir, bufnr)
  local dir = start_dir or vim.fn.expand("%:p:h")
  if not dir or dir == "" then dir = vim.uv.cwd() end
  dir = vim.fs.normalize(dir)

  local current_env = M.get_current_env(bufnr)
  local env_vars = {}
  local default_headers = {}

  -- 1. OS environment variables
  local os_env = vim.fn.environ()
  for k, v in pairs(os_env) do
    env_vars[k] = v
  end

  -- Search parent directories from root DOWN to current dir so closer files win
  local parent_dirs = get_parent_dirs(dir)
  -- Reverse so furthest root is processed first
  local dirs = {}
  for i = #parent_dirs, 1, -1 do
    table.insert(dirs, parent_dirs[i])
  end

  -- 2. .env files: .env -> .env.<current_env> -> .env.local -> .env.<current_env>.local -> .env.private
  for _, d in ipairs(dirs) do
    local files_to_check = {
      vim.fs.joinpath(d, ".env"),
      vim.fs.joinpath(d, ".env." .. current_env),
      vim.fs.joinpath(d, ".env.local"),
      vim.fs.joinpath(d, ".env." .. current_env .. ".local"),
      vim.fs.joinpath(d, ".env.private"),
    }
    for _, dotenv_path in ipairs(files_to_check) do
      if vim.uv.fs_stat(dotenv_path) then
        local raw = Utils.read_file(dotenv_path)
        if raw then
          local parsed = parse_dotenv(raw)
          for k, v in pairs(parsed) do
            env_vars[k] = v
          end
        end
      end
    end
  end

  -- 3 & 4. http-client.env.json & http-client.private.env.json
  for _, d in ipairs(dirs) do
    for _, fname in ipairs({ "http-client.env.json", "http-client.private.env.json", "http-client.env.private.json" }) do
      local file = vim.fs.joinpath(d, fname)
      if vim.uv.fs_stat(file) then
        local raw = Utils.read_file(file)
        if raw then
          local data = Utils.json_decode(raw)
          if type(data) == "table" then
            -- Check shared section
            local shared = data["$shared"] or data["$kulalaShared"]
            if type(shared) == "table" then
              for k, v in pairs(shared) do
                if k == "$default_headers" or k == "$kulalaDefaultHeaders" then
                  if type(v) == "table" then
                    for hk, hv in pairs(v) do
                      default_headers[hk] = tostring(hv)
                    end
                  end
                elseif not k:match("^%$") then
                  env_vars[k] = v
                end
              end
            end

            -- Check active environment section
            local env_data = data[current_env]
            if type(env_data) == "table" then
              for k, v in pairs(env_data) do
                if k == "$default_headers" or k == "$kulalaDefaultHeaders" then
                  if type(v) == "table" then
                    for hk, hv in pairs(v) do
                      default_headers[hk] = tostring(hv)
                    end
                  end
                elseif not k:match("^%$") then
                  env_vars[k] = v
                end
              end
            end
          end
        end
      end
    end
  end

  return env_vars, default_headers
end

return M
