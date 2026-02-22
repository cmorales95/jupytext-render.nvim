local M = {}

local config     = require("jupytext-render.config")
local cells      = require("jupytext-render.cells")
local extmarks   = require("jupytext-render.extmarks")
local injections = require("jupytext-render.injections")

-- Resolved config (set on setup())
local _cfg = nil

-- Per-buffer state: { [buf] = { enabled=bool, timer=uv_timer|nil } }
local _state = {}

--- Define default highlight groups (overridable by colorscheme).
local function define_highlights()
  vim.api.nvim_set_hl(0, "JupytextMDCell", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "JupytextMDSep",  { link = "Comment",    default = true })
end

--- Cancel any pending debounce timer for a buffer.
---@param buf integer
local function cancel_timer(buf)
  local s = _state[buf]
  if s and s.timer then
    s.timer:stop()
    s.timer:close()
    s.timer = nil
  end
end

--- Schedule a debounced render for the buffer.
---@param buf integer
local function debounced_render(buf)
  if not _state[buf] or not _state[buf].enabled then return end
  cancel_timer(buf)
  local timer = vim.uv and vim.uv.new_timer() or vim.loop.new_timer()
  _state[buf].timer = timer
  timer:start(_cfg.debounce_ms, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(buf) and _state[buf] and _state[buf].enabled then
      extmarks.render(buf, _cfg)
    end
    if _state[buf] then _state[buf].timer = nil end
  end))
end

--- Subscribe TextChanged events for live re-render.
---@param buf integer
local function subscribe_text_events(buf)
  local group = vim.api.nvim_create_augroup("JupytextRender_buf" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer  = buf,
    group   = group,
    callback = function() debounced_render(buf) end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer  = buf,
    group   = group,
    callback = function()
      if _state[buf] and _state[buf].enabled then
        extmarks.render(buf, _cfg)
      end
    end,
  })
  -- Clean up state when buffer is deleted
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer  = buf,
    group   = group,
    once    = true,
    callback = function()
      cancel_timer(buf)
      _state[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_name, "JupytextRender_buf" .. buf)
    end,
  })
end

--- Try to attach rendering to a buffer (guards: filetype=python, has # %% markers).
---@param buf integer
local function try_attach(buf)
  if not _cfg or not _cfg.auto_attach then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].filetype ~= "python" then return end
  if not cells.is_jupytext(buf) then return end
  -- Already attached?
  if _state[buf] then return end

  _state[buf] = { enabled = true, timer = nil }
  extmarks.render(buf, _cfg)
  injections.enable_render_markdown(buf)
  subscribe_text_events(buf)
end

--- Enable rendering for a buffer.
---@param buf? integer  defaults to current buffer
function M.enable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not _state[buf] then
    _state[buf] = { enabled = false, timer = nil }
    subscribe_text_events(buf)
  end
  _state[buf].enabled = true
  extmarks.render(buf, _cfg)
  injections.enable_render_markdown(buf)
end

--- Disable rendering for a buffer.
---@param buf? integer  defaults to current buffer
function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  cancel_timer(buf)
  if _state[buf] then _state[buf].enabled = false end
  extmarks.clear(buf)
  injections.disable_render_markdown(buf)
end

--- Toggle rendering for a buffer.
---@param buf? integer  defaults to current buffer
function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if _state[buf] and _state[buf].enabled then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

--- Main setup entry point.
---@param user_opts table|nil
function M.setup(user_opts)
  _cfg = config.merge(user_opts)

  define_highlights()
  injections.setup(_cfg)

  -- Register toggle keymap if configured
  if _cfg.keymaps and _cfg.keymaps.toggle and _cfg.keymaps.toggle ~= "" then
    vim.keymap.set("n", _cfg.keymaps.toggle, function()
      M.toggle()
    end, { desc = "Toggle jupytext markdown rendering", silent = true })
  end

  -- Auto-attach autocmds
  if _cfg.auto_attach then
    local group = vim.api.nvim_create_augroup("JupytextRender", { clear = true })

    vim.api.nvim_create_autocmd({ "BufReadPost", "FileType" }, {
      group   = group,
      pattern = "*.py",
      callback = function(ev)
        -- Defer slightly so filetype detection has run
        vim.defer_fn(function() try_attach(ev.buf) end, 0)
      end,
    })

    -- Also attach to already-open python buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].filetype == "python" then
        vim.defer_fn(function() try_attach(buf) end, 0)
      end
    end
  end
end

return M
