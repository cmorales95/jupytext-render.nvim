# jupytext-render.nvim

> VSCode-parity rendering for jupytext-style Python notebooks in Neovim.

Renders `# %% [markdown]` cells in `.py` hydrogen/jupytext files with:

- **Concealed `# ` prefix** — comment markers disappear, leaving clean markdown text
- **Background highlight** — markdown cells visually distinct from code cells
- **Cell borders** — top/bottom virtual-line separators
- **Full render-markdown.nvim integration** — headings, bold, tables, code blocks all render inside markdown cells
- **Zero-config** — works out of the box with sensible defaults

---

## Requirements

- Neovim ≥ 0.10
- [molten-nvim](https://github.com/benlubas/molten-nvim) — kernel execution engine
- [jupytext.nvim](https://github.com/GCBallesteros/jupytext.nvim) — `.ipynb` ↔ `.py` conversion
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) (optional, for rich markdown rendering)

### System prerequisites

```sh
# Python venv with Jupyter dependencies
uv venv ~/.venvs/nvim --python 3.12
uv pip install --python ~/.venvs/nvim/bin/python pynvim jupyter_client ipykernel jupytext

# Inline images (optional, kitty terminal only)
brew install imagemagick
luarocks --lua-version 5.1 install magick
```

---

## Installation

### lazy.nvim (minimal)

```lua
{
  "cmorales95/jupytext-render.nvim",
  event        = "VeryLazy",
  dependencies = { "MeanderingProgrammer/render-markdown.nvim" },  -- optional
  opts         = {},
},
```

> **Note:** Use `event = "VeryLazy"` rather than `ft = { "python" }`. Lazy-loading on
> filetype causes a race condition: when a `.ipynb` file is opened via jupytext.nvim,
> the `FileType python` event fires before this plugin has loaded, so the first buffer
> is never rendered. `VeryLazy` loads the plugin shortly after startup and the
> "already-open buffers" scan in `setup()` catches any buffers that opened first.

### Recommended full setup (with molten + jupytext)

```lua
-- 1. Kernel execution
{
  "benlubas/molten-nvim",
  version      = "^1.0.0",
  build        = ":UpdateRemotePlugins",
  ft           = { "python" },
  dependencies = { "3rd/image.nvim" },   -- for inline images (kitty only)
  init = function()
    vim.g.molten_auto_open_output      = true
    vim.g.molten_output_win_max_height = 20
    vim.g.molten_wrap_output           = true
    vim.g.molten_virt_text_output      = true
  end,
},

-- 2. .ipynb ↔ Python conversion
{
  "GCBallesteros/jupytext.nvim",
  lazy   = false,
  opts   = { style = "hydrogen", output_extension = "auto", force_ft = "python" },
},

-- 3. Markdown cell rendering (this plugin)
{
  "cmorales95/jupytext-render.nvim",
  ft           = { "python" },
  dependencies = { "MeanderingProgrammer/render-markdown.nvim" },
  opts = {
    keymaps = { toggle = "<leader>mM" },
  },
},
```

---

## Usage

### Opening a notebook

| Action | Result |
|--------|--------|
| `:e mynotebook.ipynb` | jupytext.nvim auto-converts to Python `# %%` format |
| `:e mynotebook.py` (hydrogen file) | opens directly; rendering attaches automatically |

Markdown cells render immediately on open. No manual step needed.

### Running cells

These keymaps work with **molten-nvim** (set up separately):

| Key | Mode | Action |
|-----|------|--------|
| `<leader>mi` | Normal | Init / select a Jupyter kernel |
| `<leader>mr` | Normal | Run the cell under the cursor |
| `<leader>mr` | Visual | Run the selected lines |
| `<leader>ml` | Normal | Run current line only |
| `<leader>mo` | Normal | Show output window for current cell |
| `<leader>mR` | Normal | Re-run **all** cells in the buffer |
| `<leader>mA` | Normal | Run all cells from top to bottom |
| `<leader>mM` | Normal | Toggle markdown rendering on/off |

> **Tip:** A kernel is required to run cells. If you have a `.venv` in your project directory,
> molten-nvim will auto-detect and init the matching kernel on file open.

### Workflow example

```
1. :e analysis.ipynb          → opens as Python # %% cells, markdown renders automatically
2. <leader>mi                 → pick kernel (or auto-inited from .venv)
3. Navigate to a code cell
4. <leader>mr                 → run cell, output appears inline below
5. <leader>mR                 → re-run everything after edits
6. :w                         → saves .py; jupytext.nvim writes back to .ipynb
```

---

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

---

## Highlight Groups

| Group | Default | Purpose |
|-------|---------|---------|
| `JupytextMDCell` | links to `CursorLine` | Background for markdown cell body lines |
| `JupytextMDSep`  | links to `Comment`    | Border lines and concealed marker |

Override after your colorscheme loads:

```lua
vim.api.nvim_set_hl(0, "JupytextMDCell", { bg = "#1e1e2e" })
vim.api.nvim_set_hl(0, "JupytextMDSep",  { fg = "#6c7086" })
```

---

## API

```lua
local jr = require("jupytext-render")

jr.setup(opts)      -- initialize with options
jr.enable(buf)      -- enable rendering for buffer (default: current)
jr.disable(buf)     -- disable rendering for buffer
jr.toggle(buf)      -- toggle rendering for buffer
```

---

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
import pandas as pd

df = pd.read_csv("data.csv")
df.head()
```

This plugin:

1. Scans for `# %%` markers using `vim.api.nvim_buf_get_lines`
2. For each markdown cell:
   - Places a virtual-line border above/below
   - Conceals the `# ` prefix from each comment line (extmarks with `conceal = ""`)
   - Applies a background highlight group across each line
3. Registers a treesitter injection that injects `markdown` grammar into those comment nodes (offset by 2 chars to strip `# `)
4. render-markdown.nvim then processes the injected markdown and renders headings, bold, tables, etc.

---

## Supported Cell Formats

| Marker | Detected as |
|--------|------------|
| `# %%` | code cell |
| `# %% [markdown]` | markdown cell |
| `# %% [md]` | markdown cell |
| `# In[N]:` | code cell (Jupyter classic) |

---

## License

MIT
