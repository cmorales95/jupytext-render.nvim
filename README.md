# jupytext-render.nvim

> VSCode-parity rendering for jupytext-style Python notebooks in Neovim.

Renders `# %% [markdown]` cells in `.py` hydrogen/jupytext files with:

- **Concealed `# ` prefix** — comment markers disappear, leaving clean markdown text
- **Background highlight** — markdown cells visually distinct from code cells
- **Cell borders** — top/bottom virtual-line separators
- **Full render-markdown.nvim integration** — headings, bold, tables, code blocks all render inside markdown cells
- **Zero-config** — works out of the box with sensible defaults

## Requirements

- Neovim ≥ 0.10
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) (optional, for rich markdown rendering)

## Installation

### lazy.nvim

```lua
{
  "cmorales95/jupytext-render.nvim",
  ft           = { "python" },
  dependencies = { "MeanderingProgrammer/render-markdown.nvim" },  -- optional
  opts         = {},   -- uses all defaults
},
```

### With custom options

```lua
{
  "cmorales95/jupytext-render.nvim",
  ft = { "python" },
  opts = {
    keymaps = { toggle = "<leader>mM" },
    border = {
      top    = "── markdown ──────────────────────",
      bottom = "──────────────────────────────────",
    },
    conceal_marker = true,
    auto_attach    = true,
  },
},
```

## Default Options

```lua
require("jupytext-render").setup({
  render_markdown = true,      -- integrate with render-markdown.nvim
  keymaps = {
    toggle = "<leader>mM",     -- toggle rendering in current buffer
  },
  highlights = {
    cell_bg = "JupytextMDCell",  -- background hl for markdown cell lines
    sep     = "JupytextMDSep",   -- color of border lines
  },
  border = {
    top    = "── markdown ──────────────────────",
    bottom = "──────────────────────────────────",
  },
  conceal_marker = true,  -- hide "# %% [markdown]" marker line
  auto_attach    = true,  -- attach automatically on BufReadPost/FileType
  debounce_ms    = 150,   -- re-render delay after text changes (ms)
})
```

## Highlight Groups

| Group | Default | Purpose |
|-------|---------|---------|
| `JupytextMDCell` | links to `CursorLine` | Background for markdown cell body lines |
| `JupytextMDSep`  | links to `Comment`    | Border lines and concealed marker |

Override in your colorscheme setup:

```lua
vim.api.nvim_set_hl(0, "JupytextMDCell", { bg = "#1e1e2e" })
vim.api.nvim_set_hl(0, "JupytextMDSep",  { fg = "#6c7086" })
```

## API

```lua
local jr = require("jupytext-render")

jr.setup(opts)      -- initialize with options
jr.enable(buf)      -- enable rendering for buffer (default: current)
jr.disable(buf)     -- disable rendering for buffer
jr.toggle(buf)      -- toggle rendering for buffer
```

## How It Works

jupytext Python files use `# %%` markers to delimit cells:

```python
# %% [markdown]
# # My Heading
# Some **bold** text and a table:
#
# | col A | col B |
# |-------|-------|
# | 1     | 2     |

# %%
def my_function():
    return 42
```

This plugin:

1. Scans for `# %%` markers using `vim.api.nvim_buf_get_lines`
2. For each markdown cell:
   - Places a virtual-line border above/below
   - Conceals the `# ` prefix from each comment line (extmarks with `conceal = ""`)
   - Applies a background highlight group across each line
3. Registers a treesitter injection that injects `markdown` grammar into those comment nodes (offset by 2 chars to strip `# `)
4. render-markdown.nvim then processes the injected markdown and renders headings, bold, tables, etc.

## Supported Cell Formats

| Marker | Detected as |
|--------|------------|
| `# %%` | code cell |
| `# %% [markdown]` | markdown cell |
| `# %% [md]` | markdown cell |
| `# In[N]:` | code cell (Jupyter classic) |

## License

MIT
