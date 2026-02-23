local M = {}

-- Per-buffer cache mapping line numbers to markdown cell membership.
-- Keyed by buffer number; each entry stores changedtick and a set of
-- markdown body line numbers for O(1) lookup by the treesitter predicate.
M._cache = {}

--- Rebuild the line→markdown-cell cache for a buffer.
--- Skips work if the buffer's changedtick hasn't changed.
---@param buf integer
function M.update_cache(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local entry = M._cache[buf]
  if entry and entry.tick == tick then return end

  local scanned = M.scan(buf)
  local md_lines = {}
  for _, cell in ipairs(scanned) do
    if cell.type == "markdown" then
      -- Body lines only (skip the marker line itself)
      for lnum = cell.start + 1, cell.stop do
        md_lines[lnum] = true
      end
    end
  end
  M._cache[buf] = { tick = tick, md_lines = md_lines }
end

--- Return true if `row` (0-indexed) is inside a markdown cell body.
---@param buf integer
---@param row integer  0-indexed line number
---@return boolean
function M.is_line_in_markdown_cell(buf, row)
  local entry = M._cache[buf]
  if not entry then return false end
  return entry.md_lines[row] == true
end

--- Clear the cache for a buffer (used on BufDelete).
---@param buf integer
function M.clear_cache(buf)
  M._cache[buf] = nil
end

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

--- Return true if the buffer looks like a jupytext Python file.
--- Matches either: # %% cell markers, or the # --- jupytext YAML header.
---@param buf integer
---@return boolean
function M.is_jupytext(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:match("^# %%%%") or line:match("^# In%[") then
      return true
    end
    -- jupytext YAML frontmatter header (# --- at top of file)
    if line:match("^# jupyter:") then
      return true
    end
  end
  return false
end

return M
