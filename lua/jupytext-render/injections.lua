local M = {}

--- Enable render-markdown.nvim on a specific buffer, if available.
---
--- We force a full treesitter re-parse first so that our
--- queries/python/injections.scm (which may have just been added to the
--- runtimepath by lazy.nvim) is picked up before render-markdown reads the
--- treesitter tree.  A small defer then lets render-markdown run its render
--- pass after the injection sub-tree exists.
---@param buf integer
function M.enable_render_markdown(buf)
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then return end

  -- Step 1: force the Python parser to re-parse, building injection sub-trees
  -- (including the markdown injection from our queries/python/injections.scm).
  local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, "python")
  if ts_ok and parser then
    parser:parse(true)
  end

  -- Step 2: a short defer so the injection trees are fully populated before
  -- render-markdown's render pass reads them.
  vim.defer_fn(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    pcall(vim.api.nvim_buf_call, buf, function()
      pcall(render_md.enable)
    end)
  end, 80)
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

--- Plugin-level setup: ensure render-markdown.nvim will process Python buffers.
--- render-markdown ignores enable() calls on buffers whose filetype is not in
--- its configured file_types list (default: only "markdown").  We use
--- vim.schedule so this runs AFTER the user's own render-markdown.setup() call,
--- then read the live config to extend file_types rather than replace it.
---@param cfg table
function M.setup(cfg)
  vim.schedule(function()
    local ok, render_md = pcall(require, "render-markdown")
    if not ok then return end

    -- Try to read the current resolved file_types from render-markdown's state.
    local current_fts = { "markdown" }
    local state_ok, rm_state = pcall(require, "render-markdown.state")
    if state_ok and rm_state.config and rm_state.config.file_types then
      current_fts = rm_state.config.file_types
    end

    -- Only patch if Python is not already present (avoids redundant re-setup).
    if not vim.tbl_contains(current_fts, "python") then
      local new_fts = vim.list_extend(vim.deepcopy(current_fts), { "python" })
      pcall(render_md.setup, { file_types = new_fts })
    end
  end)
end

return M
