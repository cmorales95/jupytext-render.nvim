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
--- Ensures the injection is registered, forces a full treesitter re-parse
--- to build injection sub-trees, then defers render-markdown's enable pass.
---@param buf integer
function M.enable_render_markdown(buf)
  local ok, render_md = pcall(require, "render-markdown")
  if not ok then return end

  -- Ensure injection is registered (may have been cleared by a later
  -- render-markdown setup() call or parser cache refresh).
  M._ensure_injection()

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
--- Patches render-markdown's state directly instead of re-calling setup()
--- (which would reset user config to defaults via resolve_config()).
---@param cfg table
function M.setup(cfg)
  vim.schedule(function()
    local ok = pcall(require, "render-markdown")
    if not ok then
      M._register_injection_fallback()
      return
    end

    local state_ok, rm_state = pcall(require, "render-markdown.state")
    if not state_ok or not rm_state.file_types then
      -- render-markdown not initialized yet; register injection directly
      M._register_injection_fallback()
      return
    end

    -- Patch state directly (avoids re-calling setup which resets user config)
    if not vim.tbl_contains(rm_state.file_types, "python") then
      table.insert(rm_state.file_types, "python")
    end
    rm_state.injections = rm_state.injections or {}
    rm_state.injections.python = { enabled = true, query = M._injection_query }

    -- Call ts.inject("python") which calls vim.treesitter.query.set() internally
    local ts_ok, rm_ts = pcall(require, "render-markdown.core.ts")
    if ts_ok and rm_ts.inject then
      rm_ts.inject("python")
    else
      M._register_injection_fallback()
    end
  end)
end

--- Check if the injection query is registered and re-register if missing.
function M._ensure_injection()
  local query_ok, query = pcall(vim.treesitter.query.get, "python", "injections")
  if query_ok and query then
    local source = query:source()
    if type(source) == "string" and source:find("injection.combined", 1, true) then
      return -- already registered
    end
  end
  -- Not registered; try render-markdown's ts.inject first, fall back to direct
  local ts_ok, rm_ts = pcall(require, "render-markdown.core.ts")
  if ts_ok and rm_ts.inject then
    -- Ensure state has our injection config
    local state_ok, rm_state = pcall(require, "render-markdown.state")
    if state_ok and rm_state.injections then
      rm_state.injections.python = { enabled = true, query = M._injection_query }
    end
    rm_ts.inject("python")
  else
    M._register_injection_fallback()
  end
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
