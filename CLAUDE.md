# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Neovim plugin (pure Lua, requires Neovim >= 0.10) that renders markdown cells inside jupytext-converted Jupyter notebooks. It's the visual layer between two other plugins: jupytext.nvim (`.ipynb` → Python conversion) and molten-nvim (cell execution). Optionally integrates with render-markdown.nvim for advanced markdown rendering (disabled by default due to Neovim 0.11 bounding-box issues).

## Development

No build step, test suite, or linting config. The plugin is tested manually by opening `.ipynb` files in Neovim. Use `:JupytextRenderDebug` to inspect buffer state, cell detection, extmark counts, render-markdown status, and treesitter parser availability.

Follows conventional commits (`feat:`, `fix:`, `docs:`) and semantic versioning.

## Architecture

### Rendering Pipeline

1. **Detection** (`cells.lua`) — scans buffer for `# %%` markers, returns `{start, stop, type}` tuples (0-indexed)
2. **Extmarks** (`extmarks.lua`) — the main rendering engine. Uses `virt_text_pos = "overlay"` to hide `# ` prefixes and cell markers, applies borders (virtual lines), background highlights, and renders markdown formatting natively:
   - **Headings** (H1–H6) with nerd-font icons and `@markup.heading.N.markdown` highlights
   - **Inline formatting**: `**bold**`, `*italic*`, `***bold italic***`, `` `code` `` with markers stripped
   - **Tables** with box-drawing characters (┌┬┐, │, ├┼┤, └┴┘), columns auto-sized to max content width
   - **Fenced code blocks** (` ```python `) with treesitter syntax highlighting via `vim.treesitter.get_string_parser()`
   - All in namespace `"jupytext_render"`, cleared and rebuilt on every render pass
3. **Treesitter Injection** (`injections.lua`) — optional, gated behind `render_markdown = true` config. Registers a treesitter injection query for markdown inside Python comments. Currently disabled by default because Neovim 0.11's `injection.combined` bounding-box bug causes visual artifacts on code cell lines when render-markdown.nvim sets `conceallevel=2`.

### Module Dependencies

```
init.lua (API, events, lifecycle)
├── config.lua     (defaults + merge)
├── cells.lua      (cell scanning)
├── extmarks.lua   (visual rendering) → cells.lua
├── injections.lua (TS injection + render-markdown bridge, optional)
└── navigation.lua (cell jump + current_cell) → cells.lua
```

### Rendering Approach

The plugin uses `virt_text_pos = "overlay"` instead of `conceallevel` to hide the `# ` Python comment prefix and cell markers. This avoids conflicts with render-markdown.nvim's `conceallevel=2` setting and the treesitter injection's `#offset!` directive, which together caused a column-gap artifact on code cell lines.

Multi-line constructs (tables, fenced code blocks) are rendered in a multi-pass approach in `render_md_body()`:
1. **Classify** — collect lines, detect code fences and table rows
2. **Syntax highlight** — parse fenced code blocks with `vim.treesitter.get_string_parser()` for the specified language
3. **Table blocks** — find contiguous table rows, compute max column widths, render with aligned box-drawing borders
4. **Render** — apply overlay extmarks per line with proper highlights

### Key Timing Constraints

The plugin typically loads lazily (`event = "VeryLazy"`) but the Python buffer opens earlier via jupytext. Two mechanisms handle this race:

- **200ms deferred scan** in `setup()` catches already-open buffers
- **`BufWinEnter` autocmd** re-applies extmarks when the buffer enters a new window

### Buffer State

All per-buffer state lives in `_state[buf]` (table in `init.lua`): `{enabled: bool, timer: uv_timer_t|nil}`. Cleaned up on `BufDelete`. Each attached buffer gets its own augroup (`JupytextRender_buf{N}`).

## Non-Obvious Details

- **`render_markdown` defaults to `false`** — the treesitter injection and render-markdown.nvim integration are disabled by default. Users can opt in with `render_markdown = true`, but this may cause visual artifacts on code cells in Neovim 0.11+.
- **Molten keymaps default to `""`** (disabled) to avoid overwriting user's existing molten bindings. Opt-in only.
- **`injections.lua` `setup()` uses `vim.treesitter.query.set()` directly** with `;; extends` to register the injection query, then patches render-markdown's state (`file_types`, `injections.python`) for consistency. Uses `vim.schedule` to run after the user's own render-markdown config.
- **Cell detection Lua patterns**: `^# %%%%` is the Lua literal for matching `# %%` (percent must be escaped).
- **`extmarks.render()` clears the entire namespace first** — no incremental updates, full rebuild each pass.
- **`run_cell` line math**: `cell.start` is 0-indexed marker line, so first executable line = `cell.start + 2` (skip marker + convert to 1-indexed) for `MoltenEvaluateRange`.
- **Code block syntax highlighting** uses `vim.treesitter.get_string_parser()` to parse code content as a standalone string, then maps highlight captures back to overlay virtual text segments. Supports language aliases (`py`→`python`, `js`→`javascript`, etc.). Falls back to plain text if the parser isn't installed.
- **Table alignment** computes max formatted width (after stripping inline markers) per column across all rows, then pads every cell to that width. Borders use the same widths for perfect alignment.
- **Highlight groups**: `JupytextMDCell` (cell bg), `JupytextMDSep` (borders), `JupytextBold`, `JupytextItalic`, `JupytextBoldItalic`, `JupytextCode`, `JupytextCodeBlock`, `JupytextCodeFence` — all customizable with `default = true`.
