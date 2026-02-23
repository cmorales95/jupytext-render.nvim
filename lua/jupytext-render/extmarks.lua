local M = {}
local cells = require("jupytext-render.cells")

local NS = vim.api.nvim_create_namespace("jupytext_render")

---@return table[]  virt_lines entry
local function make_border_vline(text, hl)
  return { { text, hl } }
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

      -- Hide the marker line (# %% [markdown]) with overlay
      if cfg.conceal_marker then
        local marker = vim.api.nvim_buf_get_lines(buf, cell.start, cell.start + 1, false)[1] or ""
        vim.api.nvim_buf_set_extmark(buf, NS, cell.start, 0, {
          virt_text = { { string.rep(" ", #marker), sep_hl } },
          virt_text_pos = "overlay",
          line_hl_group = sep_hl,
        })
      end

      -- Body lines
      for lnum = cell.start + 1, cell.stop do
        local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""

        if line:match("^# ") then
          -- Hide "# " Python comment prefix by overlaying with spaces
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            virt_text = { { "  ", bg_hl } },
            virt_text_pos = "overlay",
          })
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            line_hl_group = bg_hl,
          })
        elseif line == "#" then
          -- Hide bare "#" by overlaying with a space
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            virt_text = { { " ", bg_hl } },
            virt_text_pos = "overlay",
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

    elseif cell.type == "code" then
      -- Top border virtual line above marker
      vim.api.nvim_buf_set_extmark(buf, NS, cell.start, 0, {
        virt_lines_above = true,
        virt_lines = { make_border_vline(cfg.border.code_top or cfg.border.bottom, sep_hl) },
      })

      -- Hide the marker line (# %%) with overlay
      if cfg.conceal_marker then
        local marker = vim.api.nvim_buf_get_lines(buf, cell.start, cell.start + 1, false)[1] or ""
        vim.api.nvim_buf_set_extmark(buf, NS, cell.start, 0, {
          virt_text = { { string.rep(" ", #marker), sep_hl } },
          virt_text_pos = "overlay",
          line_hl_group = sep_hl,
        })
      end

      -- Bottom border virtual line after last body line
      vim.api.nvim_buf_set_extmark(buf, NS, cell.stop, 0, {
        virt_lines = { make_border_vline(cfg.border.bottom, sep_hl) },
      })
    end
  end

  return #cell_list  -- return cell count for debug
end

--- Clear all extmarks.
---@param buf integer
function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
end

--- Return count of extmarks currently set on buf (for debug).
---@param buf integer
---@return integer
function M.mark_count(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
end

return M
