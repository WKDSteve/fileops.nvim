# Bindings cheatsheet

Every keymap, user command, and autocommand `fileops.nvim` defines. Kept in
sync with `lua/fileops/bindings/`.

## Keymaps

Registered by `require("fileops").setup()`; `keymaps = false` (or
`keymaps = { enable = false }`) binds none of them. Otherwise gated by
`config.keymaps.cycle` / `config.keymaps.delete` (master switches) and
`config.keymaps.lhs.*` (per-key, set to `false` to disable or a string to
remap). See [`bindings/keymaps.lua`](../lua/fileops/bindings/keymaps.lua).

| Key | `lhs` config key | Mode | Action |
|---|---|---|---|
| `<leader>nf` | `next_replace` | n | Next file (replace) |
| `<leader>pf` | `prev_replace` | n | Previous file (replace) |
| `<leader>nfn` | `next_current` | n | Next file (stay listed) |
| `<leader>pfn` | `prev_current` | n | Previous file (stay listed) |
| `<leader>nF` | `next_background` | n | Next file (background) |
| `<leader>pF` | `prev_background` | n | Previous file (background) |
| `<leader>NF` | `next_vsplit` | n | Next file (vsplit) |
| `<leader>PF` | `prev_vsplit` | n | Previous file (vsplit) |
| `<leader>dcf` | `delete` | n | Delete current file + close buffer |

### Unset by default (2026-08-24)

These actions were reachable only as `:File …` subcommands. Making a keymap
*possible* is a different thing from claiming a key for it, so none of them
is bound unless you name an `lhs`:

| `lhs` config key | Mode | Action |
| --- | --- | --- |
| `next_filtered` / `prev_filtered` | n | Prompt for a glob, then cycle within it (`:File next *.lua` as a key) |
| `delete_force` | n | Delete + force-close even with unsaved changes — the `:File! delete` form |
| `path` | n | Copy the current path to the clipboard |
| `cd` | n | `cd` to the current file's directory |
| `info` | n | Show file info |
| `lockinfo` | n | Diagnose which process locks this file |
| `bulk_rename` | n | Bulk rename in this directory (prompts for pattern, then replacement) |

The prompting ones prompt because a bare keypress carries no argument: a glob
for the filtered cycle, a pattern and a replacement for the bulk rename. The
filtered cycle remembers the last glob for the session, so walking a `*.lua`
set does not mean retyping it at every step, and it still honours a count.

All cycle keymaps respect `v:count1`.

## Context Menu (optional)

`fileops.integrations.menu` contributes entries in the shape
[nvzone/menu](https://github.com/nvzone/menu) expects — Rename file…,
Duplicate file…, Delete file, Copy path, Show file info, Next/Previous file
in directory — all acting on the current buffer's file, the same target
every `:File <subcommand>` acts on. Each entry just runs the equivalent
`:File <subcommand>` with no arguments, so options (git-aware flags, retry,
refresh-explorers, delete confirmation mode, …) and destination prompting
stay identical to running the command directly — see
[`bindings/usrcmds.lua`](../lua/fileops/bindings/usrcmds.lua). Entries
needing a real file are omitted on an unnamed buffer.

fileops.nvim has **no** dependency on `menu` and never opens a context menu
itself — a host (typically your own `<RightMouse>` dispatcher) has to
compose these entries into its own menu:

`integrations = { ui_menu = false }` keeps ui.nvim's right-click menu (`ui.menu`)
from showing the fly-out while `items()`/`submenu()` keep working for any other
host; the module also answers `enabled()`, which is what `ui.menu` asks first.

```lua
local items = require("fileops.integrations.menu").items()  -- current buffer
local sub = require("fileops.integrations.menu").submenu()  -- { name = "  File", items = {…} } | nil
```

## User commands

Registered by [`bindings/usrcmds.lua`](../lua/fileops/bindings/usrcmds.lua),
gated by `config.commands` (a single boolean — there is only one command).

| Command | Args | Description |
|---|---|---|
| `:File new` | `[path]` | Set buffer name (creates parent dirs, no write) |
| `:File[!] write` | `[path]` | Set buffer name and write to disk |
| `:File save` | | `:write`; a [No Name] buffer asks for name + folder |
| `:File[!] saveas` | `[path]` | Save-as, buffer name changes |
| `:File[!] writeto` | `[path]` | Write a copy, buffer name stays |
| `:File mkdir` | — | Create parent dirs for current buffer |
| `:File touch` | `[path]` | Create an empty file if it doesn't exist yet |
| `:File[!] rename` | `[%] [dest]` | Rename file on disk + update buffer (reloads) |
| `:File[!] move` | `[%] [dest]` | Move file on disk + update buffer (no reload) |
| `:File[!] duplicate` | `[%] [dest]` | Copy file to new path and open the copy |
| `:File[!] copy` | `[%] [dest]` | Copy file to new path without opening it |
| `:File[!] delete` | `[%]` | Delete file from disk and close buffer |
| `:[count]File[!] next` | `[target] [glob]` | Next file in directory, optionally filtered (e.g. `*.lua`) |
| `:[count]File[!] prev` | `[target] [glob]` | Previous file in directory, optionally filtered |
| `:File[!] first` | `[target]` | Jump to the first file in directory |
| `:File[!] last` | `[target]` | Jump to the last file in directory |
| `:File[!] open` | `[target]` | Reopen the current file in a different window target |
| `:File path` | `[mode]` | Copy the current file's path to the clipboard (abs/rel/name/dir) |
| `:File info` | — | Show size/mtime/permissions for the current file |
| `:File[!] bulk rename` | `{pattern} {replacement}` | Batch-rename files in the directory via a Lua pattern (preview + confirm) |
| `:File cd` | `[scope]` | Set cwd to buffer's dir + refresh file explorer |
| `:File help` | — | Show a short usage overview in the command line |

Full reference: [commands.md](commands.md)
or `:h fileops-command`.

## Autocommands

Registered by [`bindings/autocmds.lua`](../lua/fileops/bindings/autocmds.lua),
gated by `config.auto_mkdir.enable` / `config.on_hold.enable` /
`config.conflict_marks.enable`.

| Event | augroup | Action | gated by |
|---|---|---|---|
| `BufWritePre` | `fileops_auto_mkdir` | Create parent directories for the file about to be written (same logic as `:File mkdir`) | `auto_mkdir.enable` |
| `CursorHold`/`CursorHoldI` | `fileops_on_hold_preview` | Preview what changed on the current line (gitsigns inline preview, or previous-content fallback) | `on_hold.enable` |
| `ModeChanged` | `fileops_on_hold_modeclear` | Clear/abort the line-diff preview when leaving an allowed mode | `on_hold.enable` |
| `CursorMoved`/`BufHidden`/`InsertEnter` (once, buffer-local) | `fileops_on_hold_cleanup` | Clear the line-diff preview on next move | `on_hold.enable` |
| `BufWinEnter` | `fileops_conflict_marks_on` | Highlight Git conflict markers (`<<<<<<<`/`=======`/`>>>>>>>`) | `conflict_marks.enable` |
| `BufWinLeave` | `fileops_conflict_marks_off` | Clear conflict marker highlights | `conflict_marks.enable` |

`config.auto_mkdir.skip_remote` (default `true`) skips buffers whose name
matches `config.auto_mkdir.detect_remote_pattern` (e.g. `ssh://`, `http://`).

Every tree-changing op (new/write/saveas/writeto/mkdir/touch/rename/move/
duplicate/copy/delete) also fires a `User FileopsChanged` autocmd
(`{action, path}`), unconditionally — see
[Autocommands § User FileopsChanged](autocommands.md#user-fileopschanged).
`rename`/`move` additionally resave the active `:mksession` session by
default (`config.session_compat.enable`).

## Which-key groups

| Prefix | Group label |
|---|---|
| `<leader>n` | fileops: next file |
| `<leader>p` | fileops: prev file |
