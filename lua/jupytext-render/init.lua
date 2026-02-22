local M = {}

local config     = require("jupytext-render.config")
local cells      = require("jupytext-render.cells")
local extmarks   = require("jupytext-render.extmarks")
local injections = require("jupytext-render.injections")

local _cfg   = nil
local _state = {}

local function define_highlights()
  vim.api.nvim_set_hl(0, "JupytextMDCell", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "JupytextMDSep",  { link = "Comment",    default = true })
end

local function cancel_timer(buf)
  local s = _state[buf]
  if s and s.timer then
    s.timer:stop()
    s.timer:close()
    s.timer = nil
  end
end

local function debounced_render(buf)
  if not _state[buf] or not _state[buf].enabled then return end
  cancel_timer(buf)
  local timer = (vim.uv or vim.loop).new_timer()
  _state[buf].timer = timer
  timer:start(_cfg.debounce_ms, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(buf) and _state[buf] and _state[buf].enabled then
      extmarks.render(buf, _cfg)
    end
    if _state[buf] then _state[buf].timer = nil end
  end))
end

local function subscribe_text_events(buf)
  local group = vim.api.nvim_create_augroup("JupytextRender_buf" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer   = buf,
    group    = group,
    callback = function() debounced_render(buf) end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer   = buf,
    group    = group,
    callback = function()
      if _state[buf] and _state[buf].enabled then
        extmarks.render(buf, _cfg)
      end
    end,
  })
  -- Re-apply conceallevel whenever the buffer enters a new window
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer   = buf,
    group    = group,
    callback = function()
      if _state[buf] and _state[buf].enabled then
        extmarks.render(buf, _cfg)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer   = buf,
    group    = group,
    once     = true,
    callback = function()
      cancel_timer(buf)
      _state[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_name, "JupytextRender_buf" .. buf)
    end,
  })
end

local function try_attach(buf)
  if not _cfg or not _cfg.auto_attach then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].filetype ~= "python" then return end
  if not cells.is_jupytext(buf) then return end
  if _state[buf] then return end -- already attached

  _state[buf] = { enabled = true, timer = nil }
  extmarks.render(buf, _cfg)
  injections.enable_render_markdown(buf)
  subscribe_text_events(buf)
end

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

function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  cancel_timer(buf)
  if _state[buf] then _state[buf].enabled = false end
  extmarks.clear(buf)
  injections.disable_render_markdown(buf)
end

function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if _state[buf] and _state[buf].enabled then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

--- Print diagnostic info for the current buffer.
function M.debug()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local ft   = vim.bo[buf].filetype
  local loaded = vim.api.nvim_buf_is_loaded(buf)
  local is_jt  = cells.is_jupytext(buf)
  local state  = _state[buf]
  local cfg_ok = _cfg ~= nil

  local lines = vim.api.nvim_buf_get_lines(buf, 0, 4, false)

  local info = {
    "── jupytext-render debug ──",
    "buf:        " .. buf,
    "name:       " .. name,
    "filetype:   " .. ft,
    "loaded:     " .. tostring(loaded),
    "is_jupytext:" .. tostring(is_jt),
    "setup done: " .. tostring(cfg_ok),
    "state:      " .. vim.inspect(state),
    "first 4 lines:",
  }
  for i, l in ipairs(lines) do
    table.insert(info, "  [" .. i .. "] " .. l)
  end

  -- Check render-markdown
  local rm_ok, _ = pcall(require, "render-markdown")
  table.insert(info, "render-markdown available: " .. tostring(rm_ok))

  vim.notify(table.concat(info, "\n"), vim.log.levels.INFO, { title = "jupytext-render" })
end

function M.setup(user_opts)
  _cfg = config.merge(user_opts)

  define_highlights()
  injections.setup(_cfg)

  if _cfg.keymaps and _cfg.keymaps.toggle and _cfg.keymaps.toggle ~= "" then
    vim.keymap.set("n", _cfg.keymaps.toggle, function()
      M.toggle()
    end, { desc = "Toggle jupytext markdown rendering", silent = true })
  end

  vim.api.nvim_create_user_command("JupytextRenderDebug", function() M.debug() end,
    { desc = "Print jupytext-render diagnostic info for current buffer" })

  if _cfg.auto_attach then
    local group = vim.api.nvim_create_augroup("JupytextRender", { clear = true })

    -- .py files opened directly
    vim.api.nvim_create_autocmd("BufReadPost", {
      group   = group,
      pattern = "*.py",
      callback = function(ev)
        vim.schedule(function() try_attach(ev.buf) end)
      end,
    })

    -- any buffer that becomes python filetype (includes jupytext .ipynb conversion)
    vim.api.nvim_create_autocmd("FileType", {
      group   = group,
      pattern = "python",
      callback = function(ev)
        vim.schedule(function() try_attach(ev.buf) end)
      end,
    })

    -- catch buffers already open when plugin loads (e.g. session restore)
    -- use a small delay so jupytext's async conversion has time to finish
    vim.defer_fn(function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "python" then
          try_attach(buf)
        end
      end
    end, 200)
  end
end

return M
