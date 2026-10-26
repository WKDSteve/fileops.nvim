# Contributing to fileops.nvim

Thank you for your interest! Bugs, ideas and questions are welcome in the
[issue tracker](https://github.com/WKDSteve/fileops.nvim/issues); pull
requests very welcome.

## Getting the repository into a session

Clone it and either symlink the checkout into your plugin directory or add it to
the runtime path directly:

```lua
vim.opt.rtp:prepend("/path/to/fileops.nvim")
require("fileops").setup({})
```

Work in a scratch directory. Several subcommands delete files.

## Ground rules

- Lua only, idiomatic Neovim Lua. 2-space indentation.
- **All I/O goes through libuv directly.** No `os.execute`, no shelling out to
  `mv`/`cp`/`rm`. That is the single reason this plugin behaves identically on
  Windows and Unix, and it is not negotiable for a convenience.
- **The disk operation and the buffer operation are one unit.** A rename that
  succeeds on disk and leaves the buffer pointing at the old path is a bug, and
  so is the reverse. Decide up front whether the operation reloads the buffer
  (`rename`) or does not (`move`), and document which.
- **Every tree-changing operation fires `User FileopsChanged`** with
  `{action, path}`, unconditionally — before any explorer-specific refresh, and
  regardless of `explorer.refresh_on_change`. That event is the public contract
  other plugins listen to; the built-in neo-tree/nvim-tree reload is a
  convenience on top of it.
- **`!` overrides safety, nothing else.** The existing-file guard and the
  modified-buffer confirmation are what the bang is for. Do not use it to select
  a different behaviour.
- **Every path argument is optional.** Omitting it opens a `vim.ui.input` prompt,
  never an error.
- Commands are registered through `lib.nvim.bindings.usercmd.composer`.
- Descriptive commit messages.

## Project layout

| Path | Contains |
| --- | --- |
| `lua/fileops/ops/` | The filesystem operations themselves, over libuv |
| `lua/fileops/features/` | Navigation, bulk rename, path/info/lockinfo reporting |
| `lua/fileops/bindings/` | The `:File` route tree, completion, and the optional keymaps |
| `lua/fileops/config/` | Defaults and `setup()` validation |
| `lua/fileops/integrations/` | Soft-dependency bridges (nvzone/menu, filetree.nvim) |
| `lua/fileops/util/` | Shared path and buffer helpers |
| `lua/fileops/health.lua` | `:checkhealth fileops` |
| `docs/` | Everything the README links to |
| `TESTS/` | The spec suite |

## Adding a subcommand

1. Implement the operation under `lua/fileops/ops/` or
   `lua/fileops/features/`, over libuv, returning an error rather than raising.
2. Decide and document: does it change the tree (then it fires
   `User FileopsChanged`), and does it reload the buffer?
3. Route it in `lua/fileops/bindings/` with completion, an optional `[path]`
   that falls back to a prompt, and `!` handling if it has a safety check.
4. Add a spec under `TESTS/`, including the failure path — a destination that
   exists, a modified buffer, a permission error.
5. Document it in [`commands.md`](commands.md), the matching page under
   [`FEATURES/`](FEATURES/README.md), and [`BINDINGS.md`](BINDINGS.md).

## Tests

`TESTS/` is a headless spec suite run by
[testing.nvim](https://github.com/WKDSteve/testing.nvim): each `*_spec.lua`
returns a function that receives the shared harness (`TESTS/harness.lua`), and
the run order is the `specs` list in `TESTS/run.lua` (read by testing.nvim,
never executed — new specs go there too). Run it from the repo root with

```sh
bash scripts/test.sh
```

(`--file <substring>` runs only matching specs, `--json <path>` also writes the
machine-readable result.) testing.nvim and lib.nvim are looked up in
`$TESTING_NVIM_DIR` / `$LIB_NVIM_DIR`, `.deps/<name>`, `../<name>` and
`stdpath('data')/lazy/<name>`; a missing one is a loud error naming all four.

Every fixture lives under `vim.fn.tempname()` — the suite never operates on
the repository. [GitHub Actions](../.github/workflows/ci.yml) runs it on every
push and PR to `main`, once on its own and once with neo-tree.nvim and
nvim-tree.lua checked out as siblings. [`TESTS/README.md`](../TESTS/README.md)
lists what each spec covers, what is deliberately left out, and the bugs
currently held in place by a regression assertion.

## Workflow

1. Fork the repository.
2. Branch as `feature/<name>`.
3. Make the change, add a spec, update the affected pages under `docs/`.
4. Open a PR with a clear description of what changed and why.
