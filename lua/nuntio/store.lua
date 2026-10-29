local Utils = require("nuntio.utils")

local M = {}

---@class NuntioStoredResponse
---@field id string Unique ID
---@field name? string Request name if named
---@field method string HTTP method
---@field url string Final requested URL
---@field status number HTTP status code
---@field status_text? string Status text (e.g. OK)
---@field headers table<string, string> Case-insensitive headers table
---@field raw_headers string Raw headers string
---@field cookies table<string, table> Parsed cookies
---@field body string Response body text
---@field raw_body string Raw body
---@field json? any Decoded JSON if body is valid JSON
---@field time number Total time in ms
---@field stats? table Timing statistics
---@field verbose? string Curl verbose output
---@field timestamp number Unix timestamp

--- In-memory store
---@type NuntioStoredResponse[]
M.history = {}

--- Map of request name -> last response
---@type table<string, NuntioStoredResponse>
M.by_name = {}

--- Map of request name -> last sent request details
---@type table<string, table>
M.sent_requests = {}

--- Script global variables
---@type table<string, any>
M.globals = {}

--- Map of variable name -> producer info { req_name?: string, path?: string, type?: string }
---@type table<string, table>
M.var_producers = {}

--- Selected environment by buffer number or "__global__"
---@type table<string|number, string>
M.selected_env = {}

--- Last executed request context for replay
---@type table|nil
M.last_request = nil

local function get_globals_file()
  local data_dir = vim.fn.stdpath("data")
  return vim.fs.joinpath(data_dir, "nuntio_globals.json")
end

--- Load persisted globals from disk
function M.load_globals()
  local file = get_globals_file()
  local content = Utils.read_file(file)
  if content then
    local data = Utils.json_decode(content)
    if type(data) == "table" then
      M.globals = data
    end
  end
end

--- Save globals to disk
function M.save_globals()
  local file = get_globals_file()
  Utils.write_file(file, Utils.json_encode(M.globals, true))
end

--- Record a response in history and by name
---@param response NuntioStoredResponse
---@param request_details? table
function M.add_response(response, request_details)
  table.insert(M.history, response)
  -- Cap history at 50
  if #M.history > 50 then
    table.remove(M.history, 1)
  end

  if response.name and response.name ~= "" then
    M.by_name[response.name] = response
    if request_details then
      M.sent_requests[response.name] = request_details
    end
  end
end

--- Get last response
---@return NuntioStoredResponse|nil
function M.get_last_response()
  return M.history[#M.history]
end

--- Get response by name
---@param name string
---@return NuntioStoredResponse|nil
function M.get_by_name(name)
  return M.by_name[name]
end

--- Get sent request details by name
---@param name string
---@return table|nil
function M.get_request_by_name(name)
  return M.sent_requests[name]
end

--- Clear response history
function M.clear_history()
  M.history = {}
  M.by_name = {}
  M.sent_requests = {}
end

--- Global variable getter
---@param key string
---@return any
function M.get_global(key)
  return M.globals[key]
end

--- Global variable setter
---@param key string
---@param value any
---@param producer_info? table
function M.set_global(key, value, producer_info)
  M.globals[key] = value
  if producer_info then
    M.var_producers[key] = producer_info
  end
  M.save_globals()
end

--- Get producer info for a variable
---@param key string
---@return table|nil
function M.get_var_producer(key)
  return M.var_producers[key]
end

--- Clear a specific global variable
---@param key string
function M.clear_global(key)
  M.globals[key] = nil
  M.save_globals()
end

--- Clear all global variables
function M.clear_all_globals()
  M.globals = {}
  M.save_globals()
end

-- Initialize globals on module load
M.load_globals()

return M
