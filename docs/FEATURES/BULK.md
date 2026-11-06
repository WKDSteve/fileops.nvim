# Bulk operations

Operations that act on more than the current file: pattern-based batch renaming
with a preview step, and changing the working directory.

## Bulk rename

Batch-renames every regular file directly inside the current buffer's
directory (no recursion) whose name changes under a Lua-pattern
`gsub(pattern, replacement)` applied to the file name only. Files the
pattern doesn't match, or that `gsub` leaves unchanged, are excluded from
the plan. Split into a pure `plan()` (side-effect free — used by the test
suite to assert the plan without touching disk) and an `execute()` that
performs the renames; the command layer previews every `old → new` pair via
a notification, then confirms via `ui.kit.confirm` before touching disk. A
destination that exists already is marked in the preview and the dialog offers
to skip it (the first choice, where the dialog starts: the rest of the batch
still proceeds and the skip is reported), to overwrite it, or to cancel; `!`
drops the skip choice, and the dialog then starts on Cancel. Any open buffer pointing at a renamed file is
re-pointed at the new path (no reload, same as `move`).

- **Module:** `ops/bulk.lua` (`M.plan`, `M.execute`)
- **Usercmds:** `:File[!] bulk rename {pattern} {replacement}` — see
  [docs/commands.md](../commands.md#file-bulk-rename-pattern-replacement)

## Change directory (`:File cd`)

Sets the working directory to the current buffer's file's directory —
window-local (`:lcd`, default), tab-local (`:tcd`), or global (`:cd`) — then
refreshes any open file explorer (neo-tree, nvim-tree, netrw) so it tracks
the new root.

- **Module:** `ops/file.lua` (`M.cd_here`, `refresh_explorers`),
  `lua/fileops/init.lua` (`M.cd_here`)
- **Usercmds:** `:File cd [scope]` — see
  [docs/commands.md](../commands.md#file-cd-scope)
- **Config:** `opts.cd.scope` (default `"window"`),
  `opts.cd.refresh_explorers` (default `true`)

