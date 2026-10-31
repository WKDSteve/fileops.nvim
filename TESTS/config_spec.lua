-- TESTS/config_spec.lua — config merge (DEFAULTS + user options).

local function spec(H)
  local eq, ok = H.eq, H.ok
  local config = require("fileops.config")

  -- defaults
  config.setup({})
  local d = config.get()
  eq(d.cycle.open_target, "replace", "default cycle.open_target")
  eq(d.cd.scope, "window", "default cd.scope")
  eq(d.delete.mode, "trash", "default delete.mode")
  eq(d.delete.on_before_delete, nil, "default delete.on_before_delete")
  eq(d.keymaps.cycle, true, "default keymaps.cycle")
  eq(d.keymaps.lhs.next_replace, "<leader>nf", "default keymaps.lhs.next_replace")
  ok(type(d.keymaps.lhs) == "table", "keymaps.lhs is a table")

  -- The keys added 2026-08-24 are deliberately unset: their actions were
  -- command-only, and making a keymap *possible* is a different thing from
  -- claiming a key for it. If a default ever appears here it should be a
  -- decision, not a slip.
  for _, key in ipairs({
    "next_filtered",
    "prev_filtered",
    "delete_force",
    "path",
    "cd",
    "info",
    "lockinfo",
    "bulk_rename",
  }) do
    eq(d.keymaps.lhs[key], nil, ("keymaps.lhs.%s has no default"):format(key))
  end
  eq(d.auto_mkdir.enable, true, "default auto_mkdir.enable")
  eq(d.auto_mkdir.skip_remote, true, "default auto_mkdir.skip_remote")
  eq(d.on_hold.enable, false, "default on_hold.enable (opt-in)")
  eq(d.on_hold.throttle_ms, 1200, "default on_hold.throttle_ms")
  eq(d.conflict_marks.enable, true, "default conflict_marks.enable")
  eq(d.conflict_marks.hl_a, "DiffDelete", "default conflict_marks.hl_a")

  -- opting in / toggling off
  config.setup({ on_hold = { enable = true }, conflict_marks = { enable = false } })
  local t = config.get()
  eq(t.on_hold.enable, true, "on_hold can be explicitly enabled")
  eq(t.conflict_marks.enable, false, "conflict_marks can be disabled")

  -- shallow override
  config.setup({ commands = false, cd = { scope = "global" } })
  local o = config.get()
  eq(o.commands, false, "override commands")
  eq(o.cd.scope, "global", "override nested cd.scope")
  -- untouched sibling keeps its default
  eq(o.cd.refresh_explorers, true, "untouched sibling key keeps default")

  -- delete.mode override + on_before_delete hook is passed through as-is
  local hook = function()
    return true
  end
  config.setup({ delete = { mode = "trash", on_before_delete = hook } })
  local dd = config.get()
  eq(dd.delete.mode, "trash", "override delete.mode")
  eq(dd.delete.on_before_delete, hook, "override delete.on_before_delete")

  -- nested keymaps.lhs deep-merge: only the touched key changes
  config.setup({ keymaps = { lhs = { next_replace = false, delete = "<leader>XX" } } })
  local k = config.get()
  eq(k.keymaps.lhs.next_replace, false, "explicit disable applied")
  eq(k.keymaps.lhs.delete, "<leader>XX", "explicit remap applied")
  eq(k.keymaps.lhs.prev_replace, "<leader>pf", "untouched lhs key keeps default")
  eq(k.keymaps.cycle, true, "master switch untouched by lhs override")

  -- ERR-50: an unknown top-level key, and an unknown key nested one level
  -- deep, are both dropped before the merge instead of surviving as dead
  -- fields next to the real option -- and reported via issues().
  local function has_issue(needle)
    for _, i in ipairs(config.issues()) do
      if i:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  config.setup({ delete = { mode2 = "trash" }, cycle = { open_taget = "split" } })
  local u = config.get()
  eq(u.delete.mode, "trash", "the unknown delete.mode2 didn't reach the merge")
  eq(u.cycle.open_target, "replace", "the unknown cycle.open_taget didn't reach the merge")
  eq(u.delete.mode2, nil, "delete.mode2 was not written into the active config")
  ok(has_issue("mode2"), "issues() names the unknown delete.mode2 key")
  ok(has_issue("did you mean"), "…with a did-you-mean hint for a close typo")

  -- ERR-22: an invalid delete.mode degrades to the default instead of to its
  -- opposite, and is reported the same way.
  config.setup({ delete = { mode = "Trash" } })
  eq(config.get().delete.mode, "trash", "an invalid delete.mode falls back to the default")
  ok(has_issue("delete.mode"), "issues() names the rejected delete.mode value")

  -- ERR-22: retry.attempts/backoff_ms of the wrong type or out of range
  -- degrade to their defaults instead of reaching
  -- lib.nvim.cross.fs.mutate's unguarded `math.max(1, attempts)` /
  -- `backoff_ms * math.pow(...)` -- a non-number `attempts` crashes the
  -- former outright, not just a zero/negative one.
  config.setup({ retry = { attempts = "six", backoff_ms = -5 } })
  local rt = config.get().retry
  eq(
    rt.attempts,
    config.DEFAULTS.retry.attempts,
    "non-number retry.attempts falls back to the default"
  )
  eq(
    rt.backoff_ms,
    config.DEFAULTS.retry.backoff_ms,
    "negative retry.backoff_ms falls back to the default"
  )
  ok(has_issue("retry.attempts"), "issues() names the rejected retry.attempts value")
  ok(has_issue("retry.backoff_ms"), "issues() names the rejected retry.backoff_ms value")

  config.setup({ retry = { attempts = 0 } })
  eq(
    config.get().retry.attempts,
    config.DEFAULTS.retry.attempts,
    "zero retry.attempts falls back to the default"
  )
  ok(has_issue("retry.attempts"), "issues() names the rejected zero retry.attempts")

  config.setup({ retry = { attempts = 3 } })
  eq(config.get().retry.attempts, 3, "a valid retry.attempts is kept as-is")
  eq(#config.issues(), 0, "a valid retry.attempts reports no issue")

  -- ERR-22: on_hold.modes of the wrong type degrades to the default instead
  -- of reaching features/on_hold.lua's unguarded `ipairs(modes)` -- which
  -- crashes for anything that isn't a string, during on_hold.setup() itself
  -- (i.e. plugin init, as soon as on_hold.enable = true), not just later.
  config.setup({ on_hold = { modes = 5 } })
  eq(
    config.get().on_hold.modes,
    config.DEFAULTS.on_hold.modes,
    "non-string/table on_hold.modes falls back to the default"
  )
  ok(has_issue("on_hold.modes"), "issues() names the rejected on_hold.modes value")

  config.setup({ on_hold = { modes = "nv" } })
  eq(config.get().on_hold.modes, "nv", "a valid string on_hold.modes is kept as-is")
  eq(#config.issues(), 0, "a valid on_hold.modes reports no issue")

  config.setup({ on_hold = { modes = { "n", "v" } } })
  eq(config.get().on_hold.modes[1], "n", "a valid array on_hold.modes is kept as-is")
  eq(#config.issues(), 0, "a valid array on_hold.modes reports no issue")

  -- ERR-22: on_hold.ignore_buftypes of the wrong type degrades to the
  -- default instead of reaching features/on_hold.lua's unguarded
  -- `vim.tbl_contains(ignore_buftypes, bt)` -- which crashes for any
  -- truthy non-table (a string included), and since that call runs on
  -- every CursorHold, not just once during setup, an unvalidated value
  -- would otherwise repeat the crash indefinitely.
  config.setup({ on_hold = { ignore_buftypes = "nofile" } })
  ok(
    vim.deep_equal(config.get().on_hold.ignore_buftypes, config.DEFAULTS.on_hold.ignore_buftypes),
    "non-table on_hold.ignore_buftypes falls back to the default"
  )
  ok(
    has_issue("on_hold.ignore_buftypes"),
    "issues() names the rejected on_hold.ignore_buftypes value"
  )

  config.setup({ on_hold = { ignore_buftypes = { "nofile", "terminal" } } })
  eq(
    config.get().on_hold.ignore_buftypes[1],
    "nofile",
    "a valid on_hold.ignore_buftypes table is kept as-is"
  )
  eq(#config.issues(), 0, "a valid on_hold.ignore_buftypes reports no issue")

  -- clean setup() reports no issues
  config.setup({})
  eq(#config.issues(), 0, "a clean setup() call reports no issues")

  -- ERR-53: a sub-table reference a consumer captured (the shape
  -- bindings.autocmds hands to on_hold/auto_mkdir/conflict_marks) survives a
  -- second setup() call -- the merge mutates it in place instead of
  -- replacing it, so the reference doesn't go stale.
  local held_on_hold = config.get().on_hold
  config.setup({ on_hold = { enable = true, throttle_ms = 500 } })
  ok(held_on_hold == config.get().on_hold, "on_hold keeps its table identity across setup()")
  eq(held_on_hold.enable, true, "…and the held reference sees the new value")
  eq(held_on_hold.throttle_ms, 500, "…for every field that changed")

  -- reset
  config.setup({})
end

return function(H)
  H.run_preserved(spec)
end
