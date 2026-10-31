-- TESTS/autocmds_spec.lua — the autocmd-driven features and the binding
-- orchestrator: `bindings/autocmds.lua`'s auto-mkdir, `features/
-- conflict_marks.lua`, `features/on_hold.lua`'s event wiring, and
-- `bindings/init.lua` deciding what gets wired at all.
--
-- The auto-mkdir callback is driven with `nvim_exec_autocmds` rather than a
-- real `:write`: the branch under test is what it does with `event.match`,
-- and a remote-looking match ("ssh://…") must never reach a real write.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local fn = vim.fn
  local autocmds = require("fileops.bindings.autocmds")
  local config = require("fileops.config")

  -- `nvim_get_autocmds` raises for a group that was never created, which is
  -- itself one of the answers these cases want ("registered nothing").
  ---@param group string
  ---@return table[]
  local function autocmds_of(group)
    local got, res = pcall(vim.api.nvim_get_autocmds, { group = group })
    return (got and res) or {}
  end

  ---@param group string
  local function drop_group(group)
    pcall(vim.api.nvim_del_augroup_by_name, group)
  end

  ---@param group string
  ---@return string[]
  local function events_of(group)
    local out = {}
    for _, a in ipairs(autocmds_of(group)) do
      out[#out + 1] = a.event
    end
    table.sort(out)
    return out
  end

  -- ── auto_mkdir ───────────────────────────────────────────────────────────
  do
    autocmds.attach_auto_mkdir({ enable = true })
    local registered = autocmds_of("fileops_auto_mkdir")
    eq(#registered, 1, "auto_mkdir registers exactly one autocmd")
    eq(registered[1].event, "BufWritePre", "…on BufWritePre, before the file is written")

    local dir = H.tmpdir()
    local target = dir .. "missing/deeper/file.txt"
    eq(fn.isdirectory(dir .. "missing/deeper"), 0, "setup: the parent directory does not exist")
    vim.api.nvim_exec_autocmds("BufWritePre", { pattern = target })
    eq(fn.isdirectory(dir .. "missing/deeper"), 1, "auto_mkdir created the parent directory")

    -- A real write is the point of the feature, so do one end to end too.
    local written = dir .. "written/by/write.txt"
    vim.cmd("enew")
    vim.cmd("file " .. fn.fnameescape(written))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "content" })
    vim.cmd("write")
    eq(fn.filereadable(written), 1, "a plain :write into a missing directory now succeeds")

    -- Remote paths are skipped: turning "ssh://host/…" into a local directory
    -- tree is never what the user meant. Fired from inside an empty scratch
    -- cwd, so that a regression would create its junk there (and be caught)
    -- instead of somewhere real — the relative remainder of such a path
    -- resolves against the cwd.
    local remote_probe = H.tmpdir()
    local probe_prev_cwd = fn.getcwd()
    vim.cmd("cd " .. fn.fnameescape(remote_probe))
    vim.api.nvim_exec_autocmds("BufWritePre", { pattern = "ssh://host/remote/dir/file.txt" })
    vim.api.nvim_exec_autocmds("BufWritePre", { pattern = "scp://host/remote/dir/file.txt" })
    vim.api.nvim_exec_autocmds("BufWritePre", { pattern = "file://host/remote/dir/file.txt" })
    eq(#fn.readdir(remote_probe), 0, "remote-looking paths create nothing locally")
    vim.cmd("cd " .. fn.fnameescape(probe_prev_cwd))

    -- The remote pattern is configurable, and a path that no longer matches it
    -- is treated as local again.
    autocmds.attach_auto_mkdir({ enable = true, detect_remote_pattern = "^nomatch://" })
    local odd = dir .. "custom/pattern/file.txt"
    vim.api.nvim_exec_autocmds("BufWritePre", { pattern = odd })
    eq(
      fn.isdirectory(dir .. "custom/pattern"),
      1,
      "a custom remote pattern narrows what is skipped"
    )

    -- Re-attaching replaces the group rather than stacking a second copy.
    autocmds.attach_auto_mkdir({ enable = true })
    eq(#autocmds_of("fileops_auto_mkdir"), 1, "re-attaching leaves exactly one autocmd behind")

    -- enable = false leaves the group as it was; the feature is simply off.
    drop_group("fileops_auto_mkdir")
    autocmds.attach_auto_mkdir({ enable = false })
    eq(#autocmds_of("fileops_auto_mkdir"), 0, "auto_mkdir = false registers nothing at all")
  end

  -- ── conflict_marks ───────────────────────────────────────────────────────
  do
    local marks = require("fileops.features.conflict_marks")

    marks.setup({ enable = false })
    eq(#autocmds_of("fileops_conflict_marks_on"), 0, "conflict_marks = false registers nothing")

    marks.setup({ enable = true })
    eq(
      events_of("fileops_conflict_marks_on")[1],
      "BufWinEnter",
      "…on, it highlights on BufWinEnter"
    )
    eq(
      events_of("fileops_conflict_marks_off")[1],
      "BufWinLeave",
      "…and clears again on BufWinLeave"
    )

    local dir = H.tmpdir()
    local conflicted = dir .. "conflicted.txt"
    H.write_file(
      conflicted,
      table.concat({
        "<<<<<<< HEAD",
        "ours",
        "=======",
        "theirs",
        ">>>>>>> branch",
      }, "\n")
    )

    vim.cmd("only")
    H.edit(conflicted)
    local ids = vim.w._fileops_conflict_match_ids
    ok(type(ids) == "table" and #ids == 3, "opening a window registers all three marker matches")

    local groups = {}
    for _, m in ipairs(fn.getmatches()) do
      groups[m.group] = (groups[m.group] or 0) + 1
    end
    eq(groups.DiffDelete, 1, "the '<<<<<<<' side uses the configured hl_a group")
    eq(groups.DiffChange, 1, "the '=======' separator uses hl_b")
    eq(groups.DiffAdd, 1, "the '>>>>>>>' side uses hl_c")

    -- Custom highlight groups are honoured.
    marks.setup({ enable = true, hl_a = "ErrorMsg", hl_b = "WarningMsg", hl_c = "Question" })
    vim.cmd("split")
    H.edit(conflicted)
    local custom = {}
    for _, m in ipairs(fn.getmatches()) do
      custom[m.group] = true
    end
    ok(custom.ErrorMsg and custom.WarningMsg and custom.Question, "custom hl groups are used")
    vim.cmd("close")
    vim.cmd("only")

    -- Switching to another buffer drops the previous set before adding the
    -- new one, so the three matches do not pile up per buffer visited.
    marks.setup({ enable = true })
    H.write_file(dir .. "plain.txt", "nothing conflicted here")
    fn.clearmatches()
    H.edit(conflicted)
    eq(#fn.getmatches(), 3, "setup: one set of matches for the current window")
    H.edit(dir .. "plain.txt")
    eq(#fn.getmatches(), 3, "switching buffers deletes the old matches before adding the new ones")
    ok(
      type(vim.w._fileops_conflict_match_ids) == "table",
      "…and the window state records the current set"
    )

    -- Regression: re-editing the SAME file in the same window is a
    -- BufWinEnter with no BufWinLeave in front of it. Three fresh matches were
    -- added and the window variable overwritten, so the previous three could
    -- never be deleted — every `:e` leaked another set for the life of the
    -- window. Invisible (same lines, same groups) but unbounded. The handler
    -- clears the recorded ids before adding its own now.
    H.edit(dir .. "plain.txt")
    eq(#fn.getmatches(), 3, "re-editing the same file replaces the matches instead of leaking")
    H.edit(dir .. "plain.txt")
    eq(#fn.getmatches(), 3, "…however often it is repeated")
    fn.clearmatches()

    drop_group("fileops_conflict_marks_on")
    drop_group("fileops_conflict_marks_off")
  end

  -- ── conflict_marks: gitsuite.nvim delegation (GS-26, optional) ───────────
  do
    local marks = require("fileops.features.conflict_marks")
    local saved = package.loaded["gitsuite.features.conflict"]
    local refresh_calls = {}
    package.loaded["gitsuite.features.conflict"] = {
      refresh = function(bufnr)
        refresh_calls[#refresh_calls + 1] = bufnr
      end,
    }

    marks.setup({ enable = true })
    local dir = H.tmpdir()
    local conflicted = dir .. "conflicted.txt"
    H.write_file(
      conflicted,
      table.concat({ "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch" }, "\n")
    )

    vim.cmd("only")
    H.edit(conflicted)
    eq(#refresh_calls, 1, "with gitsuite.nvim available, BufWinEnter calls its refresh() once")
    eq(refresh_calls[1], vim.api.nvim_get_current_buf(), "...with the current buffer")
    eq(
      vim.w._fileops_conflict_match_ids,
      nil,
      "...and never falls through to fileops' own matchadd path"
    )

    package.loaded["gitsuite.features.conflict"] = saved
    drop_group("fileops_conflict_marks_on")
    drop_group("fileops_conflict_marks_off")
  end

  -- ── on_hold: the event wiring ────────────────────────────────────────────
  -- The preview itself chains `git blame` → `git show` in two subprocesses;
  -- what is checked here is which events the feature claims per configured
  -- mode, and that the guards run without a repo (the spawn is aimed at a
  -- deliberately non-existent executable, so nothing is ever started).
  do
    local on_hold = require("fileops.features.on_hold")
    local prev_updatetime = vim.o.updatetime

    on_hold.setup({ enable = false })
    eq(#autocmds_of("fileops_on_hold_preview"), 0, "on_hold = false registers nothing")
    eq(vim.o.updatetime, prev_updatetime, "…and does not touch 'updatetime' either")

    on_hold.setup({ enable = true, modes = "n" })
    eq(
      table.concat(events_of("fileops_on_hold_preview"), ","),
      "CursorHold",
      "modes = 'n' listens on CursorHold only"
    )
    eq(
      table.concat(events_of("fileops_on_hold_modeclear"), ","),
      "ModeChanged",
      "…plus a ModeChanged autocmd that aborts a pending preview"
    )
    eq(vim.o.updatetime, 100, "on_hold lowers 'updatetime' so CursorHold fires promptly")

    on_hold.setup({ enable = true, modes = "i" })
    eq(
      table.concat(events_of("fileops_on_hold_preview"), ","),
      "CursorHoldI",
      "modes = 'i' listens on CursorHoldI only"
    )

    on_hold.setup({ enable = true, modes = "nvi" })
    eq(
      table.concat(events_of("fileops_on_hold_preview"), ","),
      "CursorHold,CursorHoldI",
      "a mode set spanning insert mode listens on both"
    )

    on_hold.setup({ enable = true, modes = { "v" } })
    eq(
      table.concat(events_of("fileops_on_hold_preview"), ","),
      "CursorHold",
      "an array of modes is accepted as well as a string"
    )

    on_hold.setup({ enable = true, modes = "x" })
    eq(
      table.concat(events_of("fileops_on_hold_preview"), ","),
      "CursorHold",
      "an unmappable mode set still leaves one event, rather than binding nothing"
    )

    on_hold.setup({ enable = true, events_override = { "BufEnter" } })
    eq(
      table.concat(events_of("fileops_on_hold_preview"), ","),
      "BufEnter",
      "events_override replaces the auto-mapped events outright"
    )

    -- Firing it: a scratch buffer is skipped by the buftype guard, a nameless
    -- buffer by the file-name guard, and a real file only gets as far as the
    -- git probe — which is aimed at a command that does not exist.
    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "fileops-no-such-git-executable",
      ignore_buftypes = { "nofile" },
    })
    local dir = H.tmpdir()
    H.write_file(dir .. "held.txt", "one\ntwo")

    vim.cmd("enew")
    vim.bo.buftype = "nofile"
    local fired = pcall(vim.api.nvim_exec_autocmds, "CursorHold", {})
    ok(fired, "CursorHold on an ignored buftype is a silent no-op")

    vim.cmd("enew")
    ok(pcall(vim.api.nvim_exec_autocmds, "CursorHold", {}), "…and on a nameless buffer too")

    H.edit(dir .. "held.txt")
    ok(
      pcall(vim.api.nvim_exec_autocmds, "CursorHold", {}),
      "…and on a real file whose git probe cannot even start"
    )
    vim.wait(100)
    local ns = vim.api.nvim_create_namespace("fileops_on_hold_preview")
    eq(
      #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}),
      0,
      "no preview is rendered when the git probe fails"
    )

    drop_group("fileops_on_hold_preview")
    drop_group("fileops_on_hold_modeclear")
    vim.o.updatetime = prev_updatetime
  end

  -- ── on_hold.ignore_buftypes: ERR-22, degrades instead of crashing on ────
  -- every CursorHold. config.setup() is the real entry point (not
  -- on_hold.setup() directly, as above) so the whole path -- validation,
  -- merge, and the feature module actually receiving the degraded value --
  -- is exercised end to end, matching how bindings/init.lua wires it up.
  do
    local on_hold = require("fileops.features.on_hold")
    local prev_updatetime = vim.o.updatetime

    local cfg = config.setup({
      on_hold = {
        enable = true,
        modes = "n",
        throttle_ms = 0,
        git_cmd = "fileops-no-such-git-executable",
        ignore_buftypes = "nofile",
      },
    })
    local reported = false
    for _, i in ipairs(config.issues()) do
      if i:find("on_hold.ignore_buftypes", 1, true) then
        reported = true
      end
    end
    ok(reported, "config.issues() reports the degraded on_hold.ignore_buftypes")
    ok(
      vim.deep_equal(cfg.on_hold.ignore_buftypes, config.DEFAULTS.on_hold.ignore_buftypes),
      "the degraded on_hold.ignore_buftypes falls back to the default table"
    )
    on_hold.setup(cfg.on_hold)

    vim.cmd("enew")
    vim.bo.buftype = "nofile"
    ok(
      pcall(vim.api.nvim_exec_autocmds, "CursorHold", {}),
      "a non-table on_hold.ignore_buftypes no longer throws on CursorHold"
    )

    drop_group("fileops_on_hold_preview")
    drop_group("fileops_on_hold_modeclear")
    vim.o.updatetime = prev_updatetime
  end

  -- ── gitsuite_events (GS-25) ──────────────────────────────────────────────
  -- No sibling gitsuite.nvim checkout needed: `User GitsuiteBranchSwitched`/
  -- `GitsuiteConflictsResolved` are just events, fired here directly via
  -- nvim_exec_autocmds exactly as gitsuite.nvim's own events.lua does.
  do
    -- `enable = false` only declines to register; it does not remove a group an earlier setup()
    -- (init_api_spec runs it) already created. Start from a clean slate.
    drop_group("fileops_gitsuite_events")
    autocmds.attach_gitsuite_events({ enable = false })
    eq(#autocmds_of("fileops_gitsuite_events"), 0, "gitsuite_events = false registers nothing")

    autocmds.attach_gitsuite_events({ enable = true })
    ok(
      #autocmds_of("fileops_gitsuite_events") > 0,
      "gitsuite_events = true registers at least one autocmd"
    )
    for _, a in ipairs(autocmds_of("fileops_gitsuite_events")) do
      eq(a.event, "User", "...on User")
    end

    local dir = H.tmpdir()
    local seen = {}
    local fc_group = vim.api.nvim_create_augroup("fileops_gitsuite_events_spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = fc_group,
      pattern = "FileopsChanged",
      callback = function(ev)
        seen[#seen + 1] = ev.data
      end,
    })

    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = "GitsuiteBranchSwitched", data = { dir = dir, branch = "feature" } }
    )
    eq(#seen, 1, "a branch switch fires FileopsChanged once")
    eq(seen[1].action, "git-checkout", "...with action git-checkout")
    eq(seen[1].path, dir, "...and the repo dir as path")

    local bufnr = vim.api.nvim_create_buf(false, true)
    local target = dir .. "conflicted.txt"
    vim.api.nvim_buf_set_name(bufnr, target)
    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = "GitsuiteConflictsResolved", data = { bufnr = bufnr } }
    )
    eq(#seen, 2, "a conflict resolution fires FileopsChanged too")
    eq(seen[2].action, "git-conflict-resolved", "...with action git-conflict-resolved")
    ok(seen[2].path:find("conflicted.txt", 1, true) ~= nil, "...and the buffer's own file as path")
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

    seen = {}
    local fired_ok = pcall(
      vim.api.nvim_exec_autocmds,
      "User",
      { pattern = "GitsuiteConflictsResolved", data = { bufnr = 999999 } }
    )
    ok(fired_ok, "an invalid bufnr does not error")
    eq(#seen, 0, "...and fires no FileopsChanged")

    vim.api.nvim_del_augroup_by_id(fc_group)
    drop_group("fileops_gitsuite_events")
  end

  -- ── bindings/init: what gets wired ───────────────────────────────────────
  do
    pcall(vim.api.nvim_del_user_command, "File")
    ok(fn.exists(":File") == 0, "setup: the :File command is gone for this case")

    require("fileops.bindings").setup(vim.tbl_deep_extend("force", config.setup({}), {
      commands = false,
      auto_mkdir = { enable = false },
      on_hold = { enable = false },
      conflict_marks = { enable = false },
    }))
    eq(fn.exists(":File"), 0, "commands = false leaves the :File command unregistered")
    ok(
      #require("lib.nvim.bindings.keymap").registered("fileops") > 0,
      "…but the keymaps are still declared"
    )

    require("fileops.bindings").setup(config.setup({
      auto_mkdir = { enable = false },
      on_hold = { enable = false },
      conflict_marks = { enable = false },
    }))
    eq(fn.exists(":File"), 2, "the default config registers :File")
    eq(#autocmds_of("fileops_auto_mkdir"), 0, "…and honours the disabled feature switches")
    eq(#autocmds_of("fileops_on_hold_preview"), 0, "…for on_hold too")
    eq(#autocmds_of("fileops_conflict_marks_on"), 0, "…and for conflict_marks")

    config.setup({})
  end
end

return function(H)
  H.run_preserved(spec)
end
