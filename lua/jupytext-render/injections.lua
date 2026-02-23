local M = {}

-- The treesitter injection query that turns Python comment lines into markdown.
-- Matches comments starting with "# " that are NOT cell markers (# %%).
-- The #offset! strips the leading "# " (2 chars) so render-markdown sees clean
-- markdown rather than Python comment syntax.
--
-- Each comment is injected as a SEPARATE markdown tree (no injection.combined).
-- Combined mode breaks block-level parsing (headings, lists) because the
-- column-2 offset + YAML front matter poisons the single combined document
-- into one giant paragraph. Per-line injection preserves block structure.
M._injection_query = [[
  ((comment) @injection.content
    (#lua-match? @injection.content "^# [^%%]")
    (#offset! @injection.content 0 2 0 0)
    (#set! injection.language "markdown"))
]]

--- Register the treesitter injection query for Python.
--- Uses ;; extends to merge with existing Python injection queries
--- from nvim-treesitter. Safe to call multiple times.
function M._register_injection()
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
