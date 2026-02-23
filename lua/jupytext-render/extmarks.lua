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

-- Inline style highlight groups (defined in init.lua define_highlights)
local STYLE_HLS = {
  bold        = "JupytextBold",
  italic      = "JupytextItalic",
  bold_italic = "JupytextBoldItalic",
  code        = "JupytextCode",
}

---@return table[]  virt_lines entry
local function make_border_vline(text, hl)
  return { { text, hl } }
end

--- Parse inline markdown formatting into segments.
--- Returns a list of { text, style } where style is "normal", "bold",
--- "italic", "bold_italic", or "code".
---@param text string
---@return table[]
local function parse_inline_md(text)
  local segments = {}
  local pos = 1
  local len = #text

  while pos <= len do
    local ch = text:sub(pos, pos)

    -- Bold italic: ***...***
    if text:sub(pos, pos + 2) == "***" then
      local close = text:find("%*%*%*", pos + 3)
      if close then
        table.insert(segments, { text:sub(pos + 3, close - 1), "bold_italic" })
        pos = close + 3
        goto continue
      end
    end

    -- Bold: **...**
    if text:sub(pos, pos + 1) == "**" then
      local close = text:find("%*%*", pos + 2)
      if close then
        table.insert(segments, { text:sub(pos + 2, close - 1), "bold" })
        pos = close + 2
        goto continue
      end
    end

    -- Italic: *...* (single asterisk, not part of **)
    if ch == "*" and text:sub(pos + 1, pos + 1) ~= "*" then
      local close = text:find("%*", pos + 1)
      if close and text:sub(close + 1, close + 1) ~= "*"
         and (close == 1 or text:sub(close - 1, close - 1) ~= "*") then
        table.insert(segments, { text:sub(pos + 1, close - 1), "italic" })
        pos = close + 1
        goto continue
      end
    end

    -- Inline code: `...`
    if ch == "`" then
      local close = text:find("`", pos + 1, true)
      if close then
        table.insert(segments, { text:sub(pos + 1, close - 1), "code" })
        pos = close + 1
        goto continue
      end
    end

    -- Normal text: collect until next potential marker
    do
      local next_special = len + 1
      for _, p in ipairs({ "%*", "`" }) do
        local found = text:find(p, pos + 1)
        if found and found < next_special then
          next_special = found
        end
      end
      table.insert(segments, { text:sub(pos, next_special - 1), "normal" })
      pos = next_special
    end

    ::continue::
  end

  return segments
end

--- Compute the display width of a virt_text array.
---@param virt table[]
---@return integer
local function virt_text_width(virt)
  local w = 0
  for _, chunk in ipairs(virt) do
    w = w + vim.fn.strdisplaywidth(chunk[1])
  end
  return w
end

--- Build virt_text segments from parsed inline-md segments.
---@param segments table[]  from parse_inline_md
---@param hl string  base highlight group
---@return table[]  virt_text chunks
local function segments_to_virt_text(segments, hl)
  local virt = {}
  for _, seg in ipairs(segments) do
    local style_hl = STYLE_HLS[seg[2]]
    if style_hl then
      table.insert(virt, { seg[1], { hl, style_hl } })
    else
      table.insert(virt, { seg[1], hl })
    end
  end
  return virt
end

--- Detect column widths from a table block for proper box-drawing borders.
--- Returns a list of column widths (character counts between pipes).
---@param contents string[]  list of table row contents (after stripping "# ")
---@return integer[]|nil  column widths, or nil if not a valid table
local function detect_table_columns(contents)
  -- Use the separator row (or first row) to detect columns
  for _, content in ipairs(contents) do
    if content:match("^|") then
      local widths = {}
      local col = 2 -- skip leading |
      while col <= #content do
        local next_pipe = content:find("|", col, true)
        if not next_pipe then break end
        table.insert(widths, next_pipe - col)
        col = next_pipe + 1
      end
      if #widths > 0 then return widths end
    end
  end
  return nil
end

--- Build a box-drawing top or bottom border from column widths.
---@param widths integer[]
---@param kind "top"|"bottom"|"sep"
---@return string
local function build_table_border(widths, kind)
  local left   = kind == "top" and "┌" or kind == "bottom" and "└" or "├"
  local right  = kind == "top" and "┐" or kind == "bottom" and "┘" or "┤"
  local middle = kind == "top" and "┬" or kind == "bottom" and "┴" or "┼"
  local horiz  = "─"

  local parts = { left }
  for i, w in ipairs(widths) do
    table.insert(parts, string.rep(horiz, w))
    if i < #widths then
      table.insert(parts, middle)
    end
  end
  table.insert(parts, right)
  return table.concat(parts)
end

--- Build a virt_text overlay for a table data row with box-drawing pipes
--- and inline formatting in cells.
---@param content string  markdown content (after stripping "# " prefix)
---@param bg_hl string
---@return table[]  virt_text chunks
local function render_table_data_row(content, bg_hl)
  local virt = { { "  ", bg_hl } } -- prefix for "# "
  local col = 1
  while col <= #content do
    local ch = content:sub(col, col)
    if ch == "|" then
      table.insert(virt, { "│", bg_hl })
      col = col + 1
    else
      local next_pipe = content:find("|", col, true) or (#content + 1)
      local cell_text = content:sub(col, next_pipe - 1)
      local cell_width = vim.fn.strdisplaywidth(cell_text)

      local segments = parse_inline_md(cell_text)
      local sv = segments_to_virt_text(segments, bg_hl)

      -- Measure formatted width
      local fmt_width = 0
      for _, chunk in ipairs(sv) do
        fmt_width = fmt_width + vim.fn.strdisplaywidth(chunk[1])
        table.insert(virt, chunk)
      end

      -- Pad cell to original width so pipes stay aligned with borders
      if fmt_width < cell_width then
        table.insert(virt, { string.rep(" ", cell_width - fmt_width), bg_hl })
      end

      col = next_pipe
    end
  end
  return virt
end

--- Render a markdown body line with inline formatting.
--- Handles headings and inline bold/italic/code via overlay extmarks.
--- Tables and code blocks are handled at the cell level in M.render().
---@param buf integer
---@param lnum integer  0-indexed line number
---@param content string  markdown content (after stripping "# " prefix)
---@param bg_hl string  background highlight group
local function render_md_line(buf, lnum, content, bg_hl)
  local orig_line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""
  local orig_width = vim.fn.strdisplaywidth(orig_line)

  -- Detect heading: content starts with one or more # followed by space
  local hashes, heading_text = content:match("^(#+) (.+)")
  if hashes then
    local level = math.min(#hashes, 6)
    local hl = HEADING_HLS[level]
    local icon = HEADING_ICONS[level] or ""

    local segments = parse_inline_md(heading_text)
    local virt = { { icon, hl } }
    for _, chunk in ipairs(segments_to_virt_text(segments, hl)) do
      table.insert(virt, chunk)
    end

    -- Pad to cover original line
    if virt_text_width(virt) < orig_width then
      table.insert(virt, { string.rep(" ", orig_width - virt_text_width(virt)), hl })
    end

    vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
      virt_text = virt,
      virt_text_pos = "overlay",
    })
    vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
      line_hl_group = hl,
    })
    return
  end

  -- Regular line: parse inline formatting
  local segments = parse_inline_md(content)
  local has_formatting = false
  for _, seg in ipairs(segments) do
    if seg[2] ~= "normal" then
      has_formatting = true
      break
    end
  end

  if has_formatting then
    local virt = { { "  ", bg_hl } }
    for _, chunk in ipairs(segments_to_virt_text(segments, bg_hl)) do
      table.insert(virt, chunk)
    end
    if virt_text_width(virt) < orig_width then
      table.insert(virt, { string.rep(" ", orig_width - virt_text_width(virt)), bg_hl })
    end
    vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
      virt_text = virt,
      virt_text_pos = "overlay",
    })
  else
    vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
      virt_text = { { "  ", bg_hl } },
      virt_text_pos = "overlay",
    })
  end

  vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
    line_hl_group = bg_hl,
  })
end

--- Render the body lines of a markdown cell, handling multi-line constructs
--- (tables, fenced code blocks) that require cross-line state tracking.
---@param buf integer
---@param cell table  {start, stop, type}
---@param cfg table
local function render_md_body(buf, cell, cfg)
  local bg_hl  = cfg.highlights.cell_bg
  local sep_hl = cfg.highlights.sep
  local cb_hl  = "JupytextCodeBlock"
  local cf_hl  = "JupytextCodeFence"

  -- First pass: collect line contents and classify them
  local lines_info = {} -- { lnum, raw, content, kind }
  for lnum = cell.start + 1, cell.stop do
    local raw = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""
    local info = { lnum = lnum, raw = raw, content = nil, kind = "empty" }
    if raw:match("^# ") then
      info.content = raw:sub(3)
      info.kind = "content"
    elseif raw == "#" then
      info.content = ""
      info.kind = "blank"
    end
    table.insert(lines_info, info)
  end

  -- Second pass: identify table blocks and code fence blocks
  -- Mark each line with its block type
  local in_code_block = false
  local code_lang = ""
  for _, info in ipairs(lines_info) do
    if info.kind == "content" then
      if not in_code_block and info.content:match("^```") then
        in_code_block = true
        code_lang = info.content:match("^```(%w+)") or ""
        info.block = "code_fence_open"
        info.code_lang = code_lang
      elseif in_code_block and info.content:match("^```%s*$") then
        in_code_block = false
        info.block = "code_fence_close"
      elseif in_code_block then
        info.block = "code_block"
      elseif info.content:match("^|") then
        info.block = "table"
      else
        info.block = "text"
      end
    elseif info.kind == "blank" then
      if in_code_block then
        info.block = "code_block"
      else
        info.block = "blank"
      end
    end
  end

  -- Third pass: collect table blocks to compute column widths
  -- Find contiguous runs of table lines
  local table_blocks = {} -- { { start_idx, end_idx, col_widths } }
  local i = 1
  while i <= #lines_info do
    if lines_info[i].block == "table" then
      local start_idx = i
      local contents = {}
      while i <= #lines_info and lines_info[i].block == "table" do
        table.insert(contents, lines_info[i].content)
        i = i + 1
      end
      local widths = detect_table_columns(contents)
      table.insert(table_blocks, { start_idx = start_idx, end_idx = i - 1, widths = widths })
    else
      i = i + 1
    end
  end

  -- Build a lookup: line index → table block
  local table_block_map = {}
  for _, tb in ipairs(table_blocks) do
    for idx = tb.start_idx, tb.end_idx do
      table_block_map[idx] = tb
    end
  end

  -- Fourth pass: render each line
  for idx, info in ipairs(lines_info) do
    local lnum = info.lnum
    local orig_width = vim.fn.strdisplaywidth(info.raw)

    if info.block == "code_fence_open" then
      -- Opening ``` fence: render as a subtle code border
      local lang = info.code_lang or ""
      local label = lang ~= "" and ("── " .. lang .. " ") or "──── "
      local pad = string.rep("─", math.max(0, 30 - vim.fn.strdisplaywidth(label)))
      local fence_text = "  " .. label .. pad
      if vim.fn.strdisplaywidth(fence_text) < orig_width then
        fence_text = fence_text .. string.rep(" ", orig_width - vim.fn.strdisplaywidth(fence_text))
      end
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        virt_text = { { fence_text, cf_hl } },
        virt_text_pos = "overlay",
      })
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        line_hl_group = cf_hl,
      })

    elseif info.block == "code_fence_close" then
      -- Closing ``` fence
      local fence_text = "  " .. string.rep("─", 30)
      if vim.fn.strdisplaywidth(fence_text) < orig_width then
        fence_text = fence_text .. string.rep(" ", orig_width - vim.fn.strdisplaywidth(fence_text))
      end
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        virt_text = { { fence_text, cf_hl } },
        virt_text_pos = "overlay",
      })
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        line_hl_group = cf_hl,
      })

    elseif info.block == "code_block" then
      -- Inside fenced code block: show content with code background
      local display = "  " .. (info.content or "")
      if vim.fn.strdisplaywidth(display) < orig_width then
        display = display .. string.rep(" ", orig_width - vim.fn.strdisplaywidth(display))
      end
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        virt_text = { { display, cb_hl } },
        virt_text_pos = "overlay",
      })
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        line_hl_group = cb_hl,
      })

    elseif info.block == "table" then
      local tb = table_block_map[idx]
      local is_sep = info.content:match("^|[%-:%s|]+$") ~= nil

      -- Add top border virtual line above first table row
      if tb and idx == tb.start_idx and tb.widths then
        vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
          virt_lines_above = true,
          virt_lines = { { { "  " .. build_table_border(tb.widths, "top"), bg_hl } } },
        })
      end

      if is_sep then
        -- Separator row: use box-drawing
        if tb and tb.widths then
          local border = build_table_border(tb.widths, "sep")
          local virt_str = "  " .. border
          if vim.fn.strdisplaywidth(virt_str) < orig_width then
            virt_str = virt_str .. string.rep(" ", orig_width - vim.fn.strdisplaywidth(virt_str))
          end
          vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
            virt_text = { { virt_str, bg_hl } },
            virt_text_pos = "overlay",
          })
        end
      else
        -- Data row: replace pipes with box-drawing + inline formatting
        local virt = render_table_data_row(info.content, bg_hl)
        if virt_text_width(virt) < orig_width then
          table.insert(virt, { string.rep(" ", orig_width - virt_text_width(virt)), bg_hl })
        end
        vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
          virt_text = virt,
          virt_text_pos = "overlay",
        })
      end

      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        line_hl_group = bg_hl,
      })

      -- Add bottom border virtual line after last table row
      if tb and idx == tb.end_idx and tb.widths then
        vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
          virt_lines = { { { "  " .. build_table_border(tb.widths, "bottom"), bg_hl } } },
        })
      end

    elseif info.block == "text" then
      render_md_line(buf, lnum, info.content, bg_hl)

    elseif info.block == "blank" then
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        virt_text = { { " ", bg_hl } },
        virt_text_pos = "overlay",
      })
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        line_hl_group = bg_hl,
      })
    end
  end
end

--- Apply extmarks for all cells in the buffer.
---@param buf integer
---@param cfg table  resolved config
function M.render(buf, cfg)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  local cell_list = cells.scan(buf)
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

      -- Body lines (tables, code blocks, inline formatting)
      render_md_body(buf, cell, cfg)

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

  return #cell_list
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
