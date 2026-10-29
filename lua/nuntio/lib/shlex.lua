local M = {}

--- Split command line string into arguments respecting quotes and backslashes
---@param s string
---@return string[]
function M.split(s)
  local words = {}
  local in_quote = nil
  local current_word = {}
  local escaped = false

  -- Normalize multiline backslash continuations
  s = s:gsub("\\\r?\n", " ")

  for i = 1, #s do
    local c = s:sub(i, i)

    if escaped then
      table.insert(current_word, c)
      escaped = false
    elseif c == "\\" and in_quote ~= "'" then
      escaped = true
    elseif in_quote then
      if c == in_quote then
        in_quote = nil
      else
        table.insert(current_word, c)
      end
    else
      if c == '"' or c == "'" then
        in_quote = c
      elseif c:match("%s") then
        if #current_word > 0 then
          table.insert(words, table.concat(current_word, ""))
          current_word = {}
        end
      else
        table.insert(current_word, c)
      end
    end
  end

  if #current_word > 0 then
    table.insert(words, table.concat(current_word, ""))
  end

  return words
end

return M
