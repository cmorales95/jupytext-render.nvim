local M = {}
local cells = require("jupytext-render.cells")

local NS = vim.api.nvim_create_namespace("jupytext_render")

-- Heading highlight groups (linked to treesitter markdown highlights)
local HEADING_HLS = {
  "@markup.heading.1.markdown",
  "@markup.heading.2.markdown",
  "@markup.heading.3.markdown",
  "@markup.heading.4.markdown",
  "@markup.heading.5.markdown",
  "@markup.heading.6.markdown",
}

-- Heading icon prefixes per level
local HEADING_ICONS = { "󰎤 ", "󰎧 ", "󰎪 ", "󰎭 ", "󰎱 ", "󰎳 " }

---@return table[]  virt_lines entry
local function make_border_vline(text, hl)
  return { { text, hl } }
end

--- Build overlay text for a table row, replacing | with box-drawing chars.
---@param content string  markdown content (after stripping "# " prefix)
---@param is_separator boolean  true if this is a separator row (|---|---|)
---@return string  rendered text with box-drawing characters
local function render_table_row(content, is_separator)
  local parts = {}
  for i = 1, #content do
    local ch = content:sub(i, i)
    if ch == "|" then
      if is_separator then
        if i == 1 then
          table.insert(parts, "├")
        elseif i == #content then
          table.insert(parts, "┤")
        else
          table.insert(parts, "┼")
        end
      else
        if i == 1 then
          table.insert(parts, "┃")
        elseif i == #content then
          table.insert(parts, "┃")
        else
          table.insert(parts, "│")
        end
      end
    elseif is_separator and (ch == "-" or ch == ":") then
      table.insert(parts, "─")
    else
      table.insert(parts, ch)
    end
  end
  return table.concat(parts)
end

--- Render a markdown body line with inline formatting.
--- Handles headings and tables via overlay extmarks.
---@param buf integer
---@param lnum integer  0-indexed line number
---@param content string  markdown content (after stripping "# " prefix)
---@param bg_hl string  background highlight group
local function render_md_line(buf, lnum, content, bg_hl)
  -- Detect heading: content starts with one or more # followed by space
  local hashes, heading_text = content:match("^(#+) (.+)")
  if hashes then
    local level = math.min(#hashes, 6)
    local hl = HEADING_HLS[level]
    local icon = HEADING_ICONS[level] or ""
    vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
      virt_text = { { icon .. heading_text, hl } },
      virt_text_pos = "overlay",
    })
    -- Pad remaining characters if overlay is shorter than original line
    local orig_len = #(vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or "")
    local display_len = vim.fn.strdisplaywidth(icon .. heading_text)
    if display_len < orig_len then
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        virt_text = { { string.rep(" ", orig_len - display_len), bg_hl } },
        virt_text_pos = "eol",
      })
    end
    vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
      line_hl_group = hl,
    })
    return
  end

  -- Detect table row: starts with |
  if content:match("^|") then
    local is_sep = content:match("^|[%-:%s|]+$") ~= nil
    local rendered = render_table_row(content, is_sep)
    vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
      virt_text = { { "  " .. rendered, bg_hl } },
      virt_text_pos = "overlay",
    })
    vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
      line_hl_group = bg_hl,
    })
    return
  end

  -- Regular line: just overlay the "# " prefix
  vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
    virt_text = { { "  ", bg_hl } },
    virt_text_pos = "overlay",
  })
  vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
    line_hl_group = bg_hl,
  })
end

--- Apply extmarks for all cells in the buffer.
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
          local content = line:sub(3) -- strip "# " prefix
          render_md_line(buf, lnum, content, bg_hl)
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
