local M = {}

-- The treesitter injection query that turns Python comment lines into markdown.
-- Matches comments starting with "# " that are NOT cell markers (# %%).
-- The #offset! strips the leading "# " (2 chars) so render-markdown sees clean
-- markdown rather than Python comment syntax.
M._injection_query = [[
  ((comment) @injection.content
    (#lua-match? @injection.content "^# [^%%]")
    (#offset! @injection.content 0 2 0 0)
    (#set! injection.combined)
    (#set! injection.language "markdown"))
]]

--- Enable render-markdown.nvim on a specific buffer, if available.
---
--- We invalidate the treesitter query cache first so that the injection
--- registered by render-markdown's setup() (via vim.treesitter.query.set)
--- is picked up.  Then we force a full re-parse to build injection sub-trees.
--- A small defer lets render-markdown run its render pass after the injection
--- sub-tree exists.
---@param buf integer
function M.enable_render_markdown(buf)
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then return end

  -- Invalidate cached Python queries so treesitter picks up the
  -- injection registered by render-markdown's setup().
  pcall(vim.treesitter.query.invalidate, "python")

  -- Force full re-parse to build injection sub-trees.
  local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, "python")
  if ts_ok and parser then
    parser:invalidate(true)
    parser:parse(true)
  end

  -- Defer enable so injection trees are populated before render pass.
  vim.defer_fn(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
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
---
--- We use render-markdown's `injections` API which internally calls
--- vim.treesitter.query.set() — this bypasses the treesitter file cache
--- entirely, fixing the VeryLazy timing issue where the Python parser
--- caches injection queries before our plugin is on the runtimepath.
---@param cfg table
function M.setup(cfg)
  vim.schedule(function()
    local ok, render_md = pcall(require, "render-markdown")
    if not ok then
      -- Fallback: no render-markdown, register injection directly
      M._register_injection_fallback()
      return
    end

    local opts = {}

    -- Ensure Python is in file_types
    local current_fts = { "markdown" }
    local state_ok, rm_state = pcall(require, "render-markdown.state")
    if state_ok and rm_state.config and rm_state.config.file_types then
      current_fts = rm_state.config.file_types
    end
    if not vim.tbl_contains(current_fts, "python") then
      opts.file_types = vim.list_extend(vim.deepcopy(current_fts), { "python" })
    end

    -- Register our markdown injection via render-markdown's injections API.
    -- render-markdown calls vim.treesitter.query.set() internally, which
    -- bypasses the treesitter file cache — fixing the VeryLazy timing issue.
    opts.injections = {
      python = {
        enabled = true,
        query = M._injection_query,
      },
    }

    pcall(render_md.setup, opts)
  end)
end

--- Fallback when render-markdown.nvim is not installed.
--- Registers the injection directly via vim.treesitter.query so that
--- treesitter at least applies markdown syntax highlighting to comments.
function M._register_injection_fallback()
  -- Read any existing Python injection queries and append ours
  local existing = ""
  local read_ok, current = pcall(vim.treesitter.query.get, "python", "injections")
  if read_ok and current then
    existing = current:source()
    -- If our injection is already present, skip
    if existing:find("injection.combined", 1, true) then
      return
    end
    existing = existing .. "\n"
  end

  local full_query = existing .. "; extends\n" .. M._injection_query
  pcall(vim.treesitter.query.set, "python", "injections", full_query)
end

return M
