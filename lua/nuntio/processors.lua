local Assertions = require("nuntio.assertions")
local JsonPath = require("nuntio.parser.jsonpath")
local Store = require("nuntio.store")
local Utils = require("nuntio.utils")

local M = {}

--- Run post-request metadata processors
---@param request NuntioResolvedRequest
---@param response NuntioStoredResponse
---@return string body Modified body if @jq applied
function M.process(request, response)
  local final_body = response.body

  -- 0. # @assert <subject> [arg] <op> [value] (before @jq rewrites the body)
  if request.assertions and #request.assertions > 0 then
    response.assertions = Assertions.run(request.assertions, response)
  end

  -- 1. # @jq <filter>
  if request.metadata["jq"] and #request.metadata["jq"] > 0 then
    local filter = request.metadata["jq"][1]
    if filter and filter ~= "" and vim.fn.executable("jq") == 1 then
      local res = vim.fn.system({ "jq", filter }, response.body)
      if vim.v.shell_error == 0 and res and res ~= "" then
        final_body = Utils.trim(res)
        response.body = final_body
        local ok, j = pcall(vim.json.decode, final_body)
        if ok and type(j) == "table" then
          response.json = j
        end
      end
    end
  end

  -- 2. # @env-json-key <VAR> [=] <JSONPATH>
  if request.metadata["env-json-key"] then
    for _, item in ipairs(request.metadata["env-json-key"]) do
      local var_name, path = item:match("^([%w_%-]+)%s*=?%s*(.*)$")
      if var_name and path then
        path = Utils.trim(path)
        if path:sub(1, 1) == "=" then
          path = Utils.trim(path:sub(2))
        end
        local val = JsonPath.extract(response.json or response.body, path)
        if val ~= nil then
          local info = { req_name = request.name, path = path, type = "json", val = val }
          Store.set_global(var_name, val, info)
          response.exported_vars = response.exported_vars or {}
          response.exported_vars[var_name] = info
        end
      end
    end
  end

  -- 3. # @env-header-key <VAR> [=] <HEADER>
  if request.metadata["env-header-key"] then
    for _, item in ipairs(request.metadata["env-header-key"]) do
      local var_name, header_name = item:match("^([%w_%-]+)%s*=?%s*(.*)$")
      if var_name and header_name then
        header_name = Utils.trim(header_name)
        if header_name:sub(1, 1) == "=" then
          header_name = Utils.trim(header_name:sub(2))
        end
        for k, v in pairs(response.headers) do
          if k:lower() == header_name:lower() then
            local info = { req_name = request.name, path = header_name, type = "header", val = v }
            Store.set_global(var_name, v, info)
            response.exported_vars = response.exported_vars or {}
            response.exported_vars[var_name] = info
            break
          end
        end
      end
    end
  end

  -- 4. Response redirect: >> file or >>! file
  if request.redirect and request.redirect.file ~= "" then
    local dest = request.redirect.file
    if not vim.fs.normalize(dest):match("^/") then
      dest = vim.fs.joinpath(request.buffer_dir, dest)
    end
    if request.redirect.overwrite then
      Utils.write_file(dest, response.body)
    else
      local existing = Utils.read_file(dest) or ""
      Utils.write_file(dest, existing .. response.body)
    end
  end

  return final_body
end

return M
