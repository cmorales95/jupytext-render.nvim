local M = {}
local cells = require("jupytext-render.cells")

local NS = vim.api.nvim_create_namespace("jupytext_render")

---@return table[]  virt_lines entry
local function make_border_vline(text, hl)
  return { { text, hl } }
end

--- Set conceallevel=2 on every window currently showing `buf`,
--- and also on the current window as a fallback.
local function set_conceallevel(buf)
  -- Current window (always available)
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == buf then
    vim.wo[cur].conceallevel = 2
    vim.wo[cur].concealcursor = "nc"
  end
  -- All other windows showing this buffer
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= cur and vim.api.nvim_win_get_buf(win) == buf then
      vim.wo[win].conceallevel = 2
      vim.wo[win].concealcursor = "nc"
    end
  end
end

local function clear_conceallevel(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.wo[win].conceallevel = 0
    end
  end
end

--- Apply extmarks for all markdown cells in the buffer.
---@param buf integer
---@param cfg table  resolved config
function M.render(buf, cfg)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  local cell_list = cells.scan(buf)
  local bg_hl  = cfg.highlights.cell_bg
  local sep_hl = cfg.highlights.sep

  for _, cell in ipairs(cell_list) do
    if cell.type == "markdown" then
      -- Top border virtual line above marker
      vim.api.nvim_buf_set_extmark(buf, NS, cell.start, 0, {
        virt_lines_above = true,
        virt_lines = { make_border_vline(cfg.border.top, sep_hl) },
      })

      -- Conceal the marker line (# %% [markdown])
      if cfg.conceal_marker then
        local marker = vim.api.nvim_buf_get_lines(buf, cell.start, cell.start + 1, false)[1] or ""
        vim.api.nvim_buf_set_extmark(buf, NS, cell.start, 0, {
          end_row  = cell.start,
          end_col  = #marker,
          conceal  = "",
          hl_group = sep_hl,
          line_hl_group = sep_hl,
        })
      end

      -- Body lines
      for lnum = cell.start + 1, cell.stop do
        local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""

        if line:match("^# ") then
          -- Conceal the "# " prefix (2 chars)
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            end_row = lnum,
            end_col = 2,
            conceal = "",
          })
          -- Full-line background highlight
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            line_hl_group = bg_hl,
          })
        elseif line == "#" then
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            end_row = lnum,
            end_col = 1,
            conceal = "",
          })
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            line_hl_group = bg_hl,
          })
        end
      end

      -- Bottom border virtual line after last body line
      vim.api.nvim_buf_set_extmark(buf, NS, cell.stop, 0, {
        virt_lines = { make_border_vline(cfg.border.bottom, sep_hl) },
      })
    end
  end

  set_conceallevel(buf)
  return #cell_list  -- return cell count for debug
end

--- Clear all extmarks and restore conceallevel.
---@param buf integer
function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  clear_conceallevel(buf)
end

--- Return count of extmarks currently set on buf (for debug).
---@param buf integer
---@return integer
function M.mark_count(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
end

return M
