local M = {}

M.defaults = {
  render_markdown = true,
  keymaps = {
    toggle    = "<leader>mM",
    next_cell = "]j",
    prev_cell = "[j",
  },
  highlights = {
    cell_bg = "JupytextMDCell",
    sep     = "JupytextMDSep",
  },
  border = {
    top      = "── markdown ──────────────────────",
    bottom   = "──────────────────────────────────",
    code_top = "── code ──────────────────────────",
  },
  conceal_marker = true,
  auto_attach    = true,
  debounce_ms    = 150,
  -- molten-nvim integration keymaps.
  -- All default to "" (disabled) to avoid conflicting with keymaps you may
  -- already have in your own config.  Set any key to a binding to enable it.
  molten = {
    keymaps = {
      init_kernel  = "",
      run_cell     = "",
      run_line     = "",
      show_output  = "",
      run_all      = "",
    },
  },
}

--- Merge user opts into defaults (shallow merge of top-level keys, deep for nested)
---@param user_opts table|nil
---@return table
function M.merge(user_opts)
  if not user_opts then
    return vim.deepcopy(M.defaults)
  end
  local cfg = vim.deepcopy(M.defaults)
  for k, v in pairs(user_opts) do
    if type(v) == "table" and type(cfg[k]) == "table" then
      cfg[k] = vim.tbl_deep_extend("force", cfg[k], v)
    else
      cfg[k] = v
    end
  end
  return cfg
end

return M
