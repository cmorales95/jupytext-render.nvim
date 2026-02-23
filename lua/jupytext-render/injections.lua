local M = {}

local cells = require("jupytext-render.cells")

-- The treesitter injection query that turns Python comment lines into markdown.
-- Uses injection.combined to produce a single markdown LanguageTree that
-- render-markdown.nvim can discover and render. The bounding-box region bug
-- in Neovim 0.11+ (where combined regions merge into one giant range) is
-- worked around by _fix_markdown_regions(), which replaces the bounding-box
-- with correct per-line ranges after every parse — on both the markdown
-- child AND its markdown_inline grandchild.
--
-- The custom predicate #is-in-markdown-cell? restricts injection to lines
-- inside markdown cells only, excluding YAML frontmatter and code cell comments.
--
-- The #lua-match? "^# " excludes bare "#" lines (blank comment lines).
M._injection_query = [[
  ((comment) @injection.content
    (#is-in-markdown-cell? @injection.content)
    (#lua-match? @injection.content "^# ")
    (#offset! @injection.content 0 2 0 0)
    (#set! injection.combined)
    (#set! injection.language "markdown"))
]]

local _predicate_registered = false
local _patched_parsers = {}
local _fixing = {} -- per-buffer re-entrancy guard

--- Register the custom treesitter predicate `is-in-markdown-cell?`.
--- Only registers once; safe to call multiple times.
function M._register_predicate()
  if _predicate_registered then return end
  _predicate_registered = true

  vim.treesitter.query.add_predicate("is-in-markdown-cell?", function(match, _, bufnr, pred)
    local node = match[pred[2]]
    if not node then return false end
    -- In Neovim 0.11+ match[id] returns a list of nodes, not a single TSNode
    if type(node) == "table" then
      node = node[1]
      if not node then return false end
    end
    -- Lazily ensure cache is populated — any treesitter parse pass
    -- (including render-markdown re-parses) will have up-to-date data.
    cells.update_cache(bufnr)
    local row = node:start()
    return cells.is_line_in_markdown_cell(bufnr, row)
  end, { force = true })
end

--- Register the treesitter injection query for Python.
--- Uses ;; extends to merge with existing Python injection queries
--- from nvim-treesitter. Safe to call multiple times.
function M._register_injection()
  M._register_predicate()
  pcall(vim.treesitter.query.set, "python", "injections",
    ";; extends\n" .. M._injection_query)
end

--- Compute per-line included regions for markdown content in the buffer.
--- Each content line (starting with "# ") gets a range that strips the prefix
--- and includes the trailing newline. Bare "#" lines get a range covering
--- just the newline (paragraph break).
---@param buf integer
---@return table[] ranges  list of {start_row, start_col, end_row, end_col}
local function compute_ranges(buf)
  local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ranges = {}
  local cell_list = cells.scan(buf)
  for _, cell in ipairs(cell_list) do
    if cell.type == "markdown" then
      for lnum = cell.start + 1, cell.stop do
        local line = buf_lines[lnum + 1] or ""
        if line:match("^# ") then
          table.insert(ranges, { lnum, 2, lnum + 1, 0 })
        elseif line == "#" then
          table.insert(ranges, { lnum, 1, lnum + 1, 0 })
        end
      end
    end
  end
  return ranges
end

--- Fix the markdown_inline child's included regions.
---@param md table  markdown LanguageTree
---@param ranges table[]  per-line ranges
local function fix_md_inline(md, ranges)
  if #ranges == 0 then return end
  local md_inline = md:children()["markdown_inline"]
  if not md_inline then return end
  md_inline:set_included_regions({ ranges })
  md_inline:invalidate(true)
  md_inline:parse(true)
end

--- Build correct per-line included regions for the markdown child parser
--- and its markdown_inline grandchild. Works around Neovim 0.11+ where
--- injection.combined creates a single bounding-box region.
---
--- Also monkey-patches the markdown parser (once) so that when
--- render-markdown.nvim triggers its own re-parses of the markdown tree,
--- markdown_inline regions are fixed automatically.
---@param buf integer
function M._fix_markdown_regions(buf)
  if _fixing[buf] then return end
  _fixing[buf] = true

  pcall(function()
    local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, "python")
    if not ts_ok or not parser then return end

    local md = parser:children()["markdown"]
    if not md then return end

    local ranges = compute_ranges(buf)
    if #ranges == 0 then return end

    -- Fix markdown child regions (bounding-box → per-line)
    md:set_included_regions({ ranges })
    md:invalidate(true)
    md:parse(true)

    -- Fix markdown_inline grandchild regions (same bounding-box issue)
    fix_md_inline(md, ranges)

    -- Monkey-patch the markdown parser (once per instance) so that
    -- future re-parses by render-markdown.nvim also get correct
    -- markdown_inline regions. Without this, render-markdown's own
    -- md:parse() calls recreate markdown_inline with bounding-box.
    local entry = _patched_parsers[buf]
    if not entry or entry.md ~= md then
      if not entry then _patched_parsers[buf] = {} end
      _patched_parsers[buf].md = md

      local orig_md_parse = md.parse
      md.parse = function(self, ...)
        local result = orig_md_parse(self, ...)
        -- Only fix md_inline if we're not already inside _fix_markdown_regions
        -- (which handles md_inline itself after fixing md first).
        if not _fixing[buf] then
          _fixing[buf] = true
          pcall(fix_md_inline, self, compute_ranges(buf))
          _fixing[buf] = nil
        end
        return result
      end
    end
  end)

  _fixing[buf] = nil
end

--- Monkey-patch the Python parser's parse method to fix markdown injection
--- regions after each parse pass. Ensures correct regions even when Neovim
--- or render-markdown triggers re-parses.
---@param buf integer
function M._patch_parser(buf)
  local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, "python")
  if not ts_ok or not parser then return end

  local entry = _patched_parsers[buf]
  if entry and entry.parser == parser then return end

  if not entry then _patched_parsers[buf] = {} end
  _patched_parsers[buf].parser = parser

  local orig_parse = parser.parse
  parser.parse = function(self, ...)
    local result = orig_parse(self, ...)
    M._fix_markdown_regions(buf)
    return result
  end
end

--- Clean up patched parser references for a buffer.
---@param buf integer
function M._cleanup(buf)
  _patched_parsers[buf] = nil
  _fixing[buf] = nil
end

--- Enable render-markdown.nvim on a specific buffer, if available.
---
--- Registers the injection, forces a full treesitter re-parse to build
--- injection sub-trees, fixes regions for Neovim 0.11+, then defers
--- render-markdown's enable pass.
---@param buf integer
function M.enable_render_markdown(buf)
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then return end

  M._register_injection()

  -- Refresh cell cache so the predicate has up-to-date line mappings.
  cells.update_cache(buf)

  -- Patch the Python parser BEFORE the initial parse so that when the
  -- injection creates the bounding-box markdown child, our monkey-patch
  -- immediately fixes the regions — preventing stale markdown highlights
  -- from ever appearing on code cell lines.
  local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, "python")
  if ts_ok and parser then
    M._patch_parser(buf)
    parser:invalidate(true)
    parser:parse(true)  -- monkey-patch fires → _fix_markdown_regions runs
  end

  -- Defer enable so injection trees are populated before render pass.
  vim.defer_fn(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    -- Trigger render-markdown to attach to this buffer (it may have been
    -- skipped if the buffer opened before "python" was added to file_types).
    local mgr_ok, mgr = pcall(require, "render-markdown.core.manager")
    if mgr_ok and mgr.attach then
      pcall(mgr.attach, buf)
    end
    pcall(vim.api.nvim_buf_call, buf, function()
      pcall(render_md.enable)
    end)
  end, 100)
end

--- Disable render-markdown.nvim on a specific buffer.
---@param buf integer
function M.disable_render_markdown(buf)
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then return end
  pcall(vim.api.nvim_buf_call, buf, function()
    pcall(render_md.disable)
  end)
end

--- Plugin-level setup: register our markdown injection and ensure
--- render-markdown.nvim will process Python buffers.
---@param cfg table
function M.setup(cfg)
  vim.schedule(function()
    M._register_injection()

    -- Patch render-markdown state if available (for debug/consistency)
    local state_ok, rm_state = pcall(require, "render-markdown.state")
    if state_ok and rm_state.file_types then
      if not vim.tbl_contains(rm_state.file_types, "python") then
        table.insert(rm_state.file_types, "python")
      end
      if rm_state.injections then
        rm_state.injections.python = { enabled = true, query = M._injection_query }
      end
    end
  end)
end

return M
