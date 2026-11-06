# Command reference

```
:File[!] {subcommand} [args…]
```

`!` overrides safety checks (existing-file guard, modified-buffer confirm).
`%` is an optional explicit "current file" scope — always implied when omitted.

Every `{path}`/`{dest}` argument below is itself optional: omit it and the
command opens a `vim.ui.input` prompt instead of erroring. Cancelling the
prompt (`<Esc>` or an empty answer) is a silent no-op, same as `vim.ui.input`.
`:File rename` (no `{dest}`) pre-fills the prompt with the current file's
name so you edit it in place instead of retyping it.

Tab-completion for these arguments is relative to the **current buffer's
directory**, not Neovim's cwd — `:File rename <Tab>` browses files next to
the one you're editing. Input starting with `~`, `/`, or a Windows drive
letter is left alone (treated as already absolute).

For `rename`/`move`/`duplicate`/`copy`, a **typed** relative destination is
resolved the same way: against the current file's directory, so
`:File rename NEW.md` renames in place instead of dropping the file into
Neovim's cwd. The create commands (`new`/`write`/`saveas`/`writeto`/`touch`)
still resolve relative paths against the cwd, like Vim's own `:write`.

`rename`/`move`/`duplicate`/`copy`/`delete` are git-aware when
`git_aware.enable = true` (opt-in — see [Configuration](configuration.md)):
by default they just note in the result message that the file is tracked;
with `git_aware.warn_only = false`, rename/move use `git mv` and delete uses
`git rm` instead of a plain filesystem op, so the git index stays in sync.

`rename`/`move` also resave the active `:mksession` session (`v:this_session`)
by default (`session_compat.enable`, see [Configuration](configuration.md)),
so it doesn't keep pointing at the old path. A no-op when no session is
active.

## `:File new [path]`

Set the current buffer's file name to `{path}`. Creates parent directories.
Does **not** write the buffer to disk.

```
:File new lua/mymodule/init.lua
```

## `:File[!] write [path]`

Like `new` but also writes the buffer to disk immediately. `!` overwrites an
existing file (`:write!`).

## `:File[!] saveas [path]`

Save the buffer under `{path}` (`:saveas`-equivalent). Buffer name changes.
`!` overwrites an existing file.

## `:File[!] writeto [path]`

Write a copy of the buffer to `{path}` without changing the buffer's name.
`!` overwrites an existing file.

## `:File mkdir`

Create the parent directory hierarchy for the current buffer's file. This
runs automatically before every save too — see [Autocommands](autocommands.md).

## `:File touch [path]`

Create an empty file at `{path}` if it doesn't already exist yet (creates
parent directories). Real `touch` semantics: an existing file is left
untouched, never truncated. Doesn't require or open a buffer.

```
:File touch notes/todo.md
```

## `:File[!] rename [%] [dest]`

Rename (or move) the current file on disk to `{dest}`. Updates the buffer
name and **reloads the buffer from disk** afterwards (resets signs/
diagnostics). Writes unsaved changes before renaming. An existing
destination without `!` asks first (`ui.kit.confirm`) instead of just
failing; `!` overwrites directly, no prompt.

```
:File rename newname.lua
:File rename % newname.lua    (explicit %, same result)
:File! rename ../moved.lua    (overwrite if exists, no prompt)
```

## `:File[!] move [%] [dest]`

Move the current file on disk to `{dest}` (possibly a different directory)
and update the buffer name — same underlying rename as `rename`, but the
buffer is **not** reloaded: content and undo history stay exactly as they
were. An existing destination without `!` asks first instead of failing;
`!` overwrites directly.

```
:File move ../elsewhere/file.lua
:File! move % ../elsewhere/file.lua
```

## `:File[!] duplicate [%] [dest]`

Copy the current file to `{dest}` and open the copy. An existing
destination without `!` asks first instead of failing; `!` overwrites
directly.

```
:File duplicate backup.lua
:File! duplicate % backup.lua
```

## `:File[!] copy [%] [dest]`

Copy the current file to `{dest}` using libuv, like `duplicate`, but without
opening the copy afterwards. An existing destination without `!` asks first
instead of failing; `!` overwrites directly.

```
:File copy backup.lua
:File! copy % backup.lua
```

## `:File[!] delete [%]`

Delete the current file from disk and close the buffer. Sends it to the OS
trash/recycle bin by default (`delete.mode = "trash"`), or deletes it for
good via libuv when `delete.mode = "permanent"` — see
[Configuration](configuration.md). If the
buffer has unsaved changes, plain `:File delete` asks first
(`ui.kit.confirm`) instead of just refusing — decline or leave it
unanswered and nothing is deleted; `!` skips the prompt and deletes the
file + force-closes the buffer directly. If `delete.on_before_delete` is
configured, it runs first and can abort the deletion by returning `false`
(e.g. to warn about git-tracked files).

```
:File delete
:File delete %    (same)
:File! delete     (delete + force-close a modified buffer, no prompt)
```

## `:[count]File[!] next [target] [glob]` / `:[count]File[!] prev [target] [glob]`

Navigate to the next / previous file in the current directory. An optional
trailing `[glob]` (e.g. `*.lua`) narrows the directory listing to matching
file names before navigating — everything else (wrap, hidden files, sort
order) works the same as unfiltered navigation. Matching uses
`vim.fn.glob2regpat`.

```
:File next               → next file, configured open_target
:File next vsplit        → in a vertical split
:File next *.lua         → next file matching *.lua
:File next vsplit *.lua  → in a vertical split, matching *.lua
:2File next              → skip 2 files
:File! next              → bypass modified-buffer confirm
```

### Target values:

| Arg | Behaviour |
|---|---|
| `%` or `replace` | Open in current window (replaces buffer) |
| `stay` or `current` | Edit in-place, keep old buffer listed |
| `new` or `split` | Horizontal split |
| `vsplit` | Vertical split |
| `tab` | New tab |
| `bg` or `background` | Load into buffer list without switching |

If the first argument isn't one of the target keywords above, it's treated
as the glob pattern instead (so `:File next *.lua` works without needing to
name a target first).

Set `cycle.root = "buffer_dir_recursive"` (or `"cwd_recursive"`) to also walk
subdirectories instead of listing just the top-level directory — see
[Configuration](configuration.md).

## `:File[!] first [target]` / `:File[!] last [target]`

Jump straight to the first / last file in the current directory listing
(alphabetical, respecting `cycle.include_hidden`/`cycle.case_insensitive`),
instead of stepping one at a time with `next`/`prev`. Same `[target]` values
and `!` behaviour as `next`/`prev`.

```
:File first              → jump to the first file
:File last vsplit        → jump to the last file, in a vertical split
```

## `:File[!] open [target]`

Reopen the current buffer's own path in a different window target, without
changing which file is shown — e.g. pop the file you're already editing into
a vertical split or a new tab. Same `[target]` values as `next`/`prev`; `!`
skips the modified-buffer confirm the same way it does there.

```
:File open vsplit        → current file, in a vertical split
:File open tab           → current file, in a new tab
:File! open              → current file, reloaded, skipping the modified check
```

## `:File path [mode]`

Copy the current file's path to the unnamed register and the system
clipboard (`+`). `[mode]` defaults to `abs`.

| Mode | Result |
|---|---|
| `abs` (default) | Absolute path |
| `rel` | Relative to cwd |
| `name` | File name only |
| `dir` | Containing directory only |

```
:File path              → absolute path
:File path rel          → path relative to cwd
:File path name         → just the file name
```

## `:File info`

Show size, last-modified time, and permissions for the current file, via
libuv `fs_stat` (works cross-platform, including Windows).

```
:File info
→ /home/me/project/init.lua
  size: 1.2 KiB (1234 bytes)
  modified: 2026-07-20 14:03:11
  permissions: 644
```

## `:File lockinfo [path]`

Diagnose a `EBUSY` / `EPERM` / `EACCES` failure: is the file locked *right
now*, and which process is holding it? Defaults to the current buffer's file.
Run it right after a rename/move/delete failed.

```
:File lockinfo
→ path:   C:\repos\notes\00_Notes.md
  exists: yes

  rename probe:
    NOT renameable: EBUSY: resource busy or locked: …

  handle holders (Windows Restart Manager):
    pid 21096  pwsh  [PowerShell 7]
```

The report also goes to `:messages`, so it can be copied into a bug report
after the notification times out.

| Probe | Holders | Meaning |
|---|---|---|
| not renameable | a foreign process | That process is the cause — an antivirus scan, the search indexer, OneDrive. |
| not renameable | `nvim` itself | A handle leaked inside this Neovim (a watcher that was never closed); no retry can outwait it. |
| not renameable | none | A kernel-level lock not registered with the Restart Manager. |
| renameable | any | The lock was transient and is already gone — what the `retry` budget exists for. |

An open buffer is never the cause: Neovim closes a file after reading it and
keeps only its swap file open. Holder lookup is Windows-only (it uses the
Restart Manager API, no administrator rights needed); the rename probe works
everywhere. The implementation lives in `lib.nvim.cross.fs.lock` so other
plugins report the same findings in the same words.

## `:File[!] bulk rename {pattern} {replacement}`

Batch-rename every regular file directly inside the current buffer's
directory (no recursion) whose name changes under
`name:gsub(pattern, replacement)` — a **Lua pattern**, not a glob, applied
to the file name only (not the full path). Files the pattern doesn't match,
or that `gsub` leaves unchanged, are left alone.

Shows a preview of every `old → new` pair via `notify.info`, then asks for
confirmation (`ui.kit.confirm`) before touching disk. When destinations
exist already, the preview marks them `(exists)` and the dialog offers
"Rename N, skip K existing" (the first choice, where the dialog starts: the
existing files stay, the others are renamed), "Rename M, overwrite K existing"
or Cancel, so nothing
has to be retyped with `!`. `!` overwrites existing destinations without
asking about them. Any open
buffer pointing at a renamed file is re-pointed at the new path (no
reload — same as `:File move`), and each successful rename fires the usual
`notify_change`/`User FileopsChanged` (see [Autocommands](autocommands.md)).

```
:File bulk rename ^draft_ final_     → draft_1.md → final_1.md, draft_2.md → final_2.md, …
:File bulk rename %.txt$ .md         → note.txt → note.md
:File! bulk rename ^old_ new_        → overwrites existing new_* files
```

## `:File cd [scope]`

Change the working directory to the directory of the current buffer's file,
then refresh any open file explorer (neo-tree, nvim-tree, netrw) so it tracks
the new root. Optional `[scope]` overrides `cd.scope` for this call.

```
:File cd            → :lcd to buffer's dir (window-local, default)
:File cd tab        → :tcd (tab-local)
:File cd global     → :cd (global)
```

| Scope | Command | Effect |
|---|---|---|
| `window` | `:lcd` | Window-local working directory (default) |
| `tab` | `:tcd` | Tab-local working directory |
| `global` | `:cd` | Global working directory |

## `:File help`

Show a short usage overview for every subcommand directly in the command
line (via `notify.info`), without opening `:h fileops`.
