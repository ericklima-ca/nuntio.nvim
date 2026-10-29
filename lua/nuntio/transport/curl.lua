local Config = require("nuntio.config")
local Utils = require("nuntio.utils")

local M = {}

--- Active curl jobs (for cancellation)
---@type table<integer, vim.SystemObj>
M.active_jobs = {}
local job_counter = 0

---@class NuntioRawResponse
---@field status number
---@field status_text string
---@field raw_headers string
---@field headers table<string, string>
---@field cookies table<string, table>
---@field body string
---@field stats table
---@field verbose string
---@field duration_ms number
---@field temp_files string[]

--- Get path for cookie jar
---@param custom_path? string
---@return string
local function get_cookie_jar_path(custom_path)
  if custom_path and custom_path ~= "" then
    return custom_path
  end
  local data_dir = vim.fn.stdpath("data")
  return vim.fs.joinpath(data_dir, "nuntio_cookies.jar")
end
M.get_cookie_jar_path = get_cookie_jar_path

--- Parse Netscape cookie file into table
---@param cookie_file string
---@return table<string, table>
local function parse_cookie_file(cookie_file)
  local cookies = {}
  local content = Utils.read_file(cookie_file)
  if not content then return cookies end

  for _, line in ipairs(Utils.split_lines(content)) do
    line = Utils.trim(line)
    if line ~= "" and not line:match("^#%s") then
      local parts = Utils.split(line, "\t")
      if #parts >= 7 then
        local name = parts[6]
        cookies[name] = {
          domain = parts[1],
          include_subdomains = parts[2] == "TRUE",
          path = parts[3],
          secure = parts[4] == "TRUE",
          expires = parts[5],
          name = name,
          value = parts[7],
        }
      end
    end
  end
  return cookies
end
M.parse_cookie_file = parse_cookie_file

--- Parse HTTP raw headers into status, status_text, and headers map
--- Handles redirect chains by keeping the last header block
---@param raw_headers string
---@return number status, string status_text, table<string, string> headers
local function parse_raw_headers(raw_headers)
  local headers = {}
  local status = 0
  local status_text = ""

  if not raw_headers or raw_headers == "" then
    return status, status_text, headers
  end

  -- In redirect chains, curl appends multiple HTTP response header blocks separated by empty lines
  -- We take the last non-empty block
  local blocks = {}
  local current_block = {}

  for _, line in ipairs(Utils.split_lines(raw_headers)) do
    line = Utils.trim(line)
    if line == "" then
      if #current_block > 0 then
        table.insert(blocks, current_block)
        current_block = {}
      end
    else
      table.insert(current_block, line)
    end
  end
  if #current_block > 0 then
    table.insert(blocks, current_block)
  end

  local last_block = blocks[#blocks] or {}

  for i, line in ipairs(last_block) do
    if i == 1 and line:match("^HTTP/") then
      local code, text = line:match("^HTTP/[%d%.]+%s+(%d+)%s*(.*)$")
      if code then
        status = tonumber(code) or 0
        status_text = text or ""
      end
    else
      local k, v = line:match("^([%w_%-]+)%s*:%s*(.*)$")
      if k then
        headers[k:lower()] = v
        headers[k] = v
      end
    end
  end

  return status, status_text, headers
end

--- Build curl command line arguments
---@param request NuntioResolvedRequest
---@param headers_file string
---@param body_file? string
---@param resp_body_file? string
---@return string[] argv
function M.build_args(request, headers_file, body_file, resp_body_file)
  local cfg = Config.get()
  local args = { cfg.curl_path or "curl", "-s", "-S" }

  -- 1. Headers dump file
  table.insert(args, "-D")
  table.insert(args, headers_file)

  -- 2. Response body output file
  if resp_body_file then
    table.insert(args, "-o")
    table.insert(args, resp_body_file)
  end

  -- 3. Stats output in JSON format
  table.insert(args, "-w")
  table.insert(args, "%{json}")

  -- 4. Verbose trace to stderr
  table.insert(args, "-v")

  -- 5. HTTP Method
  table.insert(args, "-X")
  table.insert(args, request.method)

  -- 5. HTTP version if specified
  if request.http_version then
    if request.http_version == "HTTP/2" then
      table.insert(args, "--http2")
    elseif request.http_version == "HTTP/3" then
      table.insert(args, "--http3")
    elseif request.http_version == "HTTP/1.1" then
      table.insert(args, "--http1.1")
    end
  end

  -- 6. Headers
  local is_multipart = false
  local ct_key = nil
  for k, v in pairs(request.headers or {}) do
    if k:lower() == "content-type" and v:lower():match("multipart/form%-data") then
      is_multipart = true
      ct_key = k
      break
    end
  end

  local trimmed_body = Utils.trim(request.body or "")
  local is_raw_multipart = is_multipart and (trimmed_body:match("^%-%-") ~= nil or (ct_key and request.headers[ct_key]:match("boundary=")))
  local is_simplified_multipart = is_multipart and not is_raw_multipart and trimmed_body ~= ""

  for k, v in pairs(request.headers) do
    if not (is_simplified_multipart and k:lower() == "content-type") then
      table.insert(args, "-H")
      table.insert(args, string.format("%s: %s", k, v))
    end
  end

  -- 7. Cookies handling
  local use_cookies = true
  local cookie_jar = nil
  if request.metadata["no-cookie-jar"] then
    use_cookies = false
  end
  if request.metadata["cookie-jar"] and request.metadata["cookie-jar"][1] then
    cookie_jar = request.metadata["cookie-jar"][1]
  end

  if use_cookies then
    local jar_path = get_cookie_jar_path(cookie_jar)
    table.insert(args, "-b")
    table.insert(args, jar_path)
    table.insert(args, "-c")
    table.insert(args, jar_path)
  end

  -- 8. Custom curl flags from metadata: # @curl-<flag> [args...]
  for meta_k, meta_vals in pairs(request.metadata) do
    if meta_k:match("^curl%-") then
      local flag = meta_k:sub(6)
      local prefix = (#flag == 1) and "-" or "--"
      for _, val in ipairs(meta_vals) do
        table.insert(args, prefix .. flag)
        if val and val ~= "" then
          table.insert(args, val)
        end
      end
    end
  end

  -- 9. Additional curl arguments from user config
  if cfg.additional_curl_args and #cfg.additional_curl_args > 0 then
    for _, arg in ipairs(cfg.additional_curl_args) do
      table.insert(args, arg)
    end
  end

  -- 10. Body or Multipart Form fields
  if is_simplified_multipart then
    for _, line in ipairs(Utils.split_lines(request.body)) do
      line = Utils.trim(line)
      if line ~= "" and not line:match("^[#%/]") then
        local k, v = line:match("^([%w_%-%[%]%.]+)%s*[=:]%s*(.*)$")
        if k and v then
          v = Utils.trim(v)
          local file_path = nil
          local mime_type = nil
          if v:match("^<") then
            local raw_path = Utils.trim(v:sub(2))
            local p, t = raw_path:match("^(.-);%s*type=(.*)$")
            if p and t then
              raw_path = Utils.trim(p)
              mime_type = Utils.trim(t)
            end
            file_path = raw_path
          elseif v:match("^@") then
            local raw_path = Utils.trim(v:sub(2))
            local p, t = raw_path:match("^(.-);%s*type=(.*)$")
            if p and t then
              raw_path = Utils.trim(p)
              mime_type = Utils.trim(t)
            end
            file_path = raw_path
          end

          if file_path then
            if not vim.fs.normalize(file_path):match("^/") and request.buffer_dir then
              file_path = vim.fs.normalize(vim.fs.joinpath(request.buffer_dir, file_path))
            end
            local field_val = "@" .. file_path
            if mime_type then
              field_val = field_val .. ";type=" .. mime_type
            end
            table.insert(args, "-F")
            table.insert(args, k .. "=" .. field_val)
          else
            table.insert(args, "-F")
            table.insert(args, k .. "=" .. v)
          end
        end
      end
    end
  elseif body_file then
    table.insert(args, "--data-binary")
    table.insert(args, "@" .. body_file)
  end

  -- 11. Target URL
  table.insert(args, request.url)

  return args
end

--- Execute a resolved request asynchronously
---@param request NuntioResolvedRequest
---@param on_complete fun(res: NuntioRawResponse|nil, err: string|nil)
---@return integer job_id
function M.execute(request, on_complete)
  local cfg = Config.get()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")

  local headers_file = vim.fs.joinpath(temp_dir, "headers.txt")
  local resp_body_file = vim.fs.joinpath(temp_dir, "response.bin")
  local body_file = nil
  local temp_files = { headers_file, resp_body_file }

  local is_multipart = false
  for k, v in pairs(request.headers or {}) do
    if k:lower() == "content-type" and v:lower():match("multipart/form%-data") then
      is_multipart = true
      break
    end
  end
  local trimmed_body = Utils.trim(request.body or "")
  local is_raw_multipart = is_multipart and (trimmed_body:match("^%-%-") ~= nil or (request.headers["Content-Type"] and request.headers["Content-Type"]:match("boundary=")))
  local is_simplified_multipart = is_multipart and not is_raw_multipart and trimmed_body ~= ""

  if request.body and request.body ~= "" and not is_simplified_multipart then
    body_file = vim.fs.joinpath(temp_dir, "body.bin")
    Utils.write_file(body_file, request.body)
    table.insert(temp_files, body_file)
  end

  local args = M.build_args(request, headers_file, body_file, resp_body_file)

  local start_time = vim.uv.hrtime()
  job_counter = job_counter + 1
  local current_id = job_counter

  local job = vim.system(args, {
    text = false, -- Capture binary safely
    timeout = cfg.timeout or 60000,
  }, function(completed)
    M.active_jobs[current_id] = nil
    local duration_ms = (vim.uv.hrtime() - start_time) / 1e6

    vim.schedule(function()
      local raw_headers = Utils.read_file(headers_file) or ""
      local status, status_text, headers = parse_raw_headers(raw_headers)
      local cookies = parse_cookie_file(get_cookie_jar_path())

      local body = Utils.read_file(resp_body_file) or ""
      local raw_stdout = completed.stdout or ""
      local raw_stderr = completed.stderr or ""
      local verbose = raw_stderr

      local stats = {}
      if raw_stdout ~= "" then
        local ok, parsed = pcall(vim.json.decode, raw_stdout)
        if ok and type(parsed) == "table" then
          stats = parsed
          if status == 0 and parsed.http_code then
            status = tonumber(parsed.http_code) or 0
          end
        end
      end

      -- Clean up temp files
      for _, f in ipairs(temp_files) do
        pcall(vim.fn.delete, f)
      end
      pcall(vim.fn.delete, temp_dir, "rf")

      if completed.code ~= 0 and status == 0 then
        local err_msg = completed.stderr or string.format("curl exited with code %d", completed.code)
        on_complete(nil, err_msg)
        return
      end

      ---@type NuntioRawResponse
      local res = {
        status = status,
        status_text = status_text,
        raw_headers = raw_headers,
        headers = headers,
        cookies = cookies,
        body = body,
        stats = stats,
        verbose = verbose,
        duration_ms = duration_ms,
        temp_files = temp_files,
      }

      on_complete(res, nil)
    end)
  end)

  M.active_jobs[current_id] = job
  return current_id
end

--- Cancel all active jobs
function M.cancel_all()
  for id, job in pairs(M.active_jobs) do
    pcall(function() job:kill("sigterm") end)
    M.active_jobs[id] = nil
  end
end

return M
