local M = {}

--- Treesitter injection query for Python jupytext markdown cells.
--- Matches comment nodes that are NOT cell markers (# %%) and injects
--- them as markdown so render-markdown.nvim can style them.
---
--- The `#offset!` predicate strips the leading "# " (2 chars) so that
--- render-markdown sees clean markdown text rather than Python comment syntax.
local INJECTION_QUERY = [[
  ((comment) @injection.content
    (#lua-match? @injection.content "^# [^%%]")
    (#offset! @injection.content 0 2 0 0)
    (#set! injection.combined)
    (#set! injection.language "markdown"))
]]

--- Try to add `python` to render-markdown.nvim's file_types and register
--- the treesitter injection that strips `# ` prefixes for clean rendering.
---@param cfg table  resolved config
function M.setup(cfg)
  if not cfg.render_markdown then
    return
  end

  -- Check render-markdown is available
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then
    return
  end

  -- Register the injection query for Python buffers via treesitter
  local ts_ok = pcall(function()
    vim.treesitter.query.set("python", "injections", INJECTION_QUERY)
  end)
  if not ts_ok then
    -- Fallback: try the older API
    pcall(function()
      require("vim.treesitter.query").set_query("python", "injections", INJECTION_QUERY)
    end)
  end

  -- Extend render-markdown to include python filetype
  -- We call setup() with extend = true to merge rather than replace
  local rm_cfg_ok, rm_cfg = pcall(require, "render-markdown.config")
  if rm_cfg_ok and rm_cfg then
    -- render-markdown 6.x API: use setup() with extend
    pcall(function()
      render_md.setup({
        file_types = { "markdown", "python" },
      })
    end)
  else
    -- Fallback: direct setup
    pcall(function()
      render_md.setup({
        file_types = { "markdown", "python" },
      })
    end)
  end
end

return M
