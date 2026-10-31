-- TESTS/init_api_spec.lua — the plugin entry point: `fileops.setup()` and the
-- public Lua API every function of which is a thin, notify-reporting wrapper
-- around an ops function. Thin is exactly why they are worth a spec: each one
-- has to pick the right op, pass the arguments through, and relay the result.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local fn = vim.fn
  local fileops = require("fileops")
  local config = require("fileops.config")

  -- ── setup ────────────────────────────────────────────────────────────────
  do
    -- The ambient features stay off on purpose: `conflict_marks` would add a
    -- `matchadd` to every window entered for the rest of the suite, and
    -- `on_hold` would put a git probe on every CursorHold.
    fileops.setup({
      cd = { scope = "global" },
      conflict_marks = { enable = false },
      on_hold = { enable = false },
      auto_mkdir = { enable = false },
    })

    eq(vim.g.loaded_fileops, 1, "setup sets the loaded guard the plugin file checks")
    eq(config.get().cd.scope, "global", "setup stores the merged config")
    eq(fn.exists(":File"), 2, "setup registers the :File command")

    -- Idempotent by design: a second call (a second plugin manager entry, a
    -- re-sourced config) must not re-register anything or change the config
    -- out from under the bindings that already captured it.
    fileops.setup({ cd = { scope = "window" } })
    eq(config.get().cd.scope, "global", "a second setup() call is a no-op, config included")

    config.setup({ delete = { mode = "permanent" } })
  end

  -- ── the file API ─────────────────────────────────────────────────────────
  do
    local dir = H.tmpdir()

    vim.cmd("enew")
    local created = dir .. "api/new.txt"
    local notes = H.notifications(function()
      eq(fileops.new_file(created), true, "new_file returns the op's ok")
    end)
    ok(H.notified(notes, "created"), "new_file reports through notify")
    eq(fn.fnamemodify(fn.expand("%:p"), ":t"), "new.txt", "new_file named the buffer")

    eq(fileops.touch(dir .. "api/touched.txt"), true, "touch returns ok")
    eq(fn.filereadable(dir .. "api/touched.txt"), 1, "touch created the file")

    H.edit(dir .. "api/touched.txt")
    eq(fileops.rename("renamed.txt"), true, "rename returns ok")
    eq(fn.expand("%:t"), "renamed.txt", "rename moved the buffer's file")

    eq(fileops.copy(dir .. "api/copied.txt"), true, "copy returns ok")
    eq(fn.filereadable(dir .. "api/copied.txt"), 1, "copy created the copy")
    eq(fn.expand("%:t"), "renamed.txt", "copy did not open it")

    eq(fileops.duplicate(dir .. "api/duplicated.txt"), true, "duplicate returns ok")
    eq(fn.expand("%:t"), "duplicated.txt", "duplicate opened the copy")

    eq(fileops.move(dir .. "api/sub/moved.txt"), true, "move returns ok")
    eq(fn.filereadable(dir .. "api/sub/moved.txt"), 1, "move moved the file")

    eq(fileops.copy_path("name"), true, "copy_path returns ok")
    eq(fn.getreg('"'), "moved.txt", "copy_path wrote the requested representation")

    eq(fileops.info(), true, "info returns ok")

    local prev_cwd = fn.getcwd()
    eq(fileops.cd_here({ scope = "cd", refresh = false }), true, "cd_here returns ok")
    eq(
      vim.fs.normalize(fn.getcwd()),
      vim.fs.normalize(fn.fnamemodify(dir .. "api/sub", ":p:h")),
      "cd_here changed the working directory"
    )
    vim.cmd("cd " .. fn.fnameescape(prev_cwd))

    eq(
      fileops.delete_current({ mode = "permanent", force = true }),
      true,
      "delete_current returns ok"
    )
    eq(fn.filereadable(dir .. "api/sub/moved.txt"), 0, "delete_current deleted the file")

    -- A failing op comes back as `false`, reported at error level rather than
    -- raised — the whole point of the (ok, msg) contract these wrappers relay.
    vim.cmd("enew")
    local failed = H.notifications(function()
      eq(fileops.rename("nowhere.txt"), false, "rename on a nameless buffer returns false")
      eq(fileops.info(), false, "info on a nameless buffer returns false")
      eq(fileops.copy_path(), false, "copy_path on a nameless buffer returns false")
      eq(fileops.cd_here(), false, "cd_here on a nameless buffer returns false")
    end)
    ok(H.notified(failed, "no file name"), "the failures are reported, not raised")
  end

  -- ── the cycle API ────────────────────────────────────────────────────────
  do
    local dir = H.tmpdir()
    H.write_file(dir .. "a.lua", "-- a")
    H.write_file(dir .. "b.lua", "-- b")
    H.write_file(dir .. "c.lua", "-- c")
    H.write_file(dir .. "d.md", "-- d")

    H.edit(dir .. "a.lua")
    eq(fileops.next({ open_target = "current" }), true, "next returns ok")
    eq(fn.expand("%:t"), "b.lua", "next moved to the following file")
    eq(fileops.prev({ open_target = "current" }), true, "prev returns ok")
    eq(fn.expand("%:t"), "a.lua", "prev moved back")

    eq(fileops.next({ open_target = "current" }, 2), true, "next accepts a count")
    eq(fn.expand("%:t"), "c.lua", "…and steps that many entries")

    eq(fileops.last({ open_target = "current" }), true, "last returns ok")
    eq(fn.expand("%:t"), "d.md", "last jumps to the final entry")
    eq(fileops.first({ open_target = "current" }), true, "first returns ok")
    eq(fn.expand("%:t"), "a.lua", "first jumps to the initial entry")

    -- Per-call opts are merged over the configured cycle options rather than
    -- replacing them: the pattern below narrows the listing while everything
    -- else (wrap, case_insensitive, …) still comes from the config.
    eq(fileops.next({ open_target = "current", pattern = "*.md" }), true, "next with a filter")
    eq(fn.expand("%:t"), "d.md", "…walks only the matching files")

    vim.cmd("only")
    eq(fileops.open({ open_target = "split" }), true, "open returns ok")
    eq(#vim.api.nvim_list_wins(), 2, "open reopened the current file in a split")
    vim.wait(100)
    vim.cmd("only")

    vim.cmd("enew")
    local warned = H.notifications(function()
      eq(fileops.next(), false, "next on a nameless buffer returns false")
      eq(fileops.prev(), false, "prev on a nameless buffer returns false")
      eq(fileops.first(), false, "first on a nameless buffer returns false")
      eq(fileops.last(), false, "last on a nameless buffer returns false")
      eq(fileops.open(), false, "open on a nameless buffer returns false")
    end)
    ok(H.notified(warned, "no file name"), "…each one saying why")
  end

  -- ── diagnose_lock ────────────────────────────────────────────────────────
  do
    local dir = H.tmpdir()
    H.write_file(dir .. "locked.txt", "x")
    H.edit(dir .. "locked.txt")

    local restore = H.stub("lib.nvim.cross.fs.lock", {
      report = function(_, cb)
        cb({ "holder: none" })
      end,
    })

    -- Without a callback the public entry point supplies the notify-based one.
    local reported = H.notifications(function()
      fileops.diagnose_lock()
    end)
    ok(H.notified(reported, "holder: none"), "diagnose_lock defaults to reporting via notify")

    local got = nil
    fileops.diagnose_lock(function(_, msg)
      got = msg
    end)
    eq(got, "holder: none", "an explicit callback receives the report instead")

    restore()
  end
end

return function(H)
  H.run_preserved(spec)
end
