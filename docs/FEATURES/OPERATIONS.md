# File operations

Creating, writing, renaming, moving, duplicating, copying and deleting a file —
the core lifecycle, plus the session bookkeeping that keeps a running
`:mksession` pointing at the right path afterwards.

## Create & write operations

`new`, `write`, `saveas`, `writeto`, `mkdir`, and `touch` cover every way to
put a file on disk without an existing source file to act on. `new` only sets
the buffer name (creates parent dirs, no write); `write` does the same and
writes immediately; `saveas` changes the buffer name and saves
(`:saveas`-equivalent); `writeto` writes a copy without changing the buffer's
name; `touch` creates an empty file with real `touch` semantics (an existing
file is left untouched, never truncated) and does not require or open a
buffer. All of them create missing parent directories automatically.

- **Module:** `ops/file.lua` (`M.edit_new`, `M.save_as`, `M.write_to`,
  `M.touch`, `M.ensure_parent`, `M.mk_parent`)
- **Usercmds:** `:File new`, `:File[!] write`, `:File[!] saveas`,
  `:File[!] writeto`, `:File mkdir`, `:File touch` — see
  [docs/commands.md](../commands.md)

## Rename & move

Renames or moves the current file on disk and re-points the buffer at the new
path, resolving a typed relative destination against the **current file's
directory** (so `:File rename NEW.md` renames in place). Unsaved changes are
written first. The only difference between the two: `rename` reloads the
buffer from disk afterwards (resetting signs/diagnostics), `move` leaves
buffer content and undo history untouched. Both are git-aware and
session-compat aware (see below) and retry a transient sharing violation.

- **Module:** `ops/file.lua` (`M.rename`, `M.move`, shared
  `move_or_rename` internal), `lua/fileops/init.lua` (`M.rename`, `M.move`)
- **Usercmds:** `:File[!] rename [%] [dest]`, `:File[!] move [%] [dest]` —
  see [docs/commands.md](../commands.md#file-rename--dest)
- **Config:** `opts.git_aware`, `opts.retry`, `opts.session_compat` (see
  [Configuration](../configuration.md))

## Duplicate & copy

Copies the current file to a new path via libuv. `duplicate` opens the copy
afterwards; `copy` is the silent counterpart (same validation and copy path,
just `opts.open` forced off). Both accept `!` to overwrite an existing
destination and share the same retry budget as rename/move.

- **Module:** `ops/file.lua` (`M.duplicate`, `M.copy`)
- **Usercmds:** `:File[!] duplicate [%] [dest]`, `:File[!] copy [%] [dest]`
  — see [docs/commands.md](../commands.md#file-duplicate--dest)
- **Config:** `opts.retry`, `opts.git_aware` (adds a tracked-source note to
  the result message only — duplicate/copy never run a git command)

## Delete (permanent or trash)

Deletes the current file from disk and closes its buffer, steering any window
showing that buffer onto an alternate listed buffer first so closing it
doesn't spawn an empty scratch buffer. Refuses on unsaved changes unless `!`
force-closes. `delete.mode = "trash"` sends the file to the OS trash/recycle
bin (`lib.nvim.fs.trash`) instead of a permanent `fs_unlink`.
`delete.on_before_delete` runs first and can abort the deletion by returning
`false`.

- **Module:** `ops/file.lua` (`M.delete_current`, `switch_windows_off`)
- **Usercmds:** `:File[!] delete [%]` — see
  [docs/commands.md](../commands.md#file-delete)
- **Config:** `opts.delete.mode` (default `"trash"`),
  `opts.delete.on_before_delete` (default `nil`)


## Session-compat resave

After `rename`/`move`, resaves the active `:mksession` session
(`v:this_session`) so it doesn't keep pointing at the stale path — a
no-op when no session is active. The session file must be passed explicitly
to `:mksession!`, since a bare `:mksession!` ignores `v:this_session` and
writes `./Session.vim` in the cwd instead. Other session managers
(possession.nvim, [sessions.nvim](https://github.com/WKDSteve/sessions.nvim))
can hook `User FileopsChanged` instead of relying on `v:this_session`.

- **Module:** `ops/file.lua` (inside `move_or_rename`)
- **Config:** `opts.session_compat.enable` (default `true`)

