# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Neovim plugin (pure Lua, requires Neovim >= 0.10) that renders markdown cells inside jupytext-converted Jupyter notebooks. It's the visual layer between three other plugins: jupytext.nvim (`.ipynb` → Python conversion), render-markdown.nvim (markdown formatting), and molten-nvim (cell execution).

## Development

No build step, test suite, or linting config. The plugin is tested manually by opening `.ipynb` files in Neovim. Use `:JupytextRenderDebug` to inspect buffer state, cell detection, extmark counts, render-markdown status, and treesitter parser availability.

Follows conventional commits (`feat:`, `fix:`, `docs:`) and semantic versioning.

## Architecture

### Rendering Pipeline

1. **Detection** (`cells.lua`) — scans buffer for `# %%` markers, returns `{start, stop, type}` tuples (0-indexed)
2. **Treesitter Injection** (`injections.lua`) — registers a treesitter query via render-markdown's `injections` API (which calls `vim.treesitter.query.set()` internally), injecting markdown language into Python comment nodes and stripping the `# ` prefix via `#offset! 0 2 0 0`. Falls back to direct `query.set()` if render-markdown is not installed.
3. **Extmarks** (`extmarks.lua`) — applies borders (virtual lines), conceals `# ` prefix and marker lines, sets background highlights per cell. All in namespace `"jupytext_render"`, cleared and rebuilt on every render pass.
4. **render-markdown.nvim** — reads the injected markdown sub-trees and renders headings, bold, tables, etc.

### Module Dependencies

```
init.lua (API, events, lifecycle)
├── config.lua     (defaults + merge)
├── cells.lua      (cell scanning)
├── extmarks.lua   (visual rendering) → cells.lua
├── injections.lua (TS injection + render-markdown bridge)
└── navigation.lua (cell jump + current_cell) → cells.lua
```

### Key Timing Constraints

The plugin typically loads lazily (`event = "VeryLazy"`) but the Python buffer opens earlier via jupytext. Three mechanisms handle this race:

- **200ms deferred scan** in `setup()` catches already-open buffers
- **`vim.treesitter.query.invalidate("python")`** in `enable_render_markdown()` clears the cached query so treesitter picks up the injection registered by render-markdown's `setup()`. Followed by `parser:invalidate(true)` + `parser:parse(true)` for a full re-parse.
- **100ms defer** before `render_md.enable()` lets injection sub-trees populate first

### Buffer State

All per-buffer state lives in `_state[buf]` (table in `init.lua`): `{enabled: bool, timer: uv_timer_t|nil}`. Cleaned up on `BufDelete`. Each attached buffer gets its own augroup (`JupytextRender_buf{N}`).

### Conceallevel

Must be set to `2` on ALL windows showing the buffer (not just current). `BufWinEnter` re-applies it when the buffer enters a new window.

## Non-Obvious Details

- **Molten keymaps default to `""`** (disabled) to avoid overwriting user's existing molten bindings. Opt-in only.
- **`injections.lua` `setup()` uses render-markdown's `injections` API** to register the treesitter query (bypassing the file cache), and auto-patches `file_types` to include `"python"` if missing. Uses `vim.schedule` to run after the user's own render-markdown config. If render-markdown is absent, falls back to `vim.treesitter.query.set()` directly.
- **`queries/python/injections.scm` was removed** — the injection is now registered programmatically to avoid double-injection issues and the VeryLazy file-cache timing bug.
- **Cell detection Lua patterns**: `^# %%%%` is the Lua literal for matching `# %%` (percent must be escaped).
- **`extmarks.render()` clears the entire namespace first** — no incremental updates, full rebuild each pass.
- **`run_cell` line math**: `cell.start` is 0-indexed marker line, so first executable line = `cell.start + 2` (skip marker + convert to 1-indexed) for `MoltenEvaluateRange`.
