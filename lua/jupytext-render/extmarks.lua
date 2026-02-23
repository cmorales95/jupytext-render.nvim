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

-- Common language aliases for treesitter parser names
local LANG_MAP = {
  py = "python", js = "javascript", ts = "typescript",
  rb = "ruby", rs = "rust", sh = "bash", zsh = "bash",
  yml = "yaml", md = "markdown", tf = "hcl",
}

---@return table[]  virt_lines entry
local function make_border_vline(text, hl)
  return { { text, hl } }
end

--- Use treesitter to get syntax highlights for a code block.
--- Returns a table keyed by 1-indexed line number, each value a list of
--- { start_col, end_col, hl } ranges sorted by start_col.
---@param code_lines string[]  lines of code (no "# " prefix)
---@param lang string  language name from the ``` fence
---@return table<integer, table[]>|nil  per-line highlights, or nil
local function get_code_highlights(code_lines, lang)
  lang = LANG_MAP[lang] or lang
  if lang == "" then return nil end

  -- Check if treesitter parser is available
  if not pcall(vim.treesitter.language.inspect, lang) then return nil end

  local code = table.concat(code_lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok or not parser then return nil end

  parser:parse(true)
  local trees = parser:trees()
  if not trees or #trees == 0 then return nil end

  local q_ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not q_ok or not query then return nil end

  local num_lines = #code_lines
  local line_hl = {}
  for i = 1, num_lines do line_hl[i] = {} end

  for id, node in query:iter_captures(trees[1]:root(), code, 0, num_lines) do
    local name = query.captures[id]
    local hl = "@" .. name .. "." .. lang
    local sr, sc, er, ec = node:range()

    if sr == er then
      if sr + 1 <= num_lines then
        table.insert(line_hl[sr + 1], { start_col = sc, end_col = ec, hl = hl })
      end
    else
      if sr + 1 <= num_lines then
        table.insert(line_hl[sr + 1], { start_col = sc, end_col = #code_lines[sr + 1], hl = hl })
      end
      for r = sr + 1, er - 1 do
        if r + 1 <= num_lines then
          table.insert(line_hl[r + 1], { start_col = 0, end_col = #code_lines[r + 1], hl = hl })
        end
      end
      if er + 1 <= num_lines then
        table.insert(line_hl[er + 1], { start_col = 0, end_col = ec, hl = hl })
      end
    end
  end

  return line_hl
end

--- Build a highlighted virt_text overlay for a single code block line.
--- Uses a character-level highlight map (last capture wins) to produce
--- minimal segments with proper syntax colors.
---@param line_text string  the code content
---@param highlights table[]|nil  list of {start_col, end_col, hl}
---@param cb_hl string  code block background highlight
---@return table[]  virt_text chunks
local function build_highlighted_code_line(line_text, highlights, cb_hl)
  if not highlights or #highlights == 0 or #line_text == 0 then
    return { { "  " .. line_text, cb_hl } }
  end

  -- Build character-level highlight map (last capture wins)
  local char_hl = {}
  for _, h in ipairs(highlights) do
    for ci = h.start_col + 1, math.min(h.end_col, #line_text) do
      char_hl[ci] = h.hl
    end
  end

  -- Convert to segments
  local virt = { { "  ", cb_hl } } -- prefix for "# "
  local ci = 1
  while ci <= #line_text do
    local cur = char_hl[ci]
    local cj = ci
    while cj <= #line_text and char_hl[cj] == cur do
      cj = cj + 1
    end
    local text = line_text:sub(ci, cj - 1)
    if cur then
      table.insert(virt, { text, { cb_hl, cur } })
    else
      table.insert(virt, { text, cb_hl })
    end
    ci = cj
  end

  return virt
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

--- Parse a table row into trimmed cell contents.
---@param content string  raw table row (after stripping "# ")
---@return string[]  list of trimmed cell texts
local function parse_table_cells(content)
  local row_cells = {}
  local col = 2 -- skip leading |
  while col <= #content do
    local next_pipe = content:find("|", col, true)
    if not next_pipe then break end
    local cell = content:sub(col, next_pipe - 1)
    -- Trim whitespace
    cell = cell:match("^%s*(.-)%s*$") or ""
    table.insert(row_cells, cell)
    col = next_pipe + 1
  end
  return row_cells
end

--- Compute the display width of parsed inline-md segments.
---@param segments table[]  from parse_inline_md
---@return integer
local function segments_display_width(segments)
  local w = 0
  for _, seg in ipairs(segments) do
    w = w + vim.fn.strdisplaywidth(seg[1])
  end
  return w
end

--- Build a box-drawing border from column widths (including 1-space padding each side).
---@param col_widths integer[]  content widths per column (padding added internally)
---@param kind "top"|"bottom"|"sep"
---@return string
local function build_table_border(col_widths, kind)
  local left   = kind == "top" and "┌" or kind == "bottom" and "└" or "├"
  local right  = kind == "top" and "┐" or kind == "bottom" and "┘" or "┤"
  local middle = kind == "top" and "┬" or kind == "bottom" and "┴" or "┼"

  local parts = { left }
  for i, w in ipairs(col_widths) do
    -- +2 for 1 space padding on each side
    table.insert(parts, string.rep("─", w + 2))
    if i < #col_widths then
      table.insert(parts, middle)
    end
  end
  table.insert(parts, right)
  return table.concat(parts)
end

--- Render an entire table block (contiguous table lines) with aligned columns.
--- Computes max formatted width per column, then renders every row padded
--- to those widths with box-drawing borders.
---@param buf integer
---@param lines_info table[]  full lines_info array
---@param start_idx integer  first table line index in lines_info
---@param end_idx integer  last table line index in lines_info
---@param bg_hl string
local function render_table_block(buf, lines_info, start_idx, end_idx, bg_hl)
  -- Parse all rows into cells and find max formatted width per column
  local rows = {}
  local num_cols = 0
  for idx = start_idx, end_idx do
    local info = lines_info[idx]
    local is_sep = info.content:match("^|[%-:%s|]+$") ~= nil
    local row_cells = parse_table_cells(info.content)
    num_cols = math.max(num_cols, #row_cells)
    table.insert(rows, { idx = idx, cells = row_cells, is_sep = is_sep })
  end

  -- Compute max formatted width per column (excluding separator rows)
  local col_widths = {}
  for i = 1, num_cols do col_widths[i] = 0 end
  for _, row in ipairs(rows) do
    if not row.is_sep then
      for i, cell_text in ipairs(row.cells) do
        local segs = parse_inline_md(cell_text)
        local w = segments_display_width(segs)
        if i <= num_cols then
          col_widths[i] = math.max(col_widths[i], w)
        end
      end
    end
  end

  -- Top border (virtual line above first row)
  local first_lnum = lines_info[start_idx].lnum
  vim.api.nvim_buf_set_extmark(buf, NS, first_lnum, 0, {
    virt_lines_above = true,
    virt_lines = { { { "  " .. build_table_border(col_widths, "top"), bg_hl } } },
  })

  -- Render each row
  for _, row in ipairs(rows) do
    local lnum = lines_info[row.idx].lnum
    local orig_width = vim.fn.strdisplaywidth(lines_info[row.idx].raw)

    if row.is_sep then
      -- Separator: ├───┼───┤
      local border = build_table_border(col_widths, "sep")
      local virt_str = "  " .. border
      if vim.fn.strdisplaywidth(virt_str) < orig_width then
        virt_str = virt_str .. string.rep(" ", orig_width - vim.fn.strdisplaywidth(virt_str))
      end
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        virt_text = { { virt_str, bg_hl } },
        virt_text_pos = "overlay",
      })
    else
      -- Data row: │ cell │ cell │
      local virt = { { "  │", bg_hl } }
      for i = 1, num_cols do
        local cell_text = row.cells[i] or ""
        local segs = parse_inline_md(cell_text)
        local sv = segments_to_virt_text(segs, bg_hl)
        local fmt_w = segments_display_width(segs)

        -- Leading space
        table.insert(virt, { " ", bg_hl })
        -- Formatted content
        for _, chunk in ipairs(sv) do
          table.insert(virt, chunk)
        end
        -- Pad to column width + trailing space + pipe
        local pad = col_widths[i] - fmt_w
        if pad > 0 then
          table.insert(virt, { string.rep(" ", pad), bg_hl })
        end
        table.insert(virt, { " │", bg_hl })
      end

      -- Pad overlay to cover original line
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
  end

  -- Bottom border (virtual line after last row)
  local last_lnum = lines_info[end_idx].lnum
  vim.api.nvim_buf_set_extmark(buf, NS, last_lnum, 0, {
    virt_lines = { { { "  " .. build_table_border(col_widths, "bottom"), bg_hl } } },
  })
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

  -- Collect fenced code blocks and compute syntax highlights
  do
    local cb_start_idx = nil
    local cb_lang = ""
    for idx, info in ipairs(lines_info) do
      if info.block == "code_fence_open" then
        cb_start_idx = idx
        cb_lang = info.code_lang or ""
      elseif info.block == "code_fence_close" and cb_start_idx then
        local code_lines = {}
        for j = cb_start_idx + 1, idx - 1 do
          table.insert(code_lines, lines_info[j].content or "")
        end
        if #code_lines > 0 and cb_lang ~= "" then
          local hl = get_code_highlights(code_lines, cb_lang)
          if hl then
            for j = cb_start_idx + 1, idx - 1 do
              lines_info[j].code_hl = hl[j - cb_start_idx]
            end
          end
        end
        cb_start_idx = nil
      end
    end
  end

  -- Third pass: find contiguous table blocks
  local table_blocks = {}
  local i = 1
  while i <= #lines_info do
    if lines_info[i].block == "table" then
      local start_idx = i
      while i <= #lines_info and lines_info[i].block == "table" do
        i = i + 1
      end
      table.insert(table_blocks, { start_idx = start_idx, end_idx = i - 1 })
    else
      i = i + 1
    end
  end

  -- Build a set of table line indices (to skip in the per-line pass)
  local table_line_set = {}
  for _, tb in ipairs(table_blocks) do
    for idx = tb.start_idx, tb.end_idx do
      table_line_set[idx] = true
    end
  end

  -- Render table blocks (whole block at once for proper alignment)
  for _, tb in ipairs(table_blocks) do
    render_table_block(buf, lines_info, tb.start_idx, tb.end_idx, bg_hl)
  end

  -- Fourth pass: render non-table lines
  for idx, info in ipairs(lines_info) do
    if table_line_set[idx] then
      goto next_line -- already rendered by render_table_block
    end

    local lnum = info.lnum
    local orig_width = vim.fn.strdisplaywidth(info.raw)

    if info.block == "code_fence_open" then
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
      local content = info.content or ""
      local virt = build_highlighted_code_line(content, info.code_hl, cb_hl)
      if virt_text_width(virt) < orig_width then
        table.insert(virt, { string.rep(" ", orig_width - virt_text_width(virt)), cb_hl })
      end
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        virt_text = virt,
        virt_text_pos = "overlay",
      })
      vim.api.nvim_buf_set_extmark(buf, NS, lnum, 0, {
        line_hl_group = cb_hl,
      })

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

    ::next_line::
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
