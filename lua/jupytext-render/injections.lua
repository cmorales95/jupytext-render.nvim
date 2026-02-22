local M = {}

--- Enable render-markdown.nvim on a specific buffer, if available.
--- Uses nvim_buf_call to ensure render-markdown's enable() runs in the
--- correct buffer context regardless of what the current buffer is.
---@param buf integer
function M.enable_render_markdown(buf)
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then return end
  pcall(vim.api.nvim_buf_call, buf, function()
    pcall(render_md.enable)
  end)
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

--- Plugin-level setup: nothing to do here since the treesitter injection
--- is registered automatically via queries/python/injections.scm.
---@param cfg table
function M.setup(cfg)
  -- no-op: TS injection is file-based (queries/python/injections.scm)
end

return M
