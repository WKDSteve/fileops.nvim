# Autocommands

| Event | augroup | Action |
|---|---|---|
| `BufWritePre` | `fileops_auto_mkdir` | Create parent directories for the file about to be written — the automatic-on-save counterpart to [`:File mkdir`](commands.md#file-mkdir) |

Gated by `config.auto_mkdir.enable` (default `true`). Disable it entirely:

```lua
require("fileops").setup({
  auto_mkdir = { enable = false },
})
```

`auto_mkdir.skip_remote` (default `true`) skips buffers whose name matches
`auto_mkdir.detect_remote_pattern` (e.g. `ssh://`, `http://`).

## `on_hold`

On `CursorHold`/`CursorHoldI`, previews what changed on the current line:
prefers gitsigns' inline hunk preview when available, otherwise falls back to
showing the previous committed content of the line as virtual text (via
`git blame`/`git show`, argv-only — no shell). Per-window throttled, mode-aware
(`on_hold.modes`), and cleared on the next cursor move. Sets
`vim.o.updatetime = 100` when enabled, matching the responsiveness the
fallback preview needs.

Gated by `config.on_hold.enable` (default `false` — opt-in). Enable it:

```lua
require("fileops").setup({
  on_hold = { enable = true },
})
```

## `conflict_marks`

On `BufWinEnter`/`BufWinLeave`, highlights unresolved Git conflict markers
(`<<<<<<<`, `=======`, `>>>>>>>`) using `matchadd`/`matchdelete`, scoped
per-window.

Gated by `config.conflict_marks.enable` (default `true`). Disable it entirely:

```lua
require("fileops").setup({
  conflict_marks = { enable = false },
})
```

## `User FileopsChanged`

Every op that changes the file tree (`new`, `write`, `saveas`, `writeto`,
`mkdir`, `touch`, `rename`, `move`, `duplicate`, `copy`, `delete`) fires a
`User FileopsChanged` autocmd on success, so any plugin or user config can
react — not just the two tree explorers fileops.nvim knows about directly.

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "FileopsChanged",
  callback = function(ev)
    -- ev.data = { action = "rename"|"move"|"duplicate"|"copy"|"delete"|
    --                      "touch"|"new"|"saveas"|"writeto"|"mkdir",
    --             path = "/abs/path/to/file" }
    vim.notify(ev.data.action .. ": " .. ev.data.path)
  end,
})
```

fileops.nvim itself also reloads neo-tree/nvim-tree in place after these ops
(no root change, unlike `:File cd`), gated by `config.explorer.refresh_on_change`
(default `true`) — the event fires regardless of that setting.

`rename`/`move` additionally resave the active `:mksession` session
(`v:this_session`) by default — see `session_compat` in
[Configuration](configuration.md). Other session managers (possession.nvim,
[sessions.nvim](https://github.com/WKDSteve/sessions.nvim), ...) can hook
the `User FileopsChanged` event above instead of relying on `v:this_session`.

## `User FileopsRetry`

On Windows a rename/copy/delete can fail with `EBUSY`/`EPERM`/`EACCES`
because some process still holds the file open — an antivirus scan, the
search indexer, OneDrive, a directory watcher. (An open Neovim buffer is
*not* one of them: Neovim closes the file after reading it and only keeps
its swap file open.) fileops retries such a failure a few times with an
escalating backoff, and fires `User FileopsRetry` before each new attempt:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "FileopsRetry",
  callback = function(ev)
    -- ev.data = { path = "/abs/path", attempt = 1, err = "EBUSY: …" }
    -- Close your own handle on ev.data.path here — the wait between attempts
    -- runs the event loop, so a handle released now is gone by the next try.
  end,
})
```

This exists because a retry is useless against a handle held inside *this*
Neovim: a file watcher that never calls `handle:close()` will still be
holding the file on attempt six. Plugins that watch paths should use this
event to let go. See `retry` in [Configuration](configuration.md) for the
attempt budget.

See [Configuration](configuration.md) for the full option list.
