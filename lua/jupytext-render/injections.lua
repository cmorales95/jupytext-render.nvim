local M = {}

--- Enable render-markdown.nvim on a specific buffer, if available.
--- The treesitter injection (queries/python/injections.scm) handles
--- the language injection; this just activates render-markdown's rendering
--- engine for the given buffer.
---@param buf integer
function M.enable_render_markdown(buf)
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then return end
  pcall(render_md.enable, buf)
end

--- Disable render-markdown.nvim on a specific buffer.
---@param buf integer
function M.disable_render_markdown(buf)
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then return end
  pcall(render_md.disable, buf)
end

--- Plugin-level setup: nothing to do here since the treesitter injection
--- is registered automatically via queries/python/injections.scm.
---@param cfg table
function M.setup(cfg)
  -- no-op: TS injection is file-based (queries/python/injections.scm)
end

return M
