local M = {}
local cells = require("jupytext-render.cells")

local NS = vim.api.nvim_create_namespace("jupytext_render")

--- Build a styled virtual line for cell borders.
---@param text string
---@param hl string
---@return table[]  virt_lines entry
local function make_border_vline(text, hl)
  return { { text, hl } }
end

--- Apply extmarks for all markdown cells in the buffer.
---@param buf integer
---@param cfg table  resolved config
function M.render(buf, cfg)
  -- Clear previous marks
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  local cell_list = cells.scan(buf)
  local bg_hl  = cfg.highlights.cell_bg
  local sep_hl = cfg.highlights.sep

  for _, cell in ipairs(cell_list) do
    if cell.type == "markdown" then
      -- Top border (virtual line above the marker line)
      vim.api.nvim_buf_set_extmark(buf, NS, cell.start, 0, {
        virt_lines_above = true,
        virt_lines = { make_border_vline(cfg.border.top, sep_hl) },
      })

      -- Marker line: conceal the whole line or just dim it
      if cfg.conceal_marker then
        vim.api.nvim_buf_set_extmark(buf, NS, cell.start, 0, {
          end_row   = cell.start,
          end_col   = #vim.api.nvim_buf_get_lines(buf, cell.start, cell.start + 1, false)[1] or 0,
          conceal   = "",
          hl_group  = sep_hl,
          hl_eol    = true,
        })
      end

      -- Body lines: strip "# " prefix via conceal, apply background hl
      for lnum = cell.start + 1, cell.stop do
        local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""

        -- Only process comment lines (markdown content lines start with "# ")
        if line:match("^# ") then
          -- Conceal the leading "# " (2 chars)
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            end_row = lnum,
            end_col = 2,
            conceal = "",
          })
          -- Background highlight for the whole line
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            end_row  = lnum + 1,
            end_col  = 0,
            hl_group = bg_hl,
            hl_eol   = true,
          })
        elseif line == "#" then
          -- Empty markdown line: "# " with no content
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            end_row = lnum,
            end_col = 1,
            conceal = "",
          })
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            end_row  = lnum + 1,
            end_col  = 0,
            hl_group = bg_hl,
            hl_eol   = true,
          })
        end
      end

      -- Bottom border (virtual line after the last body line)
      vim.api.nvim_buf_set_extmark(buf, NS, cell.stop, 0, {
        virt_lines = { make_border_vline(cfg.border.bottom, sep_hl) },
      })
    end
  end

  -- Enable concealment so the extmark conceals take effect
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = "nc"
  end
end

--- Clear all jupytext_render extmarks from a buffer.
---@param buf integer
function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  -- Restore conceallevel to 0 (default)
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.wo[win].conceallevel = 0
  end
end

return M
