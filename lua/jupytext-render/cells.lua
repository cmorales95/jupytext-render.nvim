local M = {}

--- Scan a buffer for jupytext-style `# %%` cell markers.
--- Returns a list of cell ranges ordered by appearance.
---@param buf integer
---@return {start: integer, stop: integer, type: "markdown"|"code"}[]
function M.scan(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cells = {}
  local current = nil

  for i, line in ipairs(lines) do
    local lnum = i - 1 -- 0-indexed
    -- Match: # %% or # %% [markdown] or # In[N]: etc.
    if line:match("^# %%%%") or line:match("^# In%[") then
      -- Close previous cell
      if current then
        current.stop = lnum - 1
        table.insert(cells, current)
      end
      local cell_type = "code"
      if line:match("%[markdown%]") or line:match("%[md%]") then
        cell_type = "markdown"
      end
      current = { start = lnum, stop = lnum, type = cell_type }
    end
  end

  -- Close last cell
  if current then
    current.stop = #lines - 1
    table.insert(cells, current)
  end

  return cells
end

--- Return true if the buffer contains at least one jupytext cell marker.
---@param buf integer
---@return boolean
function M.is_jupytext(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:match("^# %%%%") or line:match("^# In%[") then
      return true
    end
  end
  return false
end

return M
