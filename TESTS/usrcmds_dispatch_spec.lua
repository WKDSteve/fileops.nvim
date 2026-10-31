-- TESTS/usrcmds_dispatch_spec.lua — bindings/usrcmds.lua: the whole `:File[!]`
-- surface. Every subcommand is driven through the real Ex command (composer
-- parses the line, binds the positionals and calls the route), so what is
-- under test is the command as a user types it, not an internal function.
--
-- Two things are stubbed, both at `package.loaded` and both restored:
--   * `ui.kit`      — ui.nvim is not on this suite's runtimepath and CI checks
--                     out only lib.nvim, so the prompts/dialogs are driven
--                     from here. `usrcmds` resolves it lazily, inside the
--                     dispatch, so the stub is what it finds.
--   * `lib.nvim.fs.trash` / `lib.nvim.cross.fs.lock` — both spawn an OS
--                     process. The spec asserts what fileops hands them.
-- No fixture lives outside `vim.fn.tempname()`.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local fn = vim.fn
  local config = require("fileops.config")
  local usrcmds = require("fileops.bindings.usrcmds")

  -- Prompt/dialog double. `answers.input` / `answers.confirm` are set per
  -- case; `calls` records what the command asked for.
  local answers = {}
  local calls = {}
  local restore_kit = H.stub("ui.kit", {
    input = function(o)
      calls[#calls + 1] = { kind = "input", title = o.title, default = o.default }
      if answers.input ~= nil then
        o.on_submit(answers.input)
      end
    end,
    confirm = function(o)
      calls[#calls + 1] = { kind = "confirm", question = o.question, choices = o.choices }
      -- What happens on disk while the dialog is open (it is asynchronous).
      if answers.while_open then
        answers.while_open()
      end
      if answers.confirm ~= nil then
        o.on_answer(answers.confirm == true and o.choices[1] or answers.confirm)
      end
    end,
  })

  local function reset()
    answers = {}
    calls = {}
  end

  -- The suite runs headless, where `nvim_list_uis()` is empty and a dialog
  -- nobody can answer is never opened (the bulk rename refuses instead). The
  -- dialogs here are answered by the double above, so there is a UI as far
  -- as the command can tell; the no-UI path is checked on its own below.
  local real_list_uis = vim.api.nvim_list_uis
  local ui_attached = true
  vim.api.nvim_list_uis = function()
    return ui_attached and { {} } or {}
  end

  config.setup({ delete = { mode = "permanent" } })
  usrcmds.register()

  local dir = H.tmpdir()

  -- ── create / name / write ────────────────────────────────────────────────
  do
    reset()
    vim.cmd("enew")
    vim.cmd("File new " .. fn.fnameescape(dir .. "created/named.txt"))
    eq(fn.fnamemodify(fn.expand("%:p"), ":t"), "named.txt", ":File new renames the buffer")
    eq(fn.filereadable(dir .. "created/named.txt"), 0, ":File new does not write the file")

    vim.cmd("File write")
    -- `:File write` with no path prompts; nothing was answered, so nothing
    -- happened — a cancelled prompt is a silent no-op by design.
    eq(calls[#calls].kind, "input", ":File write with no argument prompts")
    eq(calls[#calls].title, "File write: ", "…with the subcommand's own prompt title")
    eq(fn.filereadable(dir .. "created/named.txt"), 0, "a cancelled prompt writes nothing")

    reset()
    answers.input = dir .. "created/prompted.txt"
    vim.cmd("File write")
    eq(fn.filereadable(dir .. "created/prompted.txt"), 1, "an answered prompt writes the file")

    reset()
    vim.cmd("File saveas " .. fn.fnameescape(dir .. "created/saved.txt"))
    eq(fn.filereadable(dir .. "created/saved.txt"), 1, ":File saveas writes the destination")
    eq(fn.expand("%:t"), "saved.txt", ":File saveas re-points the buffer")

    vim.cmd("File writeto " .. fn.fnameescape(dir .. "created/side.txt"))
    eq(fn.filereadable(dir .. "created/side.txt"), 1, ":File writeto writes the destination")
    eq(fn.expand("%:t"), "saved.txt", ":File writeto leaves the buffer name alone")

    -- mkdir acts on the current buffer's parent, with no argument at all.
    vim.fn.delete(dir .. "created", "rf")
    vim.cmd("File mkdir")
    eq(fn.isdirectory(dir .. "created"), 1, ":File mkdir re-creates the buffer's parent directory")
  end

  -- ── touch ────────────────────────────────────────────────────────────────
  do
    reset()
    local target = dir .. "touched.txt"
    vim.cmd("File touch " .. fn.fnameescape(target))
    eq(fn.filereadable(target), 1, ":File touch creates the file")

    reset()
    answers.input = "prompted_touch.txt"
    local prev_cwd = fn.getcwd()
    local cwd_dir = H.tmpdir()
    vim.cmd("cd " .. fn.fnameescape(cwd_dir))
    vim.cmd("File touch")
    vim.cmd("cd " .. fn.fnameescape(prev_cwd))
    eq(calls[1].title, "File touch: ", ":File touch prompts with its own title")
    eq(fn.filereadable(cwd_dir .. "prompted_touch.txt"), 1, "…and uses the answer")
  end

  -- ── rename / move: the `%` form, the prompt default, the bang ────────────
  do
    reset()
    local src = dir .. "rename_me.txt"
    H.write_file(src, "content")
    H.edit(src)

    -- `:File rename %  dest` and `:File rename dest` mean the same thing: the
    -- `%` is the implied scope, not a destination.
    vim.cmd("File rename % renamed_via_percent.txt")
    eq(
      fn.expand("%:t"),
      "renamed_via_percent.txt",
      ":File rename % <dest> renames the buffer's file"
    )
    eq(fn.filereadable(dir .. "renamed_via_percent.txt"), 1, "…and the file on disk")
    eq(fn.filereadable(src), 0, "…and the old name is gone")

    reset()
    vim.cmd("File rename")
    eq(calls[1].kind, "input", ":File rename with no destination prompts")
    eq(
      calls[1].default,
      "renamed_via_percent.txt",
      "…pre-filled with the current file name, so it is edited rather than retyped"
    )

    reset()
    answers.input = "renamed_via_prompt.txt"
    vim.cmd("File rename")
    eq(fn.expand("%:t"), "renamed_via_prompt.txt", "the answered rename prompt is applied")

    -- move keeps the buffer's content/undo history; rename reloads it.
    reset()
    H.write_file(dir .. "movable.txt", "one")
    H.edit(dir .. "movable.txt")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one edited" })
    vim.cmd("File move " .. fn.fnameescape(dir .. "moved/there.txt"))
    eq(fn.expand("%:t"), "there.txt", ":File move re-points the buffer")
    eq(fn.filereadable(dir .. "moved/there.txt"), 1, ":File move created the missing directory")
    eq(fn.getline(1), "one edited", ":File move did not reload the buffer from disk")

    -- Overwriting without the bang triggers a confirm instead of just
    -- failing -- and only actually overwrites once that confirm says yes.
    reset()
    H.write_file(dir .. "occupied.txt", "occupied")
    vim.cmd("File move " .. fn.fnameescape(dir .. "occupied.txt"))
    eq(#calls, 1, "moving onto an existing file without ! asks for confirmation")
    eq(calls[1].kind, "confirm", "…via ui.kit.confirm")
    ok(
      calls[1].question:find("destination already exists", 1, true) ~= nil,
      "…mentioning the existing destination"
    )
    eq(
      fn.readfile(dir .. "occupied.txt")[1],
      "occupied",
      "…and leaves the destination untouched until answered"
    )

    reset()
    answers.confirm = true
    vim.cmd("File move " .. fn.fnameescape(dir .. "occupied.txt"))
    eq(fn.readfile(dir .. "occupied.txt")[1], "one edited", "…confirming the dialog overwrites")

    -- The bang still bypasses the confirm entirely -- no dialog needed to
    -- overwrite what the user already said `!` to.
    reset()
    H.write_file(dir .. "occupied2.txt", "occupied2")
    H.write_file(dir .. "movable2.txt", "fresh content")
    H.edit(dir .. "movable2.txt")
    vim.cmd("File! move " .. fn.fnameescape(dir .. "occupied2.txt"))
    eq(#calls, 0, ":File! move skips the confirm")
    eq(fn.readfile(dir .. "occupied2.txt")[1], "fresh content", "…and overwrites anyway")
  end

  -- ── duplicate / copy ─────────────────────────────────────────────────────
  do
    reset()
    local src = dir .. "original.txt"
    H.write_file(src, "original")
    H.edit(src)

    vim.cmd("File duplicate " .. fn.fnameescape(dir .. "duplicate.txt"))
    eq(fn.filereadable(dir .. "duplicate.txt"), 1, ":File duplicate copies the file")
    eq(fn.expand("%:t"), "duplicate.txt", ":File duplicate opens the copy")

    H.edit(src)
    vim.cmd("File copy " .. fn.fnameescape(dir .. "copied.txt"))
    eq(fn.filereadable(dir .. "copied.txt"), 1, ":File copy copies the file")
    eq(fn.expand("%:t"), "original.txt", ":File copy does NOT open the copy")

    reset()
    answers.input = dir .. "prompted_copy.txt"
    vim.cmd("File copy")
    eq(calls[1].title, "File copy: ", ":File copy with no destination prompts")
    eq(fn.filereadable(dir .. "prompted_copy.txt"), 1, "…and copies to the answer")
  end

  -- ── delete: the configured mode is what reaches the ops layer ────────────
  do
    reset()
    local victim = dir .. "deletable.txt"
    H.write_file(victim, "bye")
    H.edit(victim)
    vim.cmd("File delete")
    eq(fn.filereadable(victim), 0, ":File delete removes the file (delete.mode = permanent)")

    -- Same command, `delete.mode = "trash"`: the OS trash backend is what must
    -- be reached, and with the file's own absolute path.
    local trashed = nil
    local restore_trash = H.stub("lib.nvim.fs.trash", {
      trash_blocking = function(path)
        trashed = path
        fn.delete(path)
        return true, nil
      end,
    })
    config.setup({ delete = { mode = "trash" } })
    local trash_victim = dir .. "trash_me.txt"
    H.write_file(trash_victim, "bye")
    H.edit(trash_victim)
    vim.cmd("File delete")
    config.setup({ delete = { mode = "permanent" } })
    restore_trash()

    eq(
      trashed,
      fn.fnamemodify(trash_victim, ":p"),
      "delete.mode = 'trash' routes :File delete through the OS trash"
    )

    -- Without a bang, a modified buffer triggers an interactive confirm
    -- instead of just refusing — and only actually deletes once that
    -- confirm comes back "yes".
    reset()
    local dirty = dir .. "dirty.txt"
    H.write_file(dirty, "saved")
    H.edit(dirty)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
    vim.cmd("File delete")
    eq(#calls, 1, ":File delete on a modified buffer asks for confirmation")
    eq(calls[1].kind, "confirm", "…via ui.kit.confirm")
    ok(calls[1].question:find("unsaved", 1, true) ~= nil, "…mentioning the unsaved changes")
    eq(fn.filereadable(dirty), 1, "…and leaves the file alone until answered")

    reset()
    answers.confirm = true
    vim.cmd("File delete")
    eq(fn.filereadable(dirty), 0, "…confirming the dialog deletes it")

    -- The bang still bypasses the confirm entirely -- no dialog needed to
    -- force-close what the user already said `!` to.
    reset()
    local dirty2 = dir .. "dirty2.txt"
    H.write_file(dirty2, "saved")
    H.edit(dirty2)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
    vim.cmd("File! delete")
    eq(#calls, 0, ":File! delete skips the confirm")
    eq(fn.filereadable(dirty2), 0, "…and deletes it anyway")
  end

  -- ── cd ───────────────────────────────────────────────────────────────────
  do
    reset()
    local cd_dir = H.tmpdir()
    H.write_file(cd_dir .. "here.txt", "x")
    local prev_cwd = fn.getcwd()
    H.edit(cd_dir .. "here.txt")

    vim.cmd("File cd global")
    eq(
      vim.fs.normalize(fn.getcwd()),
      vim.fs.normalize(fn.fnamemodify(cd_dir, ":p:h")),
      ":File cd global changes the global cwd to the buffer's directory"
    )

    vim.cmd("cd " .. fn.fnameescape(prev_cwd))
    vim.cmd("File cd")
    eq(
      vim.fs.normalize(fn.getcwd()),
      vim.fs.normalize(fn.fnamemodify(cd_dir, ":p:h")),
      ":File cd with no argument uses the configured scope (window → :lcd)"
    )
    eq(fn.haslocaldir(), 1, "…which really is a window-local cd")

    vim.cmd("cd " .. fn.fnameescape(prev_cwd))
    vim.cmd("File cd tab")
    eq(fn.haslocaldir(-1, 0), 1, ":File cd tab sets a tab-local directory")
    vim.cmd("cd " .. fn.fnameescape(prev_cwd))
    eq(vim.fs.normalize(fn.getcwd()), vim.fs.normalize(prev_cwd), "cleanup: cwd restored")

    -- A configured default scope is honoured when the command names none.
    config.setup({ delete = { mode = "permanent" }, cd = { scope = "global" } })
    vim.cmd("File cd")
    eq(fn.haslocaldir(), 0, "cd.scope = 'global' makes the bare :File cd a global :cd")
    vim.cmd("cd " .. fn.fnameescape(prev_cwd))
    config.setup({ delete = { mode = "permanent" } })
  end

  -- ── next / prev / first / last / open ────────────────────────────────────
  do
    reset()
    local ndir = H.tmpdir()
    H.write_file(ndir .. "a.lua", "-- a")
    H.write_file(ndir .. "b.lua", "-- b")
    H.write_file(ndir .. "c.md", "-- c")

    H.edit(ndir .. "a.lua")
    vim.cmd("File next")
    eq(fn.expand("%:t"), "b.lua", ":File next walks the directory listing")
    vim.cmd("File prev")
    eq(fn.expand("%:t"), "a.lua", ":File prev walks it back")

    -- A glob in the first slot is a filter, not a target keyword.
    vim.cmd("File next *.md")
    eq(fn.expand("%:t"), "c.md", ":File next <glob> filters the listing")

    -- A target keyword in the first slot shifts the glob to the second.
    H.edit(ndir .. "a.lua")
    vim.cmd("File next stay *.lua")
    eq(fn.expand("%:t"), "b.lua", ":File next <target> <glob> applies both")

    -- A count prefix steps that many entries.
    H.edit(ndir .. "a.lua")
    vim.cmd("2File next")
    eq(fn.expand("%:t"), "c.md", ":2File next steps twice")

    H.edit(ndir .. "b.lua")
    vim.cmd("File first")
    eq(fn.expand("%:t"), "a.lua", ":File first jumps to the first entry")
    vim.cmd("File last")
    eq(fn.expand("%:t"), "c.md", ":File last jumps to the last entry")

    -- open reopens the current file in another window target.
    vim.cmd("only")
    H.edit(ndir .. "a.lua")
    vim.cmd("File open split")
    eq(#vim.api.nvim_list_wins(), 2, ":File open <target> opens the current file in a split")
    vim.wait(100)
    vim.cmd("only")

    -- A nameless buffer has no directory to walk, and says so rather than
    -- failing silently.
    vim.cmd("enew")
    local warned = H.notifications(function()
      vim.cmd("File next")
    end)
    ok(H.notified(warned, "no file name"), ":File next on a nameless buffer explains itself")
  end

  -- ── path / info / lockinfo / help ────────────────────────────────────────
  do
    reset()
    local pdir = H.tmpdir()
    H.write_file(pdir .. "info.txt", "0123456789")
    H.edit(pdir .. "info.txt")

    vim.cmd("File path name")
    eq(fn.getreg('"'), "info.txt", ":File path <mode> copies that representation")
    vim.cmd("File path")
    eq(fn.getreg('"'), fn.fnamemodify(pdir .. "info.txt", ":p"), ":File path defaults to abs")

    local info = H.notifications(function()
      vim.cmd("File info")
    end)
    ok(H.notified(info, "10 bytes"), ":File info reports the file's size")

    local asked_for = nil
    local restore_lock = H.stub("lib.nvim.cross.fs.lock", {
      report = function(path, cb)
        asked_for = path
        cb({ "holder: nobody" })
      end,
    })
    local lock_out = H.notifications(function()
      vim.cmd("File lockinfo")
    end)
    eq(
      asked_for,
      fn.fnamemodify(pdir .. "info.txt", ":p"),
      ":File lockinfo diagnoses the current buffer's file by default"
    )
    ok(H.notified(lock_out, "holder: nobody"), ":File lockinfo relays the report")

    local other = pdir .. "other.txt"
    H.write_file(other, "x")
    vim.cmd("File lockinfo " .. fn.fnameescape(other))
    eq(asked_for, fn.fnamemodify(other, ":p"), ":File lockinfo <path> diagnoses that path instead")
    restore_lock()

    local help = H.notifications(function()
      vim.cmd("File help")
    end)
    ok(H.notified(help, ":File[!] {subcommand}"), ":File help prints the usage block")
    ok(H.notified(help, "bulk rename"), "…listing every subcommand, including the nested one")
  end

  -- ── bulk rename ──────────────────────────────────────────────────────────
  do
    reset()
    local bdir = H.tmpdir()
    H.write_file(bdir .. "note_1.txt", "1")
    H.write_file(bdir .. "note_2.txt", "2")
    H.edit(bdir .. "note_1.txt")

    -- Preview first, and nothing happens until the dialog is answered.
    local preview = H.notifications(function()
      vim.cmd("File bulk rename ^note_ memo_")
    end)
    eq(calls[#calls].kind, "confirm", ":File bulk rename asks before renaming anything")
    ok(H.notified(preview, "note_1.txt → memo_1.txt"), "…after previewing every planned rename")
    eq(fn.filereadable(bdir .. "note_1.txt"), 1, "an unanswered dialog renames nothing")

    reset()
    answers.confirm = "Cancel"
    vim.cmd("File bulk rename ^note_ memo_")
    eq(fn.filereadable(bdir .. "note_1.txt"), 1, "cancelling the dialog renames nothing")

    reset()
    answers.confirm = true -- the first choice, "Rename N file(s)"
    local open_buf = vim.api.nvim_get_current_buf()
    local done = H.notifications(function()
      vim.cmd("File bulk rename ^note_ memo_")
    end)
    eq(fn.filereadable(bdir .. "memo_1.txt"), 1, "confirming renames the files")
    eq(fn.filereadable(bdir .. "memo_2.txt"), 1, "…all of them")
    ok(H.notified(done, "2 file(s) renamed"), "…and reports how many")

    -- Regression, in the shape a user meets it: on Windows the buffer was left
    -- pointing at a file that no longer existed, because the plan's paths and
    -- the buffer name disagreed on one separator (see bulk_edge_spec.lua).
    -- `execute` normalizes both sides of that comparison now.
    eq(
      fn.fnamemodify(vim.api.nvim_buf_get_name(open_buf), ":t"),
      "memo_1.txt",
      ":File bulk rename re-points the open buffer"
    )
    eq(fn.filereadable(vim.api.nvim_buf_get_name(open_buf)), 1, "…onto a file that exists")

    -- Nothing matched: a plain message, and no dialog.
    reset()
    local none = H.notifications(function()
      vim.cmd("File bulk rename ^zzz_ yyy_")
    end)
    eq(#calls, 0, "a plan with no matches never opens the confirm dialog")
    ok(H.notified(none, "no files in"), "…and says that nothing matched")

    -- An invalid Lua pattern is reported as such.
    reset()
    local bad = H.notifications(function()
      vim.cmd("File bulk rename [unclosed x")
    end)
    eq(#calls, 0, "an invalid pattern never opens the confirm dialog")
    ok(H.notified(bad, "invalid pattern"), "…and the error names the pattern")
  end

  -- ── bulk rename onto existing destinations: asked, not refused (UI-05) ───
  do
    local cdir = H.tmpdir()
    local function body(name)
      return table.concat(fn.readfile(cdir .. name), "\n")
    end
    local function seed()
      for _, n in ipairs({ "a_1.txt", "a_2.txt", "a_3.txt" }) do
        H.write_file(cdir .. n, "new " .. n)
      end
      H.write_file(cdir .. "b_1.txt", "old b_1")
      H.write_file(cdir .. "b_2.txt", "old b_2")
      fn.delete(cdir .. "b_3.txt")
    end
    seed()
    H.edit(cdir .. "a_1.txt")

    reset()
    answers.confirm = true -- the first choice: skip the existing ones
    local skipped = H.notifications(function()
      vim.cmd("File bulk rename ^a_ b_")
    end)
    local asked = calls[#calls]
    ok(
      asked.question:find("2 destination(s) exist already", 1, true),
      "the clash is in the question"
    )
    eq(asked.choices[1], "Rename 1, skip 2 existing", "skipping is the first (harmless) choice")
    eq(asked.choices[2], "Rename 3, overwrite 2 existing")
    ok(H.notified(skipped, "a_1.txt → b_1.txt  (exists)"), "the preview marks the clash")
    eq(body("b_1.txt"), "old b_1", "skip keeps an existing destination")
    eq(fn.filereadable(cdir .. "a_1.txt"), 1, "…and its source")
    eq(fn.filereadable(cdir .. "b_3.txt"), 1, "skip still renames the free one")
    ok(H.notified(skipped, "1 file(s) renamed"), "…with no failure reported")
    ok(
      H.notified(skipped, "kept a_1.txt: the destination exists already"),
      "…naming what it kept"
    )

    seed()
    reset()
    answers.confirm = "Rename 3, overwrite 2 existing"
    vim.cmd("File bulk rename ^a_ b_")
    eq(body("b_1.txt"), "new a_1.txt", "overwrite replaces the destination")
    eq(fn.filereadable(cdir .. "a_2.txt"), 0, "…and renames every planned file")

    seed()
    reset()
    answers.confirm = "Cancel"
    vim.cmd("File bulk rename ^a_ b_")
    eq(body("b_1.txt"), "old b_1", "cancel renames nothing")
    eq(fn.filereadable(cdir .. "a_3.txt"), 1, "…not even the free one")

    -- `!` only drops the skip choice: the dialog still starts on Cancel, the
    -- answer that overwrites nothing.
    seed()
    reset()
    answers.confirm = true
    vim.cmd("File! bulk rename ^a_ b_")
    eq(calls[#calls].choices[1], "Cancel", "with ! the dialog starts on Cancel")
    eq(calls[#calls].choices[2], "Rename 3, overwrite 2 existing", "…and offers no skip")
    eq(body("b_2.txt"), "old b_2", "…so <CR> on it overwrites nothing")
    reset()
    answers.confirm = "Rename 3, overwrite 2 existing"
    vim.cmd("File! bulk rename ^a_ b_")
    eq(body("b_2.txt"), "new a_2.txt", "! overwrites once that is chosen")

    -- b_1.txt was open (the buffer of a_1.txt, renamed onto it in the first
    -- overwrite) and a_1.txt had no buffer of its own this time: the open
    -- buffer stays and shows what was renamed there, not the old content.
    local b1 = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and vim.fs.normalize(name) == vim.fs.normalize(cdir .. "b_1.txt") then
        b1 = b
      end
    end
    ok(b1 ~= nil, "the overwritten destination's open buffer stays open")
    eq(
      vim.api.nvim_buf_get_lines(b1, 0, -1, false)[1],
      "new a_1.txt",
      "…reloaded with the content renamed onto it"
    )

    -- Every destination exists: nothing is left to skip into, so the dialog
    -- starts on Cancel, not on overwrite.
    for _, n in ipairs({ "a_1.txt", "a_2.txt" }) do
      H.write_file(cdir .. n, "new " .. n)
    end
    H.write_file(cdir .. "b_1.txt", "old b_1")
    H.write_file(cdir .. "b_2.txt", "old b_2")
    fn.delete(cdir .. "a_3.txt")
    fn.delete(cdir .. "b_3.txt")
    reset()
    answers.confirm = true
    vim.cmd("File bulk rename ^a_ b_")
    eq(calls[#calls].choices[1], "Cancel", "all destinations exist: the dialog starts on Cancel")
    eq(#calls[#calls].choices, 2, "…with no skip choice that would rename nothing")
    eq(body("b_1.txt"), "old b_1", "…so <CR> overwrites nothing")
  end

  -- ── bulk rename: a destination that is itself a source (chain) ──────────
  -- Measured before the fix: a.txt="A", aa.txt="AA", `^a` -> `aa`. aa.txt
  -- counted as "existing" although the batch moves it away; `!`/overwrite ran
  -- a.txt -> aa.txt first and destroyed "AA"; skip kept a.txt for nothing.
  do
    local kdir = H.tmpdir()
    local function body(name)
      return table.concat(fn.readfile(kdir .. name), "\n")
    end
    local function seed()
      for _, n in ipairs(fn.readdir(kdir)) do
        fn.delete(kdir .. n)
      end
      H.write_file(kdir .. "a.txt", "A")
      H.write_file(kdir .. "aa.txt", "AA")
    end
    seed()
    H.edit(kdir .. "a.txt")

    reset()
    answers.confirm = true
    local out = H.notifications(function()
      vim.cmd("File bulk rename ^a aa")
    end)
    eq(calls[#calls].choices[1], "Rename 2 file(s)", "a destination the batch vacates is no clash")
    ok(not H.notified(out, "(exists)"), "…and the preview does not mark it")
    eq(body("aaa.txt"), "AA", "the dependent rename runs first: aa.txt -> aaa.txt")
    eq(body("aa.txt"), "A", "…then a.txt -> aa.txt, with nothing lost")
    eq(fn.filereadable(kdir .. "a.txt"), 0, "…and a.txt is gone")
    ok(H.notified(out, "2 file(s) renamed"), "…both reported")

    seed()
    reset()
    answers.confirm = true
    vim.cmd("File! bulk rename ^a aa")
    eq(body("aaa.txt"), "AA", "with ! the chain loses nothing either")
    eq(body("aa.txt"), "A", "…a.txt landed on the vacated name")

    -- Skip holds a clash back, and with it every rename whose destination is
    -- the held-back source: za.txt stays, so zza.txt -> za.txt would land on it.
    for _, n in ipairs(fn.readdir(kdir)) do
      fn.delete(kdir .. n)
    end
    H.write_file(kdir .. "zza.txt", "ZZA")
    H.write_file(kdir .. "za.txt", "ZA")
    H.write_file(kdir .. "a.txt", "A")
    reset()
    answers.confirm = true
    vim.cmd("File bulk rename ^z ")
    eq(calls[#calls].choices[1], "Cancel", "skipping would hold the whole chain: no skip choice")
    eq(calls[#calls].choices[2], "Rename 2, overwrite 1 existing")
    eq(body("za.txt"), "ZA", "Cancel keeps the chain")
    reset()
    answers.confirm = "Rename 2, overwrite 1 existing"
    vim.cmd("File bulk rename ^z ")
    eq(body("a.txt"), "ZA", "overwrite: za.txt -> a.txt first")
    eq(body("za.txt"), "ZZA", "…then zza.txt -> za.txt")
  end

  -- ── bulk rename: two files onto one destination ─────────────────────────
  -- Measured before the fix: x1, y1, x2 with z2 existing, `^[xy]` -> `z`:
  -- "overwrite 1 existing", then y1 -> z1 overwrote x1 -> z1 silently.
  do
    local ddir = H.tmpdir()
    local function body(name)
      return table.concat(fn.readfile(ddir .. name), "\n")
    end
    H.write_file(ddir .. "x1.txt", "X1")
    H.write_file(ddir .. "y1.txt", "Y1")
    H.write_file(ddir .. "x2.txt", "X2")
    H.write_file(ddir .. "z2.txt", "Z2")
    H.edit(ddir .. "x1.txt")

    reset()
    answers.confirm = true
    local out = H.notifications(function()
      vim.cmd("File bulk rename ^[xy] z")
    end)
    eq(#calls, 0, "a duplicate destination refuses the batch before any dialog")
    ok(H.notified(out, "x1.txt, y1.txt → z1.txt"), "…naming the files that collide")
    ok(H.notified(out, "nothing renamed"), "…and that nothing happened")
    eq(body("x1.txt"), "X1", "x1.txt is untouched")
    eq(body("y1.txt"), "Y1", "y1.txt is untouched")
    eq(body("z2.txt"), "Z2", "the unrelated clash is untouched too")
    eq(fn.filereadable(ddir .. "z1.txt"), 0, "nothing was renamed")

    fn.delete(ddir .. "x2.txt")
    fn.delete(ddir .. "z2.txt")
    reset()
    H.notifications(function()
      vim.cmd("File! bulk rename ^[xy] z")
    end)
    eq(#calls, 0, "…with no real clash, and with !, just the same")
    eq(body("x1.txt"), "X1", "…x1.txt still untouched")
  end

  -- ── bulk rename: a cycle (swap) ──────────────────────────────────────────
  do
    local sdir = H.tmpdir()
    local function body(name)
      return table.concat(fn.readfile(sdir .. name), "\n")
    end
    H.write_file(sdir .. "ab.txt", "AB")
    H.write_file(sdir .. "ba.txt", "BA")
    H.edit(sdir .. "ab.txt")
    local buf = vim.api.nvim_get_current_buf()

    reset()
    answers.confirm = true
    local out = H.notifications(function()
      vim.cmd("File bulk rename ^(.)(.) %2%1")
    end)
    eq(calls[#calls].choices[1], "Rename 2 file(s)", "a swap is no clash")
    eq(body("ab.txt"), "BA", "ba.txt -> ab.txt")
    eq(body("ba.txt"), "AB", "ab.txt -> ba.txt, through a temporary name")
    local listing = fn.readdir(sdir)
    table.sort(listing)
    eq(table.concat(listing, ","), "ab.txt,ba.txt", "…which is gone afterwards")
    ok(H.notified(out, "2 file(s) renamed"), "…both reported")
    eq(fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"), "ba.txt", "the open buffer follows")
  end

  -- ── bulk rename: a case-only rename ──────────────────────────────────────
  -- On a case-folding filesystem (Windows, macOS) A_1.txt "exists" -- it is
  -- a_1.txt itself. That is no clash: the rename is offered plainly and done.
  do
    local udir = H.tmpdir()
    H.write_file(udir .. "a_1.txt", "a")
    H.write_file(udir .. "b_1.txt", "b")
    H.edit(udir .. "b_1.txt")
    reset()
    answers.confirm = true
    local out = H.notifications(function()
      vim.cmd("File bulk rename ^a_ A_")
    end)
    eq(calls[#calls].choices[1], "Rename 1 file(s)", "a case-only rename is no clash")
    ok(not H.notified(out, "(exists)"), "…and not marked as one")
    local listing = fn.readdir(udir)
    table.sort(listing)
    eq(table.concat(listing, ","), "A_1.txt,b_1.txt", "the name's case changed on disk")
  end

  -- ── bulk rename: a directory at the destination ─────────────────────────
  do
    local rdir = H.tmpdir()
    H.write_file(rdir .. "a_1.txt", "a")
    fn.mkdir(rdir .. "b_1.txt", "p")
    H.edit(rdir .. "a_1.txt")
    reset()
    answers.confirm = true
    local out = H.notifications(function()
      vim.cmd("File! bulk rename ^a_ b_")
    end)
    ok(
      H.notified(out, "a_1.txt → b_1.txt  (a directory: kept)"),
      "the preview names the directory"
    )
    eq(#calls, 0, "nothing left to rename: no dialog")
    ok(H.notified(out, "kept a_1.txt: the destination is a directory"), "…it says why")
    eq(fn.isdirectory(rdir .. "b_1.txt"), 1, "the directory is untouched")
    eq(fn.filereadable(rdir .. "a_1.txt"), 1, "…and so is the file")
  end

  -- ── bulk rename: destinations open in a buffer ──────────────────────────
  -- Before the fix the overwrite left both buffers wrong (E95, swallowed):
  -- a_1's buffer kept its vanished name, b_1's named content it never showed.
  do
    local odir = H.tmpdir()
    local function body(name)
      return table.concat(fn.readfile(odir .. name), "\n")
    end
    H.write_file(odir .. "a_1.txt", "new a_1")
    H.write_file(odir .. "a_2.txt", "new a_2")
    H.write_file(odir .. "b_1.txt", "old b_1")
    H.write_file(odir .. "b_2.txt", "old b_2")
    H.edit(odir .. "b_2.txt")
    local dirty = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { "unsaved b_2" })
    H.edit(odir .. "b_1.txt")
    local target = vim.api.nvim_get_current_buf()
    H.edit(odir .. "a_1.txt")
    local source = vim.api.nvim_get_current_buf()

    reset()
    answers.confirm = "Rename 1, overwrite 1 existing"
    local out = H.notifications(function()
      vim.cmd("File bulk rename ^a_ b_")
    end)
    ok(
      H.notified(out, "a_2.txt → b_2.txt  (exists, open with unsaved changes: kept)"),
      "the preview names the unsaved destination"
    )
    ok(H.notified(out, "a_1.txt → b_1.txt  (exists, open in a buffer)"), "…and the open one")
    eq(body("b_1.txt"), "new a_1", "the open, unmodified destination is overwritten")
    eq(vim.api.nvim_buf_is_valid(target), false, "…its buffer is closed")
    ok(H.notified(out, "closed the buffer of the overwritten"), "…and that is said")
    eq(
      fn.fnamemodify(vim.api.nvim_buf_get_name(source), ":t"),
      "b_1.txt",
      "the renamed file's buffer follows (no E95)"
    )
    eq(body("b_2.txt"), "old b_2", "the destination with unsaved changes is never overwritten")
    eq(fn.filereadable(odir .. "a_2.txt"), 1, "…its source stays")
    ok(H.notified(out, "kept a_2.txt: the destination is open with unsaved changes"), "…said so")
    vim.bo[dirty].modified = false
  end

  -- ── bulk rename: a destination taken while the dialog is open ───────────
  -- Only what the dialog announced is overwritten: b_3.txt was free at the
  -- preview, so a file created there meanwhile is refused, not overwritten.
  do
    local tdir = H.tmpdir()
    local function body(name)
      return table.concat(fn.readfile(tdir .. name), "\n")
    end
    H.write_file(tdir .. "a_1.txt", "new a_1")
    H.write_file(tdir .. "a_3.txt", "new a_3")
    H.write_file(tdir .. "b_1.txt", "old b_1")
    H.edit(tdir .. "a_1.txt")
    reset()
    answers.while_open = function()
      H.write_file(tdir .. "b_3.txt", "appeared")
    end
    answers.confirm = "Rename 2, overwrite 1 existing"
    local out = H.notifications(function()
      vim.cmd("File bulk rename ^a_ b_")
    end)
    eq(body("b_1.txt"), "new a_1", "the announced clash is overwritten")
    eq(body("b_3.txt"), "appeared", "the unannounced one is not")
    eq(fn.filereadable(tdir .. "a_3.txt"), 1, "…its source stays")
    ok(H.notified(out, "1/2 renamed"), "…and the failure is reported")
  end

  -- ── bulk rename without a UI: never waits, never acts ───────────────────
  do
    local ndir = H.tmpdir()
    H.write_file(ndir .. "a_1.txt", "a")
    H.write_file(ndir .. "b_1.txt", "b")
    H.edit(ndir .. "a_1.txt")
    reset()
    ui_attached = false
    local out = H.notifications(function()
      vim.cmd("File! bulk rename ^a_ b_")
    end)
    ui_attached = true
    eq(#calls, 0, "no UI: no dialog is opened")
    ok(H.notified(out, "no UI to confirm it; nothing renamed"), "…the rename is refused")
    ok(H.notified(out, "1 destination(s) exist already (use ! to overwrite)"), "…with the clash")
    eq(fn.readfile(ndir .. "b_1.txt")[1], "b", "…and nothing is overwritten")
  end

  -- ── the config flags the dispatch folds into every mutation ──────────────
  -- `retry`, `git_aware` and `session_compat` are read from the config by the
  -- dispatch and handed to the ops layer. The ops layer's own handling of
  -- them is covered in file_spec.lua; what is checked here is that the
  -- command really passes them on, since a dropped flag is silent.
  do
    reset()
    local fsops = require("lib.nvim.cross.fs.mutate")
    local real_rename = fsops.rename_file
    local seen_opts = nil

    config.setup({ delete = { mode = "permanent" }, retry = { attempts = 3, backoff_ms = 7 } })

    ---@diagnostic disable-next-line: duplicate-set-field
    fsops.rename_file = function(_, _, o)
      seen_opts = o
      return false, "EBUSY: resource busy or locked"
    end

    local rdir = H.tmpdir()
    H.write_file(rdir .. "retried.txt", "x")
    H.edit(rdir .. "retried.txt")
    H.notifications(function()
      vim.cmd("File rename other.txt")
    end)
    fsops.rename_file = real_rename

    eq(
      seen_opts and seen_opts.attempts,
      3,
      ":File rename passes the configured attempt budget down"
    )
    eq(seen_opts and seen_opts.backoff_ms, 7, "…and the configured backoff")
    ok(type(seen_opts.on_retry) == "function", "…and a hook that lets watchers release handles")

    -- session_compat: on by default, and switchable off from the config.
    local prev_session = vim.v.this_session
    local sess_dir = H.tmpdir()
    local sess_file = sess_dir .. "Session.vim"
    H.write_file(sess_dir .. "tracked_by_session.txt", "x")
    H.edit(sess_dir .. "tracked_by_session.txt")
    vim.cmd("mksession! " .. fn.fnameescape(sess_file))

    config.setup({ delete = { mode = "permanent" }, session_compat = { enable = false } })
    vim.cmd("File rename kept_stale.txt")
    local after_off = table.concat(fn.readfile(sess_file), "\n")
    ok(
      after_off:find("kept_stale.txt", 1, true) == nil,
      "session_compat.enable = false leaves the session file untouched"
    )

    H.edit(sess_dir .. "kept_stale.txt")
    vim.cmd("mksession! " .. fn.fnameescape(sess_file))
    config.setup({ delete = { mode = "permanent" } })
    vim.cmd("File rename resaved.txt")
    local after_on = table.concat(fn.readfile(sess_file), "\n")
    ok(
      after_on:find("resaved.txt", 1, true) ~= nil,
      "the default resaves the active session at the new path"
    )
    vim.v.this_session = prev_session

    -- git_aware is opt-in, and only then does a tracked file get a note.
    local gdir = H.tmpdir()
    local git_init = vim.system({ "git", "init", "-q" }, { text = true, cwd = gdir }):wait()
    if git_init.code ~= 0 then
      print("skip  usrcmds_dispatch_spec.lua git_aware section: git not usable")
    else
      local function git_run(...)
        return vim.system({ ... }, { text = true, cwd = gdir }):wait()
      end
      git_run("git", "config", "user.email", "test@example.com")
      git_run("git", "config", "user.name", "Test")
      -- One committed file per case: a libuv rename does not update the
      -- index, so a file that has already been renamed once is no longer
      -- tracked under its new name.
      for _, name in ipairs({ "tracked_a.txt", "tracked_b.txt", "tracked_c.txt" }) do
        H.write_file(gdir .. name, "x")
        git_run("git", "add", name)
      end
      git_run("git", "commit", "-q", "-m", "add the tracked fixtures")

      H.edit(gdir .. "tracked_a.txt")
      local quiet = H.notifications(function()
        vim.cmd("File rename untracked_note.txt")
      end)
      ok(
        not H.notified(quiet, "git-tracked"),
        "git_aware is off by default: no git note, and no git process"
      )

      config.setup({ delete = { mode = "permanent" }, git_aware = { enable = true } })
      H.edit(gdir .. "tracked_b.txt")
      local noted = H.notifications(function()
        vim.cmd("File rename noted.txt")
      end)
      ok(
        H.notified(noted, "(git-tracked)"),
        "git_aware.enable = true notes tracked-ness (warn_only is the default)"
      )

      config.setup({
        delete = { mode = "permanent" },
        git_aware = { enable = true, warn_only = false },
      })
      H.edit(gdir .. "tracked_c.txt")
      local moved = H.notifications(function()
        vim.cmd("File rename via_git.txt")
      end)
      ok(H.notified(moved, "(git mv)"), "warn_only = false renames through `git mv`")
      local status = git_run("git", "status", "--porcelain", "--", "tracked_c.txt", "via_git.txt")
      ok(status.stdout:match("^R"), "…so the index follows: " .. tostring(status.stdout))
      config.setup({ delete = { mode = "permanent" } })
    end
  end

  -- ── completion ───────────────────────────────────────────────────────────
  do
    local subs = fn.getcompletion("File ", "cmdline")
    for _, want in ipairs({ "rename", "move", "delete", "bulk", "cd", "help" }) do
      ok(vim.tbl_contains(subs, want), "subcommand completion offers " .. want)
    end

    eq(
      table.concat(fn.getcompletion("File cd ", "cmdline"), ","),
      "window,tab,global",
      ":File cd completes its scope enum"
    )
    eq(
      table.concat(fn.getcompletion("File path ", "cmdline"), ","),
      "abs,rel,name,dir",
      ":File path completes its mode enum"
    )
    local cycle_targets = fn.getcompletion("File first ", "cmdline")
    ok(vim.tbl_contains(cycle_targets, "vsplit"), ":File first completes the open targets")

    -- The cycle slot is not a strict enum (a glob goes there too), but it
    -- still offers the target keywords as a prefix match.
    local narrowed = fn.getcompletion("File next v", "cmdline")
    eq(table.concat(narrowed, ","), "vsplit", ":File next narrows its target keywords by prefix")
    ok(#fn.getcompletion("File next ", "cmdline") > 1, ":File next offers every target keyword")

    -- The path types complete relative to the BUFFER's directory, not the
    -- cwd: `:File rename <Tab>` is about the file being edited.
    local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
    local cdir = H.tmpdir()
    H.write_file(cdir .. "sibling_one.txt", "x")
    H.write_file(cdir .. "sibling_two.txt", "x")
    local prev_cwd = fn.getcwd()
    local elsewhere = H.tmpdir()
    vim.cmd("cd " .. fn.fnameescape(elsewhere))
    H.edit(cdir .. "sibling_one.txt")

    local path_type = argtypes.get("FILEOPS_PATH")
    local siblings = path_type.complete("sibling_")
    eq(#siblings, 2, "FILEOPS_PATH completes files next to the buffer, not next to the cwd")
    ok(
      siblings[1]:find("sibling_", 1, true) ~= nil and vim.startswith(siblings[1], cdir:sub(1, 3)),
      "…as absolute paths: " .. tostring(siblings[1])
    )

    -- Absolute-looking input is left to Neovim's own file completion.
    local absolute = path_type.complete(cdir .. "sibling_t")
    eq(#absolute, 1, "an absolute lead is completed against that directory")
    ok(absolute[1]:find("sibling_two.txt", 1, true) ~= nil, "…finding the right file")

    -- Nested-path completion: arg_lead may carry an already-typed directory
    -- segment ("subdir/partial<Tab>") ahead of the partial name being
    -- completed. This is the main risk of a scandir-based rewrite of
    -- `complete_from_bufdir` (XP-01), so it gets its own case.
    H.write_file(cdir .. "nested/deep_one.txt", "x")
    H.write_file(cdir .. "nested/deep_two.txt", "x")
    local nested = path_type.complete("nested/deep_o")
    eq(#nested, 1, "nested-path completion narrows within the subdirectory")
    ok(
      nested[1]:find("deep_one.txt", 1, true) ~= nil,
      "…finding the right nested file: " .. tostring(nested[1])
    )
    local nested_all = path_type.complete("nested/")
    eq(#nested_all, 2, "an empty partial after a subdirectory lists everything in it")

    -- A buffer directory containing a glob metacharacter must still
    -- complete. `getcompletion`/`glob` read their argument as a *pattern*,
    -- so a literal `[`/`]` in the path made every candidate vanish with no
    -- error (XP-01). `complete_from_bufdir` is scandir-based now, reading
    -- the directory as a path rather than pattern syntax.
    local glob_dir = H.tmpdir() .. "[glob]_dir/"
    H.write_file(glob_dir .. "glob_sibling.txt", "x")
    H.edit(glob_dir .. "glob_sibling.txt")
    local glob_matches = path_type.complete("glob_s")
    eq(
      #glob_matches,
      1,
      "a buffer directory containing glob metacharacters still completes (XP-01)"
    )
    ok(
      glob_matches[1]:find("glob_sibling.txt", 1, true) ~= nil,
      "…finding the right file: " .. tostring(glob_matches[1])
    )
    H.edit(cdir .. "sibling_one.txt")

    -- rename/duplicate's first slot additionally offers the `%` scope token.
    local first_slot = argtypes.get("FILEOPS_DEST_FIRST")
    eq(first_slot.complete("")[1], "%", "FILEOPS_DEST_FIRST offers '%' first on an empty lead")
    eq(
      first_slot.complete("sib")[1]:find("%%"),
      nil,
      "…and drops it once the lead cannot be '%' any more"
    )

    -- Validation: FILEOPS_PATH expands `~`, the others pass their token through.
    local vok, value = path_type.validate("~")
    ok(vok, "FILEOPS_PATH accepts '~'")
    ok(tostring(value):find("~", 1, true) == nil, "…and expands it: " .. tostring(value))
    local dok, dvalue = first_slot.validate("%")
    ok(dok, "FILEOPS_DEST_FIRST accepts '%'")
    eq(dvalue, "%", "…unchanged, so resolve_dest can recognize the scope token")

    vim.cmd("cd " .. fn.fnameescape(prev_cwd))
  end

  restore_kit()
  vim.api.nvim_list_uis = real_list_uis
  config.setup({})
end

return function(H)
  H.run_preserved(spec)
end
