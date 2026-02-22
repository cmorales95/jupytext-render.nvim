local M = {}

local cells = require("jupytext-render.cells")

--- Return the 0-indexed line the cursor is on in the window showing `buf`.
local function cursor_lnum(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then win = 0 end
  return vim.api.nvim_win_get_cursor(win)[1] - 1
end

--- Jump to the start of the next cell (any type).
---@param buf? integer
function M.goto_next(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cur = cursor_lnum(buf)
  for _, cell in ipairs(cells.scan(buf)) do
    if cell.start > cur then
      vim.api.nvim_win_set_cursor(0, { cell.start + 1, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
  vim.notify("jupytext-render: no next cell", vim.log.levels.INFO)
end

--- Jump to the start of the previous cell (any type).
---@param buf? integer
function M.goto_prev(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cur = cursor_lnum(buf)
  local prev = nil
  for _, cell in ipairs(cells.scan(buf)) do
    if cell.start >= cur then break end
    prev = cell
  end
  if prev then
    vim.api.nvim_win_set_cursor(0, { prev.start + 1, 0 })
    vim.cmd("normal! zz")
  else
    vim.notify("jupytext-render: no previous cell", vim.log.levels.INFO)
  end
end

--- Return the cell that contains the cursor, or nil if not inside any cell.
---@param buf? integer
---@return {start:integer, stop:integer, type:string}|nil
function M.current_cell(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cur = cursor_lnum(buf)
  local found = nil
  for _, cell in ipairs(cells.scan(buf)) do
    if cell.start <= cur then
      found = cell
    else
      break
    end
  end
  return found
end

return M
