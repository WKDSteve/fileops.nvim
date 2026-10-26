# Workflow — using fileops.nvim day to day

Every subcommand is documented on its own in [docs/commands.md](commands.md).
This is the different question: once you're editing a real project, what
sequence of `:File` calls (and which config toggles) actually gets used
together, and which of the plugin's own behaviors will surprise you if you
haven't read the source.

## Two different "relative to" bases — know which one you're in

This is the trap most likely to bite: **not every subcommand resolves a
relative path the same way.**

- `rename`/`move`/`duplicate`/`copy` resolve a relative destination against
  the **current file's own directory**. `:File rename NEW.md` renames in
  place, next to the file you're editing, regardless of Neovim's cwd.
- `new`/`write`/`saveas`/`writeto`/`touch` resolve a relative path against
  **Neovim's cwd** instead — the same base `:write` itself uses.

Concretely: if you're editing `src/deep/nested/file.lua` with cwd at the
project root, `:File rename sibling.lua` lands next to `file.lua`
(`src/deep/nested/sibling.lua`), but `:File touch sibling.lua` creates it at
the project root. Both are deliberate — `rename`/`move`/`duplicate`/`copy`
act *on* an existing file so "same folder" is the useful default; the create
family has no existing file to anchor to, so it falls back to the same base
`:write` already uses. Reach for `:File rename %:h/sibling.lua` (or just
`:File touch` with an absolute path) when you actually want the other base.

Tab-completion follows the buffer-directory rule everywhere it applies:
`:File rename <Tab>` browses files next to the one you're editing, not cwd —
useful for confirming you're about to hit the file you think you are before
you commit to a destination.

## The three-way delete guard

`:File delete` on a buffer with unsaved changes asks first (`ui.kit.confirm`
— "delete anyway (force-close)?"): decline or leave it unanswered and
nothing is deleted, not even a partial write. `:File! delete` skips that
prompt and force-closes and deletes directly. If you've configured
`delete.on_before_delete`, it runs *before* either of those checks touch the
disk and can veto the deletion by returning `false` — the one hook point to
add your own "warn on git-tracked files" gate, since fileops itself only
*notes* tracked-ness via `git_aware`, it never blocks a delete on it by
default.

```lua
require("fileops").setup({
  delete = {
    on_before_delete = function(path)
      if require("fileops.util.git").is_tracked(path) then
        return vim.fn.confirm("Delete tracked file " .. path .. "?", "&Yes\n&No") == 1
      end
      return true
    end,
  },
})
```

Deleting also steers any window showing that buffer onto an alternate listed
buffer first, so closing it doesn't leave you staring at an empty scratch
buffer if other files are open — nothing to configure, just useful to know
before you wonder why the window didn't go blank.

## `git_aware`: turning it on doesn't turn on `git mv`/`git rm` by itself

`git_aware.enable = true` alone only adds a "(git-tracked)" note to the
result message — the actual filesystem op still goes through libuv.
`git mv -f`/`git rm -f` only run when you *also* set `git_warn_only = false`:

```lua
require("fileops").setup({
  git_aware = { enable = true, warn_only = false },
})
```

Two things worth knowing before flipping `warn_only = false`: delete only
uses `git rm` when `delete.mode == "permanent"` (trashing a file is a
different operation, so trash mode always just notes tracked-ness and trashes
it anyway), and `duplicate`/`copy` never run a git command at all regardless
of this setting — there's no git-native "copy", the new file just starts out
untracked.

## Retry budget is effectively Windows-only, and `lockinfo` knows it

`retry.attempts` defaults to `6` on Windows and `1` everywhere else — the
comment in `config/DEFAULTS.lua` is explicit that this is deliberate:
retrying only pays off against the kind of transient sharing-violation
Windows produces (antivirus scan, search indexer, OneDrive holding a handle
for a moment); on Linux/macOS an `EBUSY`/`EPERM` is a real error worth
surfacing immediately rather than masking behind a retry loop.

When a rename/move/delete does fail with one of those codes, run
`:File lockinfo` right away — it probes whether the file is renameable *right
now* and, on Windows, names the actual process holding it via the Restart
Manager API. The holder lookup itself is Windows-only; the rename probe works
everywhere. The report is also echoed to `:messages`, specifically so it
outlives the notification timeout — `:messages` right after a failed op is
the fast way to get the full multi-line report back if you blinked and
missed the popup.

**The one thing `lockinfo` will never blame is an open Neovim buffer** —
Neovim closes a file's handle after reading it and keeps only its swap file
open, so if the holder is `nvim` itself, it's a leaked watcher (a file-watch
handle that never called `close()`), not the buffer you're looking at. That
case is also the one `lockinfo`'s own table calls out as "no retry can
outwait it" — worth knowing before burning through the retry budget a second
time expecting a different result.

## Bulk rename: it's a Lua pattern, not a glob — and it's non-recursive

`:File bulk rename {pattern} {replacement}` runs `name:gsub(pattern,
replacement)` on every regular file **directly inside** the current buffer's
directory (no recursion into subdirectories). The pattern is a **Lua
pattern**, matched against the file name only — `.` matches any character
the way it does in Lua, so `:File bulk rename .txt .md` also touches
`footxt.md`-shaped names you didn't mean to match; anchor it properly:

```
:File bulk rename %.txt$ .md      -- correct: literal ".txt" at the end
:File bulk rename ^draft_ final_  -- draft_1.md -> final_1.md, draft_2.md -> final_2.md, …
```

It always shows the full `old → new` preview via a notification *before* the
`vim.ui.select` confirm prompt appears — read the preview, not just the
count, since a pattern that's slightly too broad only announces itself there.
Files the pattern doesn't match, or that `gsub` leaves unchanged, are quietly
excluded from the plan rather than erroring. Without `!`, a conflicting
destination is skipped and reported while the rest of the batch still
completes — so a partial `N/total renamed` result is expected behavior for a
directory with pre-existing name collisions, not a bug.

## Cycling with a glob filter, and the target/glob argument-order trap

`:File next`/`:File prev` take an optional `[target]` and an optional
`[glob]`, in either order — the first argument is treated as a target
keyword if it matches one (`%`, `replace`, `stay`, `current`, `new`, `split`,
`vsplit`, `tab`, `bg`, `background`), and as the glob pattern otherwise:

```
:File next *.lua               -- next *.lua file, default target
:File next vsplit *.lua        -- next *.lua file, in a vsplit
:2File next                    -- skip 2 files (v:count1)
:File! next                    -- bypass the modified-buffer confirm
```

The trap: there is no way to pass a glob that happens to collide with a
target keyword's spelling (unlikely in practice, but a glob like `split`
alone would be read as the target, not the pattern) — if that ever matters,
pair it with an explicit target first (`:File next replace split*`) so the
glob lands in the second slot unambiguously.

Set `cycle.root = "buffer_dir_recursive"` (or `"cwd_recursive"`) once, in
config, if you want `next`/`prev`/`first`/`last` to walk subdirectories
instead of listing just the top-level directory — worth doing for a flat
"jump to next markdown note anywhere under this tree" workflow
(`cycle.root = "cwd_recursive"`, `cycle.pattern = "*.md"`), not something you
toggle per call.

## `on_hold` only activates where it can actually answer the question

`on_hold` (off by default) needs the current buffer's directory to be inside
a git work tree, and — with `only_tracked` at its default `true` — the file
itself must be tracked. Both checks run via a synchronous `git`
subprocess on every trigger, so it's a real no-op (not an error, not a
notification) on an untracked scratch file or outside any repo, silently.
If gitsigns.nvim is also installed, `on_hold` prefers its
`preview_hunk_inline()` over its own fallback — meaning the diff preview you
see is gitsigns' own rendering, not fileops', whenever both are present; the
git-blame/git-show fallback only kicks in when gitsigns is absent or its
inline preview call itself fails.

## `explorer.refresh_on_change` vs `cd.refresh_explorers` — two separate switches

Every tree-changing op fires `User FileopsChanged` unconditionally — that
part is never gated. Whether fileops *also* reloads neo-tree/nvim-tree in
place for you is a **different** setting depending on which op:
`explorer.refresh_on_change` (default `true`) covers
create/rename/move/duplicate/copy/delete, while `:File cd`'s own explorer
refresh is `cd.refresh_explorers` (also default `true`, but independent). If
you use a session/tree-explorer plugin that reacts to the raw event instead
of a in-place reload, you can turn either or both off without losing the
event itself — hook `User FileopsChanged` for your own reaction:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "FileopsChanged",
  callback = function(ev)
    -- ev.data = { action = "rename"|"move"|..., path = "/abs/path" }
  end,
})
```

## Session-compat: why a plain `:mksession!` isn't enough on its own

`session_compat.enable` (default `true`) resaves the active `:mksession`
session after `rename`/`move` specifically because a bare `:mksession!`
**ignores `v:this_session`** and writes a fresh `./Session.vim` into
whatever the cwd happens to be — not back to the file the session was
originally loaded from. fileops passes `v:this_session` explicitly
(`mksession! <that path>`) so the *existing* session file gets updated in
place instead. It's a no-op when no session was ever loaded (`v:this_session
== ""`), so nothing fires on a fresh Neovim start with no `:source
Session.vim` behind it. If you use a session manager that isn't
`v:this_session`-based (possession.nvim,
[sessions.nvim](https://github.com/WKDSteve/sessions.nvim)), leave
`session_compat.enable` on anyway — it only touches `v:this_session`, so it
won't conflict — and hook `User FileopsChanged` for the manager's own
resave logic instead of relying on this feature to cover it.

## A realistic sequence: renaming a tracked file mid-refactor

Putting several of the above together — renaming a git-tracked module while
keeping the index, the active session, and any open tree explorer all in
sync, with a safety net if something's still holding the old path open:

```lua
require("fileops").setup({
  git_aware = { enable = true, warn_only = false },
  session_compat = { enable = true },
  explorer = { refresh_on_change = true },
})
```

```
:File rename ../core/handler.lua
```

That one call: writes any unsaved changes first, resolves `../core/` against
the *current* file's directory (not cwd), runs `git mv -f` instead of a
plain filesystem rename (since `git_aware.warn_only = false`), reloads the
buffer from disk at the new path, fires `User FileopsChanged`, reloads
neo-tree/nvim-tree in place, and resaves the active session so it doesn't
point at the stale path — all before the notification for it appears. If it
fails with `EBUSY` instead (a watcher still holding the old path), the retry
budget already tried up to 6 times with a doubling backoff before giving up;
`:File lockinfo` on the old path is the next step, not a second manual
retry.
