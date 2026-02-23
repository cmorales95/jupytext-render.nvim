local M = {}

local cells = require("jupytext-render.cells")

-- The treesitter injection query that turns Python comment lines into markdown.
-- Uses injection.combined so multi-line constructs (tables, code blocks, bold)
-- are parsed as a single markdown document instead of separate per-line trees.
--
-- The custom predicate #is-in-markdown-cell? restricts injection to lines
-- inside markdown cells only, excluding YAML frontmatter and code cell comments
-- that would otherwise poison the combined document.
--
-- The #lua-match? "^# " excludes bare "#" lines (blank comment lines), which
-- act as paragraph breaks / gaps in the combined document.
M._injection_query = [[
  ((comment) @injection.content
    (#is-in-markdown-cell? @injection.content)
    (#lua-match? @injection.content "^# ")
    (#offset! @injection.content 0 2 0 0)
    (#set! injection.combined)
    (#set! injection.language "markdown"))
]]

local _predicate_registered = false

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

--- Enable render-markdown.nvim on a specific buffer, if available.
---
--- Registers the injection, forces a full treesitter re-parse to build
--- injection sub-trees, then defers render-markdown's enable pass.
---@param buf integer
function M.enable_render_markdown(buf)
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then return end

  M._register_injection()

  -- Refresh cell cache so the predicate has up-to-date line mappings.
  cells.update_cache(buf)

  -- Force full re-parse to build injection sub-trees.
  local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, "python")
  if ts_ok and parser then
    parser:invalidate(true)
    parser:parse(true)
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
