# Tests

Headless spec suite for fileops.nvim. It drives the real modules against real
files in a temporary directory: the filesystem operations, the `:File` command
as a user types it, the keymap preset, the autocmd-driven features, the health
check, and the public Lua API.

## Run

From the repo root:

```sh
bash scripts/test.sh                 # every spec
bash scripts/test.sh --file config   # only spec files whose name contains "config"
bash scripts/test.sh --json ir.json  # also write the machine-readable result
```

The runner is [testing.nvim](https://github.com/WKDSteve/testing.nvim)
(configured in `.testing.lua`, dialect `h` = the harness below). It prints one
line per spec file, a summary, and exits non-zero when a spec fails or when
nvim, testing.nvim or lib.nvim cannot be found. A skipped spec (see the
explorer integration below) is reported as a skip, never as green; pass
`--strict` to make a skip fail.

## Conventions

A spec is a file `TESTS/<name>_spec.lua` returning `function(H) H.run_preserved(spec) end`,
where `spec(H)` is the body;
testing.nvim discovers it by name. The `specs` list in `run.lua` (read, never
executed) is kept in sync with the files, so a new spec is added to that list
too. The suite shares one Neovim process but no spec may depend on the order
(`--shuffle` must stay green): a spec sets up what it asserts on itself. `H` is the shared harness:

| Helper | What it does |
| --- | --- |
| `H.eq` / `H.ok` | The two assertions. Both count into the per-spec total. |
| `H.tmpdir()` | A fresh, empty directory under `vim.fn.tempname()`, with symlinks resolved. |
| `H.write_file(path, content)` | Write a fixture, creating parent directories. |
| `H.edit(path)` | `:edit` a path and return its bufnr. |
| `H.is_windows()` | For the cases that pin platform-specific path behaviour. |
| `H.notifications(fn)` | Run `fn` with `vim.notify` captured; returns what it emitted. |
| `H.notified(seen, needle)` | Whether any captured notification contains `needle`. |
| `H.stub(module, value)` | Put a double on `package.loaded`; returns its restore function. |
| `H.preserve()` | Snapshot buffers, windows, tab pages, autocmds, user commands, global keymaps, the cwd and `vim.g.loaded_fileops`; returns the function that puts them back. |
| `H.run_preserved(spec)` | Run a spec body between `H.preserve()` and its restore, also when it raises or returns early. |

Three rules the whole suite follows:

- **Nothing is ever written outside `vim.fn.tempname()`.** Every fixture tree
  is built and thrown away there; no spec operates on the repository. The
  cases that need a particular working directory `:cd` into their own scratch
  directory and restore the previous one.
- **No spec leaves editor state behind.** Every spec body runs through
  `H.run_preserved`, and testing.nvim's state guard is on `error`
  (`.testing.lua`): a buffer, window, tab page, autocmd, user command, keymap
  or working directory a spec leaves turns the run red. A spec closes only
  the windows and tab pages it opened itself.
- **No process is spawned that a spec does not need.** `git` is real, in the
  three specs that test git-awareness (and each skips itself if `git` cannot
  run). Everything else that shells out is replaced at `package.loaded`
  before the call that would resolve it — see below.

`H.tmpdir()` hands its directory back with symlinks already resolved, and a
spec should build every expected path on top of it rather than on a raw
`vim.fn.tempname()`. On macOS `$TMPDIR` is `/var/folders/…` and `/var` is a
symlink to `/private/var`: Neovim resolves that when it names a buffer, and
`getcwd()` reports the resolved form, while `fnamemodify(…, ":p")` does not
resolve anything. An expected path joined onto the raw temp name therefore
compares as unequal to the very same file read back off a buffer — a
difference in spelling, not in behaviour. Resolving in the fixture keeps both
sides of such a comparison in one spelling from the start.

## Doubles, and why

`ui.nvim` is not a dependency of this suite (`.testing.lua` lists only
`lib.nvim`), so the prompt/dialog layer is always a double. The rest of the
doubles exist to keep the suite off the OS.

| Module | Replaced because | Used in |
| --- | --- | --- |
| `ui.kit` | Not a CI checkout; `input`/`confirm` need an answer to continue. | `usrcmds*`, `cycle_edge`, `keymaps`, `filetree_assets` |
| `ui.contextmenu` | Not a CI checkout; the entries are the subject, not the rendering. | `health_menu` |
| `lib.nvim.fs.trash` | Real trashing spawns PowerShell/`osascript`/`gio` and would leave fixtures in the machine's recycle bin. | `file_delete`, `usrcmds_dispatch`, `keymaps` |
| `lib.nvim.cross.fs.lock` | The holder lookup spawns a helper process. | `file_delete`, `usrcmds_dispatch`, `keymaps`, `init_api` |
| `lib.nvim.cross.fs.mutate` | Swapped for one case each, to prove the retry budget is passed down — a Windows sharing violation cannot be provoked from inside this process. | `file_spec`, `usrcmds_dispatch` |
| `filetree.refs` | Soft integration with a plugin that is not a dependency. | `filetree_assets`, `keymaps` |

Each is restored immediately afterwards, so the specs stay independent of one
another with respect to them.

## Layout

| File | Covers |
| --- | --- |
| `harness.lua` | The assertions and helpers above. |
| `run.lua` | Legacy runner, no longer executed; its `specs` list fixes the spec order for testing.nvim. |
| `minimal_init.lua` | Puts this repo, testing.nvim and lib.nvim on the runtimepath for isolated child runs; fails loudly (all four searched places) when one is missing. |
| `config_spec.lua` | `config/`: defaults, deep merge, the deliberately unset keymaps. |
| `notify_spec.lua` | `util/notify.lua`: the prefix, the levels, and `report()`'s relay contract. |
| `cycle_spec.lua` | `ops/cycle.lua`: listing, wrap, hidden files, patterns, recursion, case-insensitive order. |
| `cycle_edge_spec.lua` | `ops/cycle.lua`: every `open_target`, the unsaved-changes dialog, the `root` variants, counts, wrap boundaries, failure returns, and the `follow_symlinks = false` path comparison. |
| `file_spec.lua` | `ops/file.lua`: copy/move/rename/touch/delete, the retry contract, git-awareness, `session_compat`. |
| `file_paths_spec.lua` | `ops/file.lua`: path resolution (spaces, `%`/`#`, globs, drive letters, relative vs. absolute), `ensure_parent` failures, `edit_new`/`save_as`/`write_to`/`mk_parent`, `notify_change`, `copy_path`, the `info` size ladder. |
| `file_delete_spec.lua` | `ops/file.lua`: trash vs. permanent, the unsaved guard, window bookkeeping after a delete, `delete_path`, the `on_before_delete` veto, `diagnose_lock`, vanished sources. |
| `bulk_spec.lua` | `ops/bulk.lua`: plan/execute, conflicts, hidden-file filtering. |
| `bulk_edge_spec.lua` | `ops/bulk.lua`: invalid patterns, the separator normalization, what `plan` excludes, partial failures, buffers following a rename. |
| `git_spec.lua` | `util/git.lua`: `is_tracked`/`mv`/`rm` against a real temp git repo (skips if git is unusable). |
| `git_async_spec.lua` | `util/git.lua`: the `_async` twins, driven to completion via `vim.wait`. |
| `usrcmds_spec.lua` | `bindings/usrcmds.lua`: that `prompt_dest()` routes through `kit.input`. |
| `usrcmds_dispatch_spec.lua` | `bindings/usrcmds.lua`: every `:File[!]` subcommand through the real Ex command, the `%` scope form, the prompts and their defaults, the config flags the dispatch folds in (`retry`, `git_aware`, `session_compat`, `delete.mode`), bulk rename end to end, and completion for every slot. |
| `keymaps_spec.lua` | `bindings/keymaps.lua`: the declared action set, both family switches, per-key overrides, `keymaps = false` (nothing bound, no which-key group labels), and what every action's `rhs` does. |
| `autocmds_spec.lua` | `bindings/autocmds.lua` (auto-mkdir, remote skipping), `features/conflict_marks.lua`, `features/on_hold.lua`'s event mapping and guards, and `bindings/init.lua`'s wiring. |
| `on_hold_preview_spec.lua` | `features/on_hold.lua`'s preview itself: the git blame/show fallback against a real temp repo, `truncate()`'s character-vs-byte handling, `only_tracked`, an uncommitted line, the `gitsigns.preview_hunk_inline()` branch (including its own failure), `restore_view`, and the cleanup autocmd. |
| `init_api_spec.lua` | `init.lua`: `setup()` and its idempotence, plus every public API function. |
| `health_menu_spec.lua` | `health.lua` against a recorded `vim.health`, and `integrations/menu.lua`'s entries and what they run. |
| `filetree_assets_spec.lua` | `integrations/filetree_assets.lua`: the cascade-delete-assets seam behind `:File delete`. |
| `explorer_integration_spec.lua` | `ops/file.lua`'s explorer-refresh path against REAL neo-tree.nvim/nvim-tree.lua — optional, see below. |
| `testing_config_spec.lua` | The project's `.testing.lua`: evaluable without the editor API, no directory allowed as a write root, only neo-tree's log file let through the fs guard. |

`platform_spec.lua` is gone: `util/platform.lua` was removed in favour of
`lib.nvim.cross.fs.mutate`, and that behaviour (`mkdir_p`, `copy_file`,
`rename_file`, `delete_file`) is covered by lib.nvim's own
`TESTS/nvim_helpers_spec.lua`. The coverage moved with the code.

## Deliberately not covered

- **`lua/fileops/@types/init.lua`** — annotations only, no runtime code.
- **`plugin/fileops.lua`** — a three-line `vim.g.loaded_fileops` guard with no
  branch of its own.
- **`config/DEFAULTS.lua`** as a table — every value that matters is asserted
  through the behaviour it produces (`config_spec.lua` and each feature's own
  spec) rather than by re-typing the table here.
- **`ops/file.lua`'s `reload_explorers`/`refresh_explorers`** beyond their
  `package.loaded[…]` guard — they need real neo-tree/nvim-tree instances,
  which is what the separate `explorer_integration_spec.lua` job is for.
- **`lib.nvim.fs.trash`'s backends and `lib.nvim.cross.fs.lock`'s holder
  lookup** — other repo, other suite. What is asserted here is the argument
  fileops hands them and how it reports their answer.
- **The `:File` dispatcher's unknown-subcommand branch** — unreachable through
  the command: composer resolves the route first and reports
  `unknown subcommand '…'` before `dispatch` is ever called.
- **`ops/bulk.lua`'s "cannot read directory" guard** — also unreachable:
  everything `vim.fs.dir` would raise on already raises one line earlier,
  where `plan` normalizes the trailing separator. A directory that does not
  exist simply lists as empty.

## Bugs this suite found

Eight defects came out of writing it and a later re-audit round. All eight are
**fixed**; the assertions that pinned them stayed on as regression guards, so
the behaviour cannot drift back unnoticed.

1. **`ops/cycle.lua` — `follow_symlinks = false` froze navigation on
   Windows** (`cycle_edge_spec.lua`) — **fixed.** `list_files` joins entries as
   `dir .. "/" .. name`; with `follow_symlinks` off, `canon` fell back to
   `fnamemodify(":p")`, which leaves that `/` in place, while
   `nvim_buf_get_name` spells the same file with `\`. `index_of` therefore
   never found the current file, `navigate` appended it as an extra listing
   entry, `\` sorted the copy last, and `next` wrapped straight back onto the
   same file. Comparisons now run through a `comparable()` helper that
   normalizes separators; the paths the plugin stores, opens and shows keep
   their platform spelling.
2. **`ops/bulk.lua` — a bulk rename stranded the open buffer on Windows**
   (`bulk_edge_spec.lua`, `usrcmds_dispatch_spec.lua`) — **fixed.** `execute`
   re-points open buffers by comparing the plan's path against
   `nvim_buf_get_name`; the two disagreed in one character, `nvim_buf_set_name`
   never ran, and after the rename the buffer pointed at a file that no longer
   existed — the next `:w` wrote the old name back into being. Both sides of
   that comparison are normalized now. The plan's own strings are unchanged, so
   a root spelled with and without a trailing separator still produces
   different *strings* for the same file; that is asserted as documented
   behaviour rather than as a defect.
3. **`bindings/keymaps.lua` — the delete key ignored `delete.mode`** —
   **fixed**, assertions kept as regression guards (`keymaps_spec.lua`).
   `:File delete` reads `config.delete` (the mode and `on_before_delete`)
   plus the git-aware/retry/refresh flags; the keymap called `delete_fn({})`
   and passed none of them, so once the default flipped to `"trash"` the
   default delete key still unlinked the file permanently, with no undo, and
   never ran an `on_before_delete` hook. `delete_fn` now reads
   `delete.mode`/`delete.on_before_delete` per invocation — the way the other
   actions in that file read their config, so a later `setup()` still
   applies — while `force` stays the caller's. The git-aware/retry/refresh
   flags are deliberately still not pulled in: the keymaps never carried
   them, and adding them is a separate decision.
4. **`ops/file.lua` — `delete_path` accepted directories it could never
   delete** (`file_delete_spec.lua`) — **fixed.** Its existence check let a
   directory through, but the permanent deletion is `uv.fs_unlink`. On Windows
   libuv answers `EPERM`, which lib.nvim's retry loop treats as a transient
   sharing violation (so the full budget was spent first) and
   `explain_fs_error` then blamed a virus scanner for what is really "this is a
   directory". The permanent path refuses a directory up front now, with that
   reason; trashing one still works, since the OS backend handles it.
5. **`features/conflict_marks.lua` — matches leaked per `:e`**
   (`autocmds_spec.lua`) — **fixed.** Re-editing the same file in the same
   window is a `BufWinEnter` with no `BufWinLeave` in front of it: three fresh
   matches were added and the recorded ids overwritten, so the previous set
   could never be deleted. Invisible (same lines, same groups) but unbounded.
   Both handlers now go through one `clear_window_matches()` helper, and
   `BufWinEnter` calls it before adding its own.
6. **`health.lua` — `:checkhealth fileops` crashed instead of degrading when
   `lib.nvim` was genuinely absent** (`health_menu_spec.lua`) — **fixed.**
   The check correctly detected a missing
   `lib.nvim.bindings.usercmd.composer` and reported it with
   `vim.health.error(...)`, but then unconditionally called
   `require("lib.nvim.bindings.usercmd.composer").checkhealth("File")` at the
   end of `M.check()` regardless — a bare `require()` of the exact module it
   had just reported missing, which throws and aborts the whole report
   instead of ending on the warning already given. That final call is now
   gated on the same detection.
7. **`features/on_hold.lua` — the committed-line preview had never actually
   rendered anything** (`on_hold_preview_spec.lua`) — **fixed.**
   `get_previous_line_async` built `git show <sha>:<file>` from
   `nvim_buf_get_name`'s absolute path; `git show`'s `<rev>:<path>` resolves
   `<path>` against the repository root, not the filesystem, so the call
   always failed with `fatal: path '...' does not exist in '<rev>'` and the
   chain silently ended at `cb(nil)` — no crash, no notification, just a
   fallback preview that had never once rendered outside
   `gitsigns.preview_hunk_inline()`. `cwd` is already the file's own
   directory, so `git show` now asks for
   `sha .. ":./" .. fnamemodify(file, ":t")`, which git resolves relative to
   that `cwd` instead.
8. **`features/on_hold.lua` — `truncate()` could slice a multi-byte
   character in half** (`on_hold_preview_spec.lua`) — **fixed.** `max_len` is
   documented (`DEFAULTS.lua`, `@types`) as "this many characters", but
   `truncate()` measured and cut with `#s`/`string.sub`, both byte-indexed —
   identical to a character count for plain ASCII, but a previous line
   containing any multi-byte UTF-8 character near the cut point could be
   split mid-character, handing `nvim_buf_set_extmark` a malformed byte
   sequence for its `virt_text` (it does not reject one — it renders the
   mangled bytes). Now measured and cut with `vim.fn.strchars`/
   `vim.fn.strcharpart`, a no-op change for the plain-ASCII case.
9. **`bindings/usrcmds.lua` — `complete_from_bufdir` went silently empty for
   a buffer directory containing a glob metacharacter** (`usrcmds_dispatch_spec.lua`)
   — **fixed.** It fed the buffer's directory straight into
   `getcompletion(..., "file")`, which reads its argument as a *pattern*, not
   a path; a directory like `notes[final]/` or `[Project]/` made every
   candidate vanish with no error, so `:File rename <Tab>` offered nothing
   for that buffer (completion-only — the path could still be typed by
   hand). `complete_from_bufdir` is scandir-based now (`vim.fs.dir` via the
   new `scandir_prefix` helper), which reads a directory as a path, and
   splits `arg_lead` itself into an already-typed directory segment plus the
   trailing partial name so nested-path completion (`subdir/partial<Tab>`)
   keeps working the same as it did through `getcompletion`.

Two related quirks are asserted as *documented* behaviour rather than as bugs:
`:saveas` normalizes the buffer name it stores while the `:file` command
behind `rename`/`edit_new` does not, so a renamed buffer carries a
mixed-separator name on Windows (`file_paths_spec.lua`); and a plan built from
a root *with* a trailing separator produces different path strings than the
same directory spelled without one (`bulk_edge_spec.lua`).

## lib.nvim

The suite needs `lib.nvim` on the runtimepath, since `ops/file.lua` and
`ops/cycle.lua` require it. `scripts/test.sh` resolves it (and testing.nvim) in
this order, and exits 1 naming all four places when it is not found:

1. `$LIB_NVIM_DIR` (`$TESTING_NVIM_DIR` for testing.nvim)
2. `.deps/lib.nvim`
3. a sibling checkout (`../lib.nvim`)
4. the plugin-manager copy (`stdpath("data")/lazy/lib.nvim`)

A set override decides alone; it is never skipped for another checkout. The
sibling checkout wins over the plugin-manager copy: the bootstrap clone is
often older than the working checkout, and testing against a stale lib.nvim
produces misleading failures.

## Explorer integration (optional)

`explorer_integration_spec.lua` exercises `ops/file.lua`'s explorer-refresh
code path against real `neo-tree.nvim` and `nvim-tree.lua` instances instead
of just the `package.loaded[...]`-guarded no-op every other spec exercises.
Neither plugin is a runtime dependency of fileops.nvim, so the spec skips
itself (prints `skip` and returns) unless both — plus neo-tree's own hard
deps, `nui.nvim` and `plenary.nvim` — are found, looked up by the spec itself in
this order (plenary is only the neo-tree dependency here, not the test runner):

1. `$NEO_TREE_NVIM_DIR` / `$NVIM_TREE_LUA_DIR` / `$NUI_NVIM_DIR` / `$PLENARY_NVIM_DIR`
2. a sibling checkout (`../neo-tree.nvim`, `../nvim-tree.lua`, `../nui.nvim`, `../plenary.nvim`)

CI runs it as its own `explorer-integration` job in `.github/workflows/ci.yml`,
which checks the four repos out as siblings and runs with `--strict`, so a skip
there is red. A local run with nothing checked out just reports it as a skip —
the main `test` job (and a plain `bash scripts/test.sh`) never depend on it.

## Adding a spec

Create `<name>_spec.lua` returning `function(H) … end` and add its filename
to the `specs` list in `run.lua`. Build fixtures with `H.tmpdir()` /
`H.write_file`, assert the *reported* error on a failure path (not just that
something failed), and restore anything global the spec touches — the working
directory, a stubbed module, an autocmd group, `vim.notify`.
