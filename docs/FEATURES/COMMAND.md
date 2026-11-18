# The unified :File command

Everything fileops.nvim does hangs off a single user command. This page covers
the command surface itself and the reasoning behind collapsing every operation
into one verb.

## Unified `:File` command

A single `:File[!] {subcommand} [args…]` command dispatches to every
operation the plugin offers instead of one command per verb. `!` overrides
safety checks (existing-file guard, modified-buffer confirm); `%` is an
explicit "current file" scope, always implied when omitted. Every
`[path]`/`[dest]` argument is optional — omitting it opens a `vim.ui.input`
(via `ui.kit`) prompt instead of erroring, and cancelling the prompt
is a silent no-op. Tab-completion for path arguments resolves against the
**current buffer's directory**, not Neovim's cwd.

- **Tab:** true
- **Module:** `bindings/usrcmds.lua` (`M.register`, `dispatch`), built on
  `lib.nvim.bindings.usercmd.composer`
- **Usercmds:** [`:File`](../commands.md) — see
  [docs/BINDINGS.md#user-commands](../BINDINGS.md#user-commands) for the full
  subcommand table
- **Config:** `opts.commands` (default `true`) — master switch for
  registering `:File` at all

- Create/write: `save`, `new`, `write`, `saveas`, `writeto`, `mkdir`, `touch`
- Mutate: `rename`, `move`, `duplicate`, `copy`, `delete` (git-aware, retrying,
  session-compat, trash-mode opt-in)
- Navigate: `next`, `prev`, `first`, `last`, `open` (glob filter, recursive
  root, configurable open target)
- Diagnose: `info`, `lockinfo` (Windows sharing-violation holder lookup)
- Bulk: `bulk rename` (Lua-pattern batch rename with preview + confirm)
- Misc: `path` (clipboard), `cd` (+ explorer refresh), `help`
- Ambient features: `auto_mkdir`, `on_hold` (line-diff preview, opt-in),
  `conflict_marks`
- Full Lua API mirroring every subcommand (`docs/api.md`), which-key groups,
  per-key remappable keymaps, `:checkhealth fileops`, headless test suite
  (`TESTS/`) run in CI alongside stylua/luacheck.

### Why one command instead of many

Every subcommand shares the same `!`/`%`/prompt-on-missing-arg conventions,
the same tab-completion base (buffer directory), and the same
git-aware/retry/session-compat plumbing for the five mutating subcommands
(`rename`/`move`/`duplicate`/`copy`/`delete`). Dispatching through one
`lib.nvim.bindings.usercmd.composer` verb with per-subcommand routes means that
plumbing is written once in `bindings/usrcmds.lua`'s `dispatch()` function
instead of once per command definition, and `:File help` can enumerate every
subcommand from the same `SUBCMDS` table the router itself uses.

