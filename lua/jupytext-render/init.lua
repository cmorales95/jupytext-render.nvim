local M = {}

local config     = require("jupytext-render.config")
local cells      = require("jupytext-render.cells")
local extmarks   = require("jupytext-render.extmarks")
local injections = require("jupytext-render.injections")
local navigation = require("jupytext-render.navigation")

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
  local buf  = vim.api.nvim_get_current_buf()
  local win  = vim.api.nvim_get_current_win()
  local name = vim.api.nvim_buf_get_name(buf)
  local ft   = vim.bo[buf].filetype
  local is_jt   = cells.is_jupytext(buf)
  local state   = _state[buf]
  local cfg_ok  = _cfg ~= nil
  local cl      = vim.wo[win].conceallevel
  local scanned = cells.scan(buf)
  local marks   = extmarks.mark_count(buf)
  local rm_ok   = pcall(require, "render-markdown")

  -- Check render-markdown file_types includes python
  local rm_has_python = false
  local state_ok, rm_state = pcall(require, "render-markdown.state")
  if state_ok then
    -- Check both state.file_types (patched directly) and state.config.file_types
    if rm_state.file_types then
      rm_has_python = vim.tbl_contains(rm_state.file_types, "python")
    elseif rm_state.config and rm_state.config.file_types then
      rm_has_python = vim.tbl_contains(rm_state.config.file_types, "python")
    end
  end

  -- Check treesitter parsers
  local ts_py = pcall(vim.treesitter.get_parser, buf, "python")
  local ts_md_ok, nvim_ts = pcall(require, "nvim-treesitter.parsers")
  local ts_md = ts_md_ok and nvim_ts.has_parser("markdown")

  -- Check injection query
  local inj_query_ok, inj_query = pcall(vim.treesitter.query.get, "python", "injections")
  local has_md_injection = false
  if inj_query_ok and inj_query then
    local src = inj_query:source()
    has_md_injection = type(src) == "string" and src:find("injection.combined", 1, true) ~= nil
  end

  -- Check parser has markdown children
  local has_md_children = false
  if ts_py then
    local p_ok, p = pcall(vim.treesitter.get_parser, buf, "python")
    if p_ok and p then
      local children = p:children()
      has_md_children = children and children["markdown"] ~= nil
    end
  end

  -- Check navigation keymaps
  local nj = vim.fn.maparg("]j", "n")
  local pj = vim.fn.maparg("[j", "n")

  local info = {
    "── jupytext-render debug ──",
    "buf:              " .. buf,
    "name:             " .. vim.fn.fnamemodify(name, ":t"),
    "filetype:         " .. ft,
    "is_jupytext:      " .. tostring(is_jt),
    "setup done:       " .. tostring(cfg_ok),
    "state:            " .. vim.inspect(state),
    "cells found:      " .. #scanned,
    "extmarks set:     " .. marks,
    "conceallevel:     " .. cl,
    "render-md:        " .. tostring(rm_ok),
    "render-md python: " .. tostring(rm_has_python)
      .. (rm_ok and not rm_has_python and " ← MISSING (run :JupytextRenderDebug after reopening)" or ""),
    "ts python parser: " .. tostring(ts_py),
    "ts markdown:      " .. tostring(ts_md),
    "inj query set:    " .. tostring(has_md_injection)
      .. (not has_md_injection and " ← MISSING" or ""),
    "inj md children:  " .. tostring(has_md_children)
      .. (not has_md_children and " ← MISSING" or ""),
    "keymap ]j:        " .. (nj ~= "" and "set" or "NOT SET"),
    "keymap [j:        " .. (pj ~= "" and "set" or "NOT SET"),
  }
  for i, c in ipairs(scanned) do
    table.insert(info, ("  cell[%d] type=%-8s lines %d-%d"):format(i, c.type, c.start, c.stop))
  end

  vim.notify(table.concat(info, "\n"), vim.log.levels.INFO, { title = "jupytext-render" })
end

function M.setup(user_opts)
  _cfg = config.merge(user_opts)

  define_highlights()
  injections.setup(_cfg)

  -- Apply molten output split settings if enabled
  if _cfg.molten and _cfg.molten.output_split then
    vim.g.molten_output_win_style = "split"
    vim.g.molten_split_direction = "right"
    vim.g.molten_split_size = 40
  end

  local nk = _cfg.keymaps or {}
  if nk.toggle and nk.toggle ~= "" then
    vim.keymap.set("n", nk.toggle, function()
      M.toggle()
    end, { desc = "Toggle jupytext markdown rendering", silent = true })
  end
  if nk.next_cell and nk.next_cell ~= "" then
    vim.keymap.set("n", nk.next_cell, function() navigation.goto_next() end,
      { desc = "Jump to next Jupyter cell", silent = true })
  end
  if nk.prev_cell and nk.prev_cell ~= "" then
    vim.keymap.set("n", nk.prev_cell, function() navigation.goto_prev() end,
      { desc = "Jump to previous Jupyter cell", silent = true })
  end

  -- molten-nvim integration keymaps
  local mk = _cfg.molten and _cfg.molten.keymaps or {}
  if mk.init_kernel and mk.init_kernel ~= "" then
    vim.keymap.set("n", mk.init_kernel, ":MoltenInit<CR>",
      { desc = "Initialize Jupyter kernel", silent = true })
  end
  if mk.show_output and mk.show_output ~= "" then
    vim.keymap.set("n", mk.show_output, ":MoltenShowOutput<CR>",
      { desc = "Show Jupyter cell output", silent = true })
  end
  if mk.run_line and mk.run_line ~= "" then
    vim.keymap.set("n", mk.run_line, ":MoltenEvaluateLine<CR>",
      { desc = "Run current line in Jupyter kernel", silent = true })
  end
  if mk.run_cell and mk.run_cell ~= "" then
    vim.keymap.set("n", mk.run_cell, function()
      local buf  = vim.api.nvim_get_current_buf()
      local cell = navigation.current_cell(buf)
      if not cell then
        vim.notify("jupytext-render: cursor is not inside a cell", vim.log.levels.WARN)
        return
      end
      if cell.type == "markdown" then
        vim.notify("jupytext-render: cannot run a markdown cell", vim.log.levels.WARN)
        return
      end
      -- cell.start is the # %% marker line (0-indexed); skip it.
      -- MoltenEvaluateRange uses 1-indexed line numbers.
      local first = cell.start + 2  -- skip marker, 1-indexed
      local last  = cell.stop  + 1  -- 1-indexed
      if first > last then return end
      vim.cmd(string.format("%d,%dMoltenEvaluateRange", first, last))
    end, { desc = "Run current Jupyter cell", silent = true })
  end
  if mk.run_all and mk.run_all ~= "" then
    vim.keymap.set("n", mk.run_all, function()
      local buf = vim.api.nvim_get_current_buf()
      for _, cell in ipairs(cells.scan(buf)) do
        if cell.type == "code" then
          local first = cell.start + 2
          local last  = cell.stop  + 1
          if first <= last then
            vim.cmd(string.format("%d,%dMoltenEvaluateRange", first, last))
          end
        end
      end
    end, { desc = "Run all Jupyter code cells", silent = true })
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
