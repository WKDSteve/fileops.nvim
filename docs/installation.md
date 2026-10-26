# Installation

## Requirements

- Neovim **0.9+**
- [lib.nvim](https://github.com/WKDSteve/lib.nvim) — **required**. Supplies
  the `:File` command layer (`lib.nvim.bindings.usercmd.composer`), notifications, the
  injection-safe file primitives behind create/rename/duplicate/delete
  (`lib.nvim.cross.fs.mutate`), and background buffer opening
- [ui.nvim](https://github.com/WKDSteve/ui.nvim) — **required**. `ui.kit`
  backs every prompt fileops has no other UI for — the missing-destination
  prompt (`:File rename/move/duplicate/copy/touch/new` with no argument), the
  modified-buffer confirm on `:File next`/`:File prev`, and `:File bulk
  rename` / the bulk-rename keymap — and `ui.contextmenu` backs the optional
  context-menu integration (`fileops.integrations.menu`). Lazily required, so
  nothing loads it until one of those runs, but there is no fallback: the
  default keymaps and several `:File` subcommands raise an error without it.

No CLI tools are required — all I/O goes through libuv directly, which is
what keeps behaviour identical on Windows and Unix.

### Optional

Each detected at runtime and degrading to nothing when absent:

| | |
| --- | --- |
| [filetree.nvim](https://github.com/WKDSteve/filetree.nvim), neo-tree, nvim-tree | Refreshed in place after a tree-changing operation |
| [which-key.nvim](https://github.com/folke/which-key.nvim) | Labels for the optional keymaps |
| [nvzone/menu](https://github.com/nvzone/menu) | A host for the context-menu entries — see [Integrations](FEATURES/INTEGRATIONS.md) |
| `git` | The two opt-in git features: the `on_hold` line-diff preview and `git_aware`. Every filesystem operation itself needs no CLI tool |
| [gitsuite.nvim](https://github.com/WKDSteve/gitsuite.nvim) | Refreshes explorers on a branch switch or conflict resolution (`gitsuite_events`, default on) — no dependency in either direction, these are plain `User` autocmds. Also backs `conflict_marks`' highlighting (exact marker-length matching, diff3/ambiguous-region awareness instead of fileops' own fixed patterns) and `on_hold`'s blame step (reuses its parser instead of fileops' own `git blame --porcelain`), both falling back to fileops' own implementation when it is absent |

`git` is declared in [install.json](install.json) and read by lib.nvim's
[deps module](https://github.com/WKDSteve/lib.nvim/blob/main/lua/lib/nvim/deps/README.md):
`:Lib deps show fileops.nvim` says what is missing and why it matters, and
`:Lib deps install fileops.nvim` offers to install it, asking first.

## Installation

### When to use which:

| Variant | Startup impact | When to use |
|---|---|---|
| `event = "VeryLazy"` | Minimal, after UI init | **Recommended** |
| `lazy = false` | Loads immediately | Small config, want it available instantly |

### lazy.nvim

```lua
{
  "WKDSteve/fileops.nvim",
  dependencies = { "WKDSteve/lib.nvim", "WKDSteve/ui.nvim" },
  event = "VeryLazy",
  opts = {},
}
```

`event = "VeryLazy"` rather than `cmd = "File"`: the `User FileopsChanged`
autocmd and the explorer refresh have to be live before the first operation,
not after it.

### packer.nvim / pckr.nvim

```lua
use({
  "WKDSteve/fileops.nvim",
  requires = { "WKDSteve/lib.nvim", "WKDSteve/ui.nvim" }, -- both required
  config = function()
    require("fileops").setup()
  end,
})
```

### vim-plug

```vim
Plug 'WKDSteve/lib.nvim'  " required
Plug 'WKDSteve/ui.nvim'   " required
Plug 'WKDSteve/fileops.nvim'
```
```lua
require("fileops").setup()
```

See [Configuration](configuration.md) for all available `setup()` options.
