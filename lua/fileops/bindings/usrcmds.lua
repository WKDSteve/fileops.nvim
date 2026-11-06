---@module 'fileops.bindings.usrcmds'
---Registers the single :File[!] unified user command, built via
---lib.nvim.bindings.usercmd.composer.
local M = {}

local composer = require("lib.nvim.bindings.usercmd.composer")
local notify = require("fileops.util.notify")
local file = require("fileops.ops.file")
local cycle = require("fileops.ops.cycle")
local bulk = require("fileops.ops.bulk")
local config = require("fileops.config")
-- Shared with the delete/delete_force keymaps (bindings/keymaps.lua): the
-- confirm-on-unsaved-changes step, then delete + cascade-delete-assets.
local delete_confirm = require("fileops.bindings.delete_confirm")

-- ─── Subcommand catalogue ─────────────────────────────────────────────────────

local SUBCMDS = {
  "new",
  "write",
  "saveas",
  "writeto",
  "mkdir",
  "touch",
  "rename",
  "move",
  "duplicate",
  "copy",
  "delete",
  "next",
  "prev",
  "first",
  "last",
  "open",
  "path",
  "info",
  "lockinfo",
  "bulk rename",
  "cd",
  "help",
}

local HELP_TEXT = table.concat({
  ":File[!] {subcommand} [args…]",
  "",
  "  new {path}              set buffer name (no write)",
  "  write {path}            set buffer name + write (! overwrites)",
  "  saveas {path}           :saveas-equivalent (! overwrites)",
  "  writeto {path}          write a copy, name stays (! overwrites)",
  "  mkdir                   create parent dirs for current buffer",
  "  touch {path}            create an empty file if missing",
  "  rename [%] {dest}       rename + update buffer (reloads)",
  "  move [%] {dest}         move + update buffer (no reload)",
  "  duplicate [%] {dest}    copy + open the copy (! overwrites)",
  "  copy [%] {dest}         copy without opening (! overwrites)",
  "  delete [%]              delete + close buffer (! force-closes)",
  "  next/prev [target] [glob]  navigate directory listing, optionally filtered",
  "  first/last [target]     jump to first/last file in directory",
  "  open [target]           reopen current file in split/vsplit/tab/…",
  "  path [mode]             copy path to clipboard (abs/rel/name/dir)",
  "  info                    show size/mtime/permissions for current file",
  "  lockinfo [path]         who holds this file open (Windows EBUSY/EPERM diagnosis)",
  "  bulk rename {pat} {rep} batch-rename files in dir via Lua pattern (preview + confirm)",
  "  cd [scope]              cd to buffer's dir + refresh explorer",
  "  help                    show this message",
  "",
  "See :h fileops-command or docs/commands.md for full details.",
}, "\n")

local CD_SCOPES = { "window", "tab", "global" }

local CD_SCOPE_MAP = {
  ["window"] = "lcd",
  ["tab"] = "tcd",
  ["global"] = "cd",
}

local CYCLE_TARGETS = {
  "%",
  "replace",
  "stay",
  "current",
  "new",
  "split",
  "vsplit",
  "tab",
  "bg",
  "background",
}

local PATH_MODES = { "abs", "rel", "name", "dir" }

local CYCLE_TARGET_MAP = {
  ["%"] = "replace",
  ["replace"] = "replace",
  ["stay"] = "current",
  ["current"] = "current",
  ["new"] = "split",
  ["split"] = "split",
  ["vsplit"] = "vsplit",
  ["tab"] = "tab",
  ["bg"] = "background",
  ["background"] = "background",
}

-- ─── Completion ───────────────────────────────────────────────────────────────
-- rename/duplicate's first slot ("%" or a direct dest path) needs a custom
-- type; every other path completion below is FILEOPS_PATH (bufdir-relative);
-- non-path args map onto enums (CD_SCOPES/CYCLE_TARGETS/PATH_MODES).

---@internal
---Names in `dir` (bare, not full paths) that start with `prefix`, read
---straight off the filesystem via `vim.fs.dir` -- never through a glob, so a
---directory name or `prefix` itself containing a glob metacharacter (`[`,
---`]`, `*`, `?`, `{`, `}`) is just a literal to compare against, not pattern
---syntax that fails to match or matches the wrong thing (XP-01: `getcompletion`
---and `glob` both read their argument as a pattern). Dotfiles are excluded
---unless `prefix` itself starts with `.`, mirroring `getcompletion`'s own
---convention so a bare `<Tab>` doesn't suddenly surface `.git` and friends.
---An unreadable/missing `dir` yields no names rather than erroring, same as
---`getcompletion` would.
---@param dir string
---@param prefix string
---@return string[] names  Sorted, bare entry names (files and directories).
local function scandir_prefix(dir, prefix)
  local out = {}
  local ok, iter = pcall(vim.fs.dir, dir)
  if not ok then
    return out
  end
  local show_hidden = prefix:sub(1, 1) == "."
  for name in iter do
    local hidden = name:sub(1, 1) == "."
    if (show_hidden or not hidden) and name:sub(1, #prefix) == prefix then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---@internal
---Complete `arg_lead` relative to the current buffer's directory instead of
---cwd (`getcompletion`'s default base), so `:File rename <Tab>` browses
---files next to the buffer being edited rather than wherever Neovim's cwd
---happens to be. Absolute-looking input (`~`, `/`, or a Windows drive
---letter) is left alone. Candidates come back as full absolute paths — that
---keeps them unambiguous regardless of cwd once the command actually runs.
---
---This is scandir-based (`scandir_prefix`), not glob-based: a path is a
---path here, never a pattern, so a buffer directory containing a glob
---metacharacter (`[Project]`, `notes{final}`, …) still completes instead of
---silently returning nothing (XP-01). `arg_lead` may itself carry
---already-typed directory segments (`:File rename subdir/partial<Tab>`) --
---only the piece after the last separator is the partial name being
---completed; everything before it is more directory to descend into first,
---so nested-path completion keeps working the same as it did through
---`getcompletion`.
---
---The buffer's directory is resolved before it is used as the completion
---base. A Windows 8.3 short name (`C:\Users\RUNNER~1\…`, the alias a user
---name longer than eight characters gets) is a perfectly real path and
---`vim.fs.dir` reads it fine either way; `fs_realpath` here is only about
---returning candidates spelled the way the filesystem itself spells them,
---which is friendlier to read back than the short alias. A no-op everywhere
---else, 8.3 aliases included, once the user name is short enough not to get
---one.
---@param arg_lead string
---@return string[]
local function complete_from_bufdir(arg_lead)
  if arg_lead:match("^~") or arg_lead:match("^/") or arg_lead:match("^%a:[\\/]") then
    return vim.fn.getcompletion(arg_lead, "file")
  end

  local bufdir = vim.fn.expand("%:p:h")
  if bufdir == "" or vim.fn.isdirectory(bufdir) ~= 1 then
    return vim.fn.getcompletion(arg_lead, "file")
  end

  local uv = vim.uv or vim.loop
  local real = uv.fs_realpath and uv.fs_realpath(bufdir)
  if type(real) == "string" and real ~= "" then
    bufdir = real
  end

  local typed_dir, partial = arg_lead:match("^(.*)[/\\]([^/\\]*)$")
  local scan_dir = bufdir
  if typed_dir then
    scan_dir = bufdir .. "/" .. typed_dir
  else
    partial = arg_lead
  end

  if vim.fn.isdirectory(scan_dir) ~= 1 then
    return {}
  end

  local names = scandir_prefix(scan_dir, partial)
  local out = {}
  for i, name in ipairs(names) do
    out[i] = scan_dir .. "/" .. name
  end
  return out
end

-- `desc` of the three types: the line lib.nvim's option float shows for an
-- argument of that type without a text of its own. A route whose argument plays
-- another role words its own (every FILEOPS_PATH below does -- see `route()`).
composer.register_type("FILEOPS_DEST_FIRST", {
  desc = "Destination, relative to this file's folder (% may come first)",
  validate = function(raw)
    return true, raw, nil
  end,
  complete = function(arg_lead)
    local fc = complete_from_bufdir(arg_lead)
    if ("%"):sub(1, #arg_lead) == arg_lead then
      table.insert(fc, 1, "%")
    end
    return fc
  end,
})

composer.register_type("FILEOPS_PATH", {
  desc = "Path of a file (completion starts in this file's folder)",
  validate = function(raw)
    return true, require("lib.nvim.cross.fs.expand_path")(raw), nil
  end,
  complete = complete_from_bufdir,
})

-- `next`/`prev` accept an optional glob filter (e.g. `:File next *.lua`) in
-- the same slot a target keyword would go — so this slot can't be a strict
-- enum. Validation always passes; completion still offers the known target
-- keywords as a prefix match.
composer.register_type("FILEOPS_CYCLE_ARG", {
  desc = "Open target (replace, split, tab, ...) or a glob such as *.lua",
  validate = function(raw)
    return true, raw, nil
  end,
  complete = function(arg_lead)
    if arg_lead == "" then
      return vim.deepcopy(CYCLE_TARGETS)
    end
    local out = {}
    for _, t in ipairs(CYCLE_TARGETS) do
      if t:sub(1, #arg_lead) == arg_lead then
        out[#out + 1] = t
      end
    end
    return out
  end,
})

-- ─── Dispatch ─────────────────────────────────────────────────────────────────

local report = notify.report

---@internal
---Split next/prev's two optional args into a resolved target + glob
---pattern. Since the first slot may be either a target keyword or a glob
---filter (`:File next *.lua`), a recognized target keyword there shifts the
---pattern to the second slot; anything else is treated as the pattern
---itself (and a second arg, if present, is ignored).
---@param a1 string|nil
---@param a2 string|nil
---@return string|nil target
---@return string|nil pattern
local function resolve_cycle_args(a1, a2)
  local target = a1 and CYCLE_TARGET_MAP[a1:lower()]
  if target then
    return target, a2
  end
  return nil, a1
end

---@internal
---Run the file-cycle navigate with opts from config + per-call overrides.
---@param direction FileOps.Direction
---@param a1 string|nil  Target keyword or glob pattern (see `resolve_cycle_args`).
---@param a2 string|nil  Glob pattern, when `a1` was a target keyword.
---@param count integer
---@param bang boolean
local function do_cycle(direction, a1, a2, count, bang)
  local cfg = config.get()
  local copts = vim.deepcopy(cfg.cycle or {})

  local target, pattern = resolve_cycle_args(a1, a2)
  if target then
    copts.open_target = target
  end
  if pattern and pattern ~= "" then
    copts.pattern = pattern
  end

  if bang then
    copts.confirm_on_modified = false
  end

  local dir, err = cycle.get_root_dir(copts)
  if not dir then
    notify.warn(err or "cannot determine root directory")
    return
  end

  report(cycle.navigate(dir, direction, copts, count))
end

---@internal
---Jump straight to the first/last file in the directory, with opts from
---config + per-call overrides (same target/bang handling as `do_cycle`).
---@param edge "first"|"last"
---@param target_arg string|nil
---@param bang boolean
local function do_jump(edge, target_arg, bang)
  local cfg = config.get()
  local copts = vim.deepcopy(cfg.cycle or {})

  local target = target_arg and CYCLE_TARGET_MAP[target_arg:lower()]
  if target then
    copts.open_target = target
  end

  if bang then
    copts.confirm_on_modified = false
  end

  local dir, err = cycle.get_root_dir(copts)
  if not dir then
    notify.warn(err or "cannot determine root directory")
    return
  end

  report(cycle.jump_edge(dir, edge, copts))
end

---@internal
---Resolve destination from fargs, handling optional "%" scope prefix.
---Returns the destination path, or nil if missing.
---@param fargs string[]  Args after the subcommand.
---@return string|nil dest
local function resolve_dest(fargs)
  if #fargs == 0 then
    return nil
  end
  if fargs[1] == "%" then
    return fargs[2] -- :File rename % dest
  end
  return fargs[1] -- :File rename dest  (% implied)
end

---@internal
---Prompt for a missing path argument via kit.input instead of erroring.
---Calls `cb(input)` once a non-empty value is entered; a cancelled/empty
---prompt is a silent no-op (matches vim.ui.input's own convention).
---@param prompt_label string
---@param cb fun(input: string)
---@param default? string  Pre-filled prompt content (e.g. the current filename).
local function prompt_dest(prompt_label, cb, default)
  require("ui.kit").input({
    title = prompt_label,
    default = default,
    on_submit = function(input)
      if not input or input == "" then
        return
      end
      cb(input)
    end,
  })
end

---@internal
---Detects `ops/file.lua`'s own "destination already exists (use ! to
---overwrite)" error text -- the one case where a failure is really a
---declined-by-default choice, not a real error.
---@param msg string|nil
---@return boolean
local function is_overwrite_error(msg)
  return type(msg) == "string" and msg:find("use ! to overwrite", 1, true) ~= nil
end

---@internal
---Run `fn(dest, opts)` (one of file.rename/move/duplicate/copy); on the
---"destination already exists" error, offer to overwrite instead of just
---reporting it and leaving the user to retype the command with `!`. A
---decline is a silent no-op, matching `prompt_dest`'s own convention for a
---cancelled prompt.
---@param fn fun(dest: string, opts: table): boolean, string|nil
---@param dest string
---@param opts table
local function run_with_overwrite_confirm(fn, dest, opts)
  local ok, err = fn(dest, opts)
  if ok or opts.bang or not is_overwrite_error(err) then
    report(ok, err)
    return
  end
  require("ui.kit").confirm({
    question = err,
    choices = { "Yes, overwrite", "Cancel" },
    on_answer = function(choice)
      if choice == "Yes, overwrite" then
        report(fn(dest, vim.tbl_extend("force", opts, { bang = true })))
      end
    end,
  })
end

---@internal
---Current buffer's bare filename (`:t`), for pre-filling the rename prompt
---so the user edits the existing name instead of typing it from scratch.
---@return string|nil
local function cur_filename()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":t")
end

---@internal
---Whether tree-explorer refresh is enabled per `config.explorer.refresh_on_change`.
---@return boolean
local function refresh_flag()
  local cfg = config.get()
  return not (cfg.explorer and cfg.explorer.refresh_on_change == false)
end

---@internal
---git_aware.* opts for rename/move/duplicate/copy/delete, from config.
---@return { git_aware: boolean, git_warn_only: boolean, git_cmd: string }
local function git_flags()
  local cfg = config.get()
  local gcfg = cfg.git_aware or {}
  return {
    git_aware = gcfg.enable == true,
    git_warn_only = gcfg.warn_only ~= false,
    git_cmd = gcfg.git_cmd or "git",
  }
end

---@internal
---`retry.*` opts for the filesystem mutations, from config. Folded into the
---same table as `git_flags()` by every caller, so it returns the wrapper key
---the ops layer expects rather than the bare fields.
---@return { retry: FileOps.RetryConfig }
local function retry_flags()
  local cfg = config.get()
  return { retry = cfg.retry or {} }
end

---@internal
---Whether rename/move should resave the active `:mksession` session
---(`session_compat.enable`, default true).
---@return boolean
local function session_compat_flag()
  local cfg = config.get()
  return not (cfg.session_compat and cfg.session_compat.enable == false)
end

---@internal
---Build a bulk-rename plan for the buffer's directory, preview it, and
---(on confirmation via `kit.confirm`) execute it. Destinations that exist
---already are found against the state after the batch (`bulk.analyze`) and
---the dialog offers to skip or overwrite them; `!` drops the skip choice.
---Two files onto one destination refuse the batch before any dialog.
---@param pattern string|nil
---@param replacement string|nil
---@param bang boolean
local function do_bulk_rename(pattern, replacement, bang)
  if not pattern then
    notify.warn("usage: File[!] bulk rename {pattern} {replacement}")
    return
  end
  replacement = replacement or ""

  local dir, dir_err = cycle.get_root_dir({ root = "buffer_dir" })
  if not dir then
    notify.warn(dir_err or "cannot determine directory")
    return
  end

  local plan, plan_err = bulk.plan(dir, pattern, replacement)
  if plan_err then
    notify.error("bulk rename: " .. plan_err)
    return
  end
  if #plan == 0 then
    notify.info(("bulk rename: no files in %s matched %q"):format(dir, pattern))
    return
  end

  local tail = function(p)
    return vim.fn.fnamemodify(p, ":t")
  end

  -- Two files onto one destination: whichever ran second would overwrite the
  -- first, a batch member, with no dialog ever saying so. Refused outright,
  -- before any dialog: no answer to one could make that plan safe.
  local analysis = bulk.analyze(plan)
  if #analysis.duplicates > 0 then
    local lines = {
      ("bulk rename: refused, %d destination(s) would receive more than one file; nothing renamed"):format(
        #analysis.duplicates
      ),
    }
    for _, d in ipairs(analysis.duplicates) do
      local olds = vim.tbl_map(tail, d.olds)
      lines[#lines + 1] = ("  %s → %s"):format(table.concat(olds, ", "), tail(d.new))
    end
    notify.error(table.concat(lines, "\n"))
    return
  end

  -- Destinations that exist already are found here, before the dialog, so the
  -- dialog can offer to skip or overwrite them (UI-05) instead of the run
  -- failing on them with "use ! to overwrite" and the user retyping it. "Exist"
  -- is judged after the batch: a destination this batch moves away first is
  -- free (see `bulk.analyze`).
  local mark = {
    exists = "  (exists)",
    directory = "  (a directory: kept)",
    modified = "  (exists, open with unsaved changes: kept)",
  }
  local preview = { ("bulk rename: %d file(s) in %s"):format(#plan, dir) }
  for i, item in ipairs(plan) do
    local status = analysis.status[i]
    local note = mark[status] or ""
    if status == "exists" and analysis.target_buf[i] then
      note = "  (exists, open in a buffer)"
    end
    preview[#preview + 1] = ("  %s → %s%s"):format(tail(item.old), tail(item.new), note)
  end
  notify.info(table.concat(preview, "\n"))

  local skip_run, skip_held = bulk.select(plan, analysis, "skip")
  local over_run, over_held = bulk.select(plan, analysis, "overwrite")
  local clashes = 0
  for _, item in ipairs(over_run) do
    if item.overwrite then
      clashes = clashes + 1
    end
  end

  ---@param held { item: FileOps.BulkRenamePlanItem, reason: string }[]
  ---@return string[]
  local function kept_lines(held)
    local out = {}
    for _, h in ipairs(held) do
      out[#out + 1] = ("  kept %s: %s"):format(tail(h.item.old), h.reason)
    end
    return out
  end

  ---@param items (FileOps.BulkRenamePlanItem|{ overwrite?: boolean })[]
  ---@param held { item: FileOps.BulkRenamePlanItem, reason: string }[]
  local function run(items, held)
    -- No `bang`: each item carries its own `overwrite`, set only for the
    -- destinations the dialog announced. One taken while the dialog was open
    -- is refused, not overwritten.
    local renamed, err, notes = bulk.execute(items, { refresh_explorers = refresh_flag() })
    if err then
      notify.error(("bulk rename: %d/%d renamed, first failure: %s"):format(renamed, #items, err))
    else
      notify.info(("bulk rename: %d file(s) renamed"):format(renamed))
    end
    local lines = kept_lines(held)
    for _, n in ipairs(notes or {}) do
      lines[#lines + 1] = "  " .. n
    end
    if #lines > 0 then
      notify.warn("bulk rename:\n" .. table.concat(lines, "\n"))
    end
  end

  if #over_run == 0 then
    notify.warn("bulk rename: nothing renamed\n" .. table.concat(kept_lines(over_held), "\n"))
    return
  end

  -- Nobody can answer a dialog without a UI (headless, a script): never wait
  -- on one there and never act unasked. Refused, as before the dialog existed.
  if #vim.api.nvim_list_uis() == 0 then
    local why = clashes > 0
        and (", %d destination(s) exist already (use ! to overwrite)"):format(clashes)
      or ""
    notify.warn(("bulk rename: no UI to confirm it; nothing renamed%s"):format(why))
    return
  end

  local kit = require("ui.kit")
  if clashes == 0 then
    local confirm_choice = ("Rename %d file(s)"):format(#over_run)
    kit.confirm({
      question = "[fileops] Confirm bulk rename?",
      choices = { confirm_choice, "Cancel" },
      on_answer = function(choice)
        if choice == confirm_choice then
          run(over_run, over_held)
        end
      end,
    })
    return
  end

  -- The harmless answer comes first: the dialog starts on it. That is "skip"
  -- while skipping still renames something, "Cancel" otherwise -- never the
  -- answer that overwrites.
  local overwrite = ("Rename %d, overwrite %d existing"):format(#over_run, clashes)
  local skip = nil
  local choices = { "Cancel", overwrite }
  if not bang and #skip_run > 0 then
    skip = ("Rename %d, skip %d existing"):format(#skip_run, #plan - #skip_run)
    choices = { skip, overwrite, "Cancel" }
  end
  kit.confirm({
    question = ("[fileops] Confirm bulk rename? %d destination(s) exist already"):format(clashes),
    choices = choices,
    -- Named, not left to the kit: its own default is the Cancel-style button,
    -- which would make the skip offered first one keypress further away.
    default = choices[1],
    on_answer = function(choice)
      if skip and choice == skip then
        run(skip_run, skip_held)
      elseif choice == overwrite then
        run(over_run, over_held)
      end
    end,
  })
end

---@class Fileops.CmdCtx
---@field fargs string[]    Arguments after the subcommand.
---@field bang boolean
---@field count integer      v:count1 equivalent from :N File
---@field refresh boolean    Refresh the explorers afterwards.
---@field mutopts table      Git-awareness and retry budget (the five mutating subcommands).

---@internal
---Run `run(dest)` with the first argument, or ask for it when there is none.
---@param ctx Fileops.CmdCtx
---@param label string
---@param run fun(dest: string)
local function with_dest_arg(ctx, label, run)
  if ctx.fargs[1] then
    run(ctx.fargs[1])
  else
    prompt_dest(label, run)
  end
end

---@internal
---A subcommand that takes a destination (argument or prompt) and reports `op(dest, opts)`.
---@param label string
---@param op fun(dest: string, opts: table): any
---@param extra? fun(ctx: Fileops.CmdCtx): table  Options added to `refresh_explorers`.
---@return fun(ctx: Fileops.CmdCtx)
local function dest_command(label, op, extra)
  return function(ctx)
    local opts =
      vim.tbl_extend("force", { refresh_explorers = ctx.refresh }, extra and extra(ctx) or {})
    with_dest_arg(ctx, label, function(dest)
      report(op(dest, opts))
    end)
  end
end

---@internal
---A subcommand that moves or copies onto a destination: `%`/path argument or prompt,
---with an overwrite confirmation around `op`.
---@param label string
---@param op function
---@param session_compat boolean  Also tell sessions the file moved.
---@param prompt_default? fun(): string
---@return fun(ctx: Fileops.CmdCtx)
local function transfer_command(label, op, session_compat, prompt_default)
  return function(ctx)
    local dest = resolve_dest(ctx.fargs)
    local base = { bang = ctx.bang, refresh_explorers = ctx.refresh }
    if session_compat then
      base.session_compat = session_compat_flag()
    end
    local opts = vim.tbl_extend("force", base, ctx.mutopts)
    if dest then
      run_with_overwrite_confirm(op, dest, opts)
    else
      prompt_dest(label, function(d)
        run_with_overwrite_confirm(op, d, opts)
      end, prompt_default and prompt_default() or nil)
    end
  end
end

---@internal
---Subcommand name to its handler.
---@type table<string, fun(ctx: Fileops.CmdCtx)>
local HANDLERS = {
  new = dest_command("File new: ", function(dest, opts)
    return file.edit_new(dest, opts)
  end),
  write = dest_command("File write: ", function(dest, opts)
    return file.edit_new(dest, opts)
  end, function(ctx)
    return { write = true, bang = ctx.bang }
  end),
  saveas = dest_command("File saveas: ", function(dest, opts)
    return file.save_as(dest, opts)
  end, function(ctx)
    return { bang = ctx.bang }
  end),
  writeto = dest_command("File writeto: ", function(dest, opts)
    return file.write_to(dest, opts)
  end, function(ctx)
    return { bang = ctx.bang }
  end),
  touch = dest_command("File touch: ", function(dest, opts)
    return file.touch(dest, opts)
  end),

  mkdir = function(ctx)
    report(file.mk_parent({ refresh_explorers = ctx.refresh }))
  end,

  rename = transfer_command("File rename: ", file.rename, true, cur_filename),
  move = transfer_command("File move: ", file.move, true),
  duplicate = transfer_command("File duplicate: ", file.duplicate, false),
  copy = transfer_command("File copy: ", file.copy, false),

  delete = function(ctx)
    local dcfg = config.get().delete or {}
    delete_confirm.run(vim.tbl_extend("force", {
      force = ctx.bang,
      mode = dcfg.mode,
      on_before_delete = dcfg.on_before_delete,
      refresh_explorers = ctx.refresh,
    }, ctx.mutopts))
  end,

  cd = function(ctx)
    local cfg = config.get()
    local arg = ctx.fargs[1] and CD_SCOPE_MAP[ctx.fargs[1]:lower()]
    local scope = arg or (cfg.cd and CD_SCOPE_MAP[cfg.cd.scope]) or "lcd"
    local cd_refresh = not (cfg.cd and cfg.cd.refresh_explorers == false)
    report(file.cd_here({ scope = scope, refresh = cd_refresh }))
  end,

  next = function(ctx)
    do_cycle("next", ctx.fargs[1], ctx.fargs[2], ctx.count, ctx.bang)
  end,
  prev = function(ctx)
    do_cycle("prev", ctx.fargs[1], ctx.fargs[2], ctx.count, ctx.bang)
  end,
  first = function(ctx)
    do_jump("first", ctx.fargs[1], ctx.bang)
  end,
  last = function(ctx)
    do_jump("last", ctx.fargs[1], ctx.bang)
  end,

  open = function(ctx)
    local copts = vim.deepcopy(config.get().cycle or {})

    local target = ctx.fargs[1] and CYCLE_TARGET_MAP[ctx.fargs[1]:lower()]
    if target then
      copts.open_target = target
    end

    if ctx.bang then
      copts.confirm_on_modified = false
    end

    report(cycle.open_current(copts))
  end,

  path = function(ctx)
    report(file.copy_path(ctx.fargs[1]))
  end,
  info = function()
    report(file.info())
  end,
  lockinfo = function(ctx)
    file.diagnose_lock(function(ok_, msg)
      -- The report is a multi-line block meant to be read and pasted into a
      -- bug report, so it goes to :messages as well — a notification alone
      -- would time out before it can be copied.
      if ok_ then
        print(msg)
      end
      report(ok_, msg)
    end, ctx.fargs[1])
  end,
  bulk_rename = function(ctx)
    do_bulk_rename(ctx.fargs[1], ctx.fargs[2], ctx.bang)
  end,
  help = function()
    notify.info(HELP_TEXT)
  end,
}

---@internal
---Dispatch a parsed command to the appropriate operation.
---@param subcmd string
---@param fargs string[]  Arguments after the subcommand.
---@param bang boolean
---@param count integer   v:count1 equivalent from :N File
local function dispatch(subcmd, fargs, bang, count)
  local handler = HANDLERS[subcmd]
  if not handler then
    notify.warn(("unknown subcommand %q — try: %s"):format(subcmd, table.concat(SUBCMDS, ", ")))
    return
  end
  handler({
    fargs = fargs,
    bang = bang,
    count = count,
    refresh = refresh_flag(),
    -- Git-awareness and the retry budget travel together: both apply to exactly
    -- the five subcommands that mutate the filesystem.
    mutopts = vim.tbl_extend("force", git_flags(), retry_flags()),
  })
end

-- ─── Register ────────────────────────────────────────────────────────────────

---@internal
---Reconstruct a flat fargs array (matching dispatch's expected shape) from
--- composer's bound positionals + any leftover tokens.
---@param ctx table composer Ctx
---@return string[]
local function fargs_of(ctx)
  local out = {}
  for _, v in ipairs(ctx.pos) do
    out[#out + 1] = tostring(v)
  end
  for _, v in ipairs(ctx.rest) do
    out[#out + 1] = v
  end
  return out
end

---@internal
---One line per sub-command, for the composer option float and the generated docs
---(wording follows docs/BINDINGS.md).
---@type table<string, string>
local ROUTE_DESC = {
  new = "Set the buffer name (creates parent dirs, no write)",
  write = "Set the buffer name and write it to disk",
  saveas = "Save as: the buffer name changes",
  writeto = "Write a copy, the buffer name stays",
  mkdir = "Create the parent dirs of the current buffer",
  touch = "Create an empty file if it does not exist yet",
  rename = "Rename the file on disk and update the buffer (reloads)",
  move = "Move the file on disk and update the buffer (no reload)",
  duplicate = "Copy the file to a new path and open the copy",
  copy = "Copy the file to a new path without opening it",
  delete = "Delete the file from disk and close the buffer",
  cd = "Set the cwd to the buffer's directory and refresh the explorer",
  next = "Next file in the directory (optionally filtered, e.g. *.lua)",
  prev = "Previous file in the directory (optionally filtered)",
  first = "Jump to the first file in the directory",
  last = "Jump to the last file in the directory",
  open = "Reopen the current file in a different window target",
  path = "Copy the current file's path to the clipboard (abs/rel/name/dir)",
  info = "Show size, mtime and permissions of the current file",
  lockinfo = "Diagnose which process locks the file",
  ["bulk rename"] = "Batch-rename files in the directory via a Lua pattern (preview + confirm)",
  help = "Show the :File sub-commands",
}

---@internal
---What each open target does, for the `target` of `first`/`last`/`open` (the words are the keys of
---`CYCLE_TARGET_MAP`; `next`/`prev` take them in a free slot, which has no per-value texts).
---@type table<string, string>
local TARGET_VALUES = {
  ["%"] = "same as replace",
  replace = "open here, an unmodified old buffer is removed",
  stay = "open here, the old buffer stays",
  current = "same as stay",
  new = "same as split",
  split = "horizontal split",
  vsplit = "vertical split",
  tab = "new tab page",
  bg = "load into the buffer list, no window",
  background = "same as bg",
}

---@internal
---The single optional path argument of the commands that act on a file by its path.
---@param desc string
---@return table[]
local function path_arg(desc)
  return { { name = "path", type = "FILEOPS_PATH", optional = true, desc = desc } }
end

---@internal
---The `[%] {dest}` pair of `rename`/`move`/`duplicate`/`copy`: the first word is the
---destination (the type's own text) or `%`, which pushes the destination to the second.
---@return table[]
local function dest_args()
  return {
    { name = "a1", type = "FILEOPS_DEST_FIRST", optional = true },
    {
      name = "a2",
      type = "FILEOPS_PATH",
      optional = true,
      desc = "Destination after %, relative to this file's folder",
    },
  }
end

---@internal
---The optional `target` of `first`/`last`/`open`.
---@param desc string
---@return table[]
local function target_arg(desc)
  return {
    {
      name = "target",
      type = "STRING",
      optional = true,
      enum = CYCLE_TARGETS,
      desc = desc,
      enum_desc = TARGET_VALUES,
    },
  }
end

---@internal
---The `[target] [glob]` pair of `next`/`prev`: the first word is an open target or, when it is
---none, the glob; the second is the glob after a target.
---@return table[]
local function cycle_args()
  return {
    { name = "a1", type = "FILEOPS_CYCLE_ARG", optional = true },
    {
      name = "a2",
      type = "STRING",
      optional = true,
      desc = "Glob that narrows the listing, after a target (e.g. *.lua)",
    },
  }
end

---Build a composer route table for `subcmd`, dispatching through `dispatch`.
---@param subcmd string
---@param args? table[]
---@return table
local function route(subcmd, args)
  return {
    path = { subcmd },
    desc = ROUTE_DESC[subcmd],
    args = args,
    run = function(ctx)
      local count = (ctx.range.count and ctx.range.count > 0) and ctx.range.count or 1
      dispatch(subcmd, fargs_of(ctx), ctx.bang, count)
    end,
  }
end

function M.register()
  composer.verb("File", {
    desc = "Unified file operations (new/write/saveas/writeto/mkdir/touch/rename/move/duplicate/copy/delete/next/prev/first/last/open/path/info/lockinfo/bulk rename/cd/help)",
    bang = true,
    count = 0,
    routes = {
      -- The create commands resolve a relative path against the cwd, like `:write`; the
      -- rename family below against the folder of the current file. Without a path they prompt.
      route("new", path_arg("Buffer name to set, relative to the cwd (none: prompt)")),
      route("write", path_arg("File to write the buffer to, relative to the cwd (none: prompt)")),
      route("saveas", path_arg("File to save the buffer as, relative to the cwd (none: prompt)")),
      route("writeto", path_arg("File to write a copy to, relative to the cwd (none: prompt)")),
      route("mkdir"),
      route("touch", path_arg("File to create, relative to the cwd (none: prompt)")),
      route("rename", dest_args()),
      route("move", dest_args()),
      route("duplicate", dest_args()),
      route("copy", dest_args()),
      route("delete"),
      route("cd", {
        {
          name = "scope",
          type = "STRING",
          optional = true,
          enum = CD_SCOPES,
          desc = "How far the new directory reaches (default: cd.scope)",
          enum_desc = {
            window = "this window only (:lcd)",
            tab = "this tab page (:tcd)",
            global = "everywhere (:cd)",
          },
        },
      }),
      route("next", cycle_args()),
      route("prev", cycle_args()),
      route("first", target_arg("Where to open the file (default: cycle.open_target)")),
      route("last", target_arg("Where to open the file (default: cycle.open_target)")),
      route("open", target_arg("Where to reopen the file (default: cycle.open_target)")),
      route("path", {
        {
          name = "mode",
          type = "STRING",
          optional = true,
          enum = PATH_MODES,
          desc = "Which form of the path to copy (default: abs)",
          enum_desc = {
            abs = "the absolute path",
            rel = "relative to the cwd",
            name = "the file name only",
            dir = "the containing directory only",
          },
        },
      }),
      route("info"),
      route("lockinfo", path_arg("File to check (default: the current file)")),
      {
        path = { "bulk", "rename" },
        desc = ROUTE_DESC["bulk rename"],
        args = {
          {
            name = "pattern",
            type = "STRING",
            desc = "Lua pattern matched against each file name (not a glob)",
          },
          {
            name = "replacement",
            type = "STRING",
            optional = true,
            desc = "Replacement text; %1 inserts a capture (default: empty)",
          },
        },
        run = function(ctx)
          dispatch("bulk_rename", fargs_of(ctx), ctx.bang, 1)
        end,
      },
      route("help"),
    },
  })
end

return M
