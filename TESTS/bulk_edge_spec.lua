-- TESTS/bulk_edge_spec.lua — ops/bulk.lua's failure and edge behaviour:
-- unreadable directories, invalid Lua patterns, the trailing-separator
-- normalization `plan` does before joining, and `execute`'s "keep going after
-- the first failure" contract.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local bulk = require("fileops.ops.bulk")
  local fn = vim.fn

  -- ── plan: input validation ───────────────────────────────────────────────
  do
    -- A directory that is not there is reported, not silently treated as
    -- "nothing matched": `vim.fs.dir` itself never raises (its iterator just
    -- produces nothing for a missing/unreadable directory), so `plan` checks
    -- with `isdirectory` first instead of relying on a `pcall` that guards a
    -- failure mode that doesn't happen.
    local missing = H.tmpdir() .. "no_such_directory"
    local plan, err = bulk.plan(missing, "^a", "b")
    eq(#plan, 0, "plan on a missing directory returns an empty plan")
    ok(
      tostring(err):find("cannot read directory", 1, true) ~= nil,
      "…and reports it as unreadable, not as zero matches: " .. tostring(err)
    )

    local dir = H.tmpdir()
    H.write_file(dir .. "file.txt", "x")
    -- An unbalanced `%b`/`[` is a Lua pattern error, which would otherwise
    -- escape as a raw runtime error from inside `string.gsub`.
    local bad_plan, bad_err = bulk.plan(dir, "[unclosed", "x")
    eq(#bad_plan, 0, "plan with an invalid pattern returns an empty plan")
    ok(
      tostring(bad_err):find("invalid pattern", 1, true) ~= nil,
      "plan reports an invalid pattern as its own error: " .. tostring(bad_err)
    )
  end

  -- ── plan: the directory separator ────────────────────────────────────────
  -- `dir` reaches this function both with and without a trailing separator
  -- (`H.tmpdir()` has one; `cycle.get_root_dir` — what the binding layer
  -- actually passes — does not). Both must produce the same plan, with
  -- exactly one separator in the joined path.
  do
    local dir = H.tmpdir()
    H.write_file(dir .. "note_1.txt", "1")

    local with_slash = bulk.plan(dir, "^note_", "memo_")
    local without_slash = bulk.plan((dir:gsub("[\\/]$", "")), "^note_", "memo_")

    eq(#with_slash, 1, "plan with a trailing separator finds the file")
    eq(#without_slash, 1, "plan without a trailing separator finds the same file")
    eq(
      with_slash[1].new:find("//", 1, true) or with_slash[1].new:find("\\\\", 1, true),
      nil,
      "the joined destination has no doubled separator: " .. with_slash[1].new
    )
    eq(
      fn.fnamemodify(with_slash[1].new, ":h"),
      fn.fnamemodify(with_slash[1].old, ":h"),
      "the destination stays in the same directory as the source"
    )

    -- Documented behaviour, not a defect: a root without a trailing separator
    -- is joined with "/", and `fnamemodify(…, ":p")` leaves that slash in
    -- place, so on Windows the two spellings produce different *strings* for
    -- the same file. The plan keeps the platform spelling it was handed --
    -- what a user reads in the preview and what `:w` writes is unchanged.
    -- What used to break was the *comparison* built on top of it (the open
    -- buffer was stranded after a rename, see the buffer-follow case below);
    -- that comparison normalizes now, the stored strings do not.
    eq(
      vim.fs.normalize(with_slash[1].old),
      vim.fs.normalize(without_slash[1].old),
      "both spellings name the same source file"
    )
    eq(
      vim.fs.normalize(with_slash[1].new),
      vim.fs.normalize(without_slash[1].new),
      "and the same destination"
    )
  end

  -- ── plan: what is excluded ───────────────────────────────────────────────
  do
    local dir = H.tmpdir()
    H.write_file(dir .. "keep.txt", "x")
    H.write_file(dir .. "drop.txt", "x")
    fn.mkdir(dir .. "subdir", "p")
    fn.mkdir(dir .. "drop_dir", "p")

    -- A directory whose NAME matches is never planned: this renames files.
    local plan = bulk.plan(dir, "^drop", "moved")
    eq(#plan, 1, "plan skips directories whose name matches the pattern")
    eq(fn.fnamemodify(plan[1].old, ":t"), "drop.txt", "…and keeps the matching file")

    -- A replacement that changes nothing is not a rename.
    local noop = bulk.plan(dir, "keep", "keep")
    eq(#noop, 0, "plan skips files whose name is unchanged by the replacement")

    -- A replacement that empties the name would produce an unusable path.
    local emptied = bulk.plan(dir, "^keep%.txt$", "")
    eq(#emptied, 0, "plan skips a replacement that would leave an empty file name")
  end

  -- ── execute: a failure in the middle does not stop the rest ──────────────
  do
    local dir = H.tmpdir()
    for _, name in ipairs({ "x_1.txt", "x_2.txt", "x_3.txt" }) do
      H.write_file(dir .. name, name)
    end
    -- Pre-existing destination for the middle item only.
    H.write_file(dir .. "y_2.txt", "in the way")

    local plan = bulk.plan(dir, "^x_", "y_")
    eq(#plan, 3, "setup: three planned renames")

    local events = {}
    local group = vim.api.nvim_create_augroup("fileops_bulk_edge_spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "FileopsChanged",
      callback = function(ev)
        events[#events + 1] = ev.data
      end,
    })

    local renamed, err = bulk.execute(plan, {})
    eq(renamed, 2, "execute renames every item except the conflicting one")
    ok(
      tostring(err):find("destination already exists", 1, true) ~= nil,
      "execute reports the first failure: " .. tostring(err)
    )
    eq(fn.filereadable(dir .. "y_1.txt"), 1, "the item before the conflict was renamed")
    eq(fn.filereadable(dir .. "y_3.txt"), 1, "the item after the conflict was renamed too")
    eq(fn.filereadable(dir .. "x_2.txt"), 1, "the conflicting source was left alone")
    eq(
      fn.readfile(dir .. "y_2.txt")[1],
      "in the way",
      "the conflicting destination was not touched"
    )

    eq(#events, 2, "execute fires one FileopsChanged per file it really renamed")
    eq(events[1].action, "rename", "…with action 'rename'")

    vim.api.nvim_del_augroup_by_id(group)
  end

  -- ── execute: a source that disappeared between plan and execute ──────────
  -- The plan is built for a preview and confirmed afterwards, so the window
  -- between the two is real. A vanished source must be reported, not crash.
  do
    local dir = H.tmpdir()
    H.write_file(dir .. "z_1.txt", "1")
    H.write_file(dir .. "z_2.txt", "2")
    local plan = bulk.plan(dir, "^z_", "w_")
    eq(#plan, 2, "setup: two planned renames")

    fn.delete(plan[1].old)
    local renamed, err = bulk.execute(plan, {})
    eq(renamed, 1, "execute renames what is still there")
    ok(
      tostring(err):find("rename failed", 1, true) ~= nil,
      "execute reports the vanished source as a rename failure: " .. tostring(err)
    )
    eq(fn.filereadable(dir .. "w_2.txt"), 1, "the surviving item was renamed")
  end

  -- ── execute: the root the binding layer really passes ────────────────────
  -- `:File bulk rename` builds its plan from `cycle.get_root_dir`, which
  -- answers `fnamemodify(name, ":p:h")` — no trailing separator. That is the
  -- only spelling production ever uses, so it is the one that has to work.
  do
    local cycle = require("fileops.ops.cycle")
    local dir = H.tmpdir()
    H.write_file(dir .. "real_1.txt", "1")
    local buf = H.edit(dir .. "real_1.txt")

    local root = cycle.get_root_dir({ root = "buffer_dir" })
    ---@cast root string
    local plan = bulk.plan(root, "^real_", "actual_")
    eq(#plan, 1, "the plan the command would build has the one matching file")

    local renamed, err = bulk.execute(plan, { refresh_explorers = false })
    eq(renamed, 1, "the rename itself goes through")
    eq(err, nil, "…without an error")
    eq(fn.filereadable(dir .. "actual_1.txt"), 1, "…and the file really moved")

    -- Regression: the open buffer used to be left behind on Windows. `execute`
    -- re-points a buffer by comparing `fnamemodify(buf_name, ":p")` against the
    -- plan's `old`, and those two disagreed in exactly one character there
    -- (`\` vs the `/` `plan` joined with), so `nvim_buf_set_name` never ran:
    -- the buffer kept pointing at a path that no longer existed, and the next
    -- `:w` wrote the old file back into existence. Both sides are normalized
    -- now.
    eq(
      fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"),
      "actual_1.txt",
      "the open buffer follows the rename"
    )
    ok(
      fn.filereadable(vim.api.nvim_buf_get_name(buf)) == 1,
      "and points at a file that exists: " .. vim.api.nvim_buf_get_name(buf)
    )
    vim.cmd("bwipeout! " .. buf)
  end

  -- ── execute: open buffers follow, and are not reloaded ───────────────────
  do
    local dir = H.tmpdir()
    H.write_file(dir .. "doc_1.md", "line one")
    local buf = H.edit(dir .. "doc_1.md")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line one edited" })
    ok(fn.undotree().seq_cur > 0, "setup: the buffer has undo history")

    local plan = bulk.plan(dir, "^doc_", "text_")
    local renamed = bulk.execute(plan, { refresh_explorers = false })
    eq(renamed, 1, "execute renamed the file")
    eq(
      fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"),
      "text_1.md",
      "the open buffer follows the file to its new name"
    )
    ok(fn.undotree().seq_cur > 0, "the buffer was re-pointed, not reloaded: undo history survives")
    ok(vim.bo[buf].modified, "…and the unsaved edit is still unsaved")
    vim.cmd("bwipeout! " .. buf)
  end

  -- ── execute: a plan rooted at a symlinked directory ──────────────────────
  -- The same buffer lookup as above, against the other way two strings can
  -- spell one path. Neovim resolves symlinks when it names a buffer, so a
  -- buffer opened inside a linked directory is named through the link's
  -- target, while a plan rooted at the link keeps the link's own spelling --
  -- `:p` does not resolve. macOS reaches its whole temp tree through such a
  -- link (`/var` -> `/private/var`), which makes this the everyday case there
  -- rather than an exotic one. Without resolving both sides, `execute` renames
  -- the file but leaves the buffer pointing at the name it just vacated, and
  -- the next `:w` writes the old file back into existence.
  --
  -- Needs a directory link the platform will actually create: a junction on
  -- Windows (no elevation required), a plain symlink elsewhere. Skipped, not
  -- faked, where even that is refused.
  do
    local uv = vim.uv or vim.loop
    local real = H.tmpdir()
    local link = H.tmpdir() .. "linked"
    local target = real:gsub("[\\/]$", "")
    pcall(uv.fs_symlink, target, link, { dir = true, junction = true })

    if fn.isdirectory(link) == 1 then
      H.write_file(real .. "via_1.txt", "1")
      local buf = H.edit(real .. "via_1.txt")

      local plan = bulk.plan(link, "^via_", "through_")
      eq(#plan, 1, "a plan rooted at the link sees the file behind it")

      local renamed, err = bulk.execute(plan, { refresh_explorers = false })
      eq(renamed, 1, "execute renames it")
      eq(err, nil, "…without an error")
      eq(
        fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"),
        "through_1.txt",
        "the open buffer follows a rename planned through a symlinked root"
      )
      ok(
        fn.filereadable(vim.api.nvim_buf_get_name(buf)) == 1,
        "…and points at a file that exists: " .. vim.api.nvim_buf_get_name(buf)
      )
      vim.cmd("bwipeout! " .. buf)
    end
  end

  -- ── execute: the batch never overwrites one of its own files ─────────────
  do
    local fsops = require("lib.nvim.cross.fs.mutate")
    local real_rename = fsops.rename_file
    local dir = H.tmpdir()
    local function body(name)
      return table.concat(fn.readfile(dir .. name), "\n")
    end
    local function seed()
      for _, n in ipairs(fn.readdir(dir)) do
        fn.delete(dir .. n)
      end
      H.write_file(dir .. "a.txt", "A")
      H.write_file(dir .. "aa.txt", "AA")
    end

    -- Handed over in the order that loses data (a.txt -> aa.txt first) and
    -- with `bang`: `execute` itself runs aa.txt -> aaa.txt first.
    seed()
    local plan = {
      { old = dir .. "a.txt", new = dir .. "aa.txt" },
      { old = dir .. "aa.txt", new = dir .. "aaa.txt" },
    }
    local renamed, err = bulk.execute(plan, { bang = true, refresh_explorers = false })
    eq(err, nil, "a chain in any order runs clean: " .. tostring(err))
    eq(renamed, 2, "…renaming both")
    eq(body("aaa.txt"), "AA", "…the dependent first")
    eq(body("aa.txt"), "A", "…then the one onto the vacated name")

    -- The dependency fails: its source stays, and the item onto it is refused
    -- even with `bang` and `overwrite` -- it would destroy a batch member.
    seed()
    ---@diagnostic disable-next-line: duplicate-set-field
    fsops.rename_file = function(src, dst, o)
      if src:find("[\\/]aa%.txt$") then
        return false, "EBUSY: resource busy or locked"
      end
      return real_rename(src, dst, o)
    end
    plan = {
      { old = dir .. "a.txt", new = dir .. "aa.txt", overwrite = true },
      { old = dir .. "aa.txt", new = dir .. "aaa.txt" },
    }
    renamed, err = bulk.execute(plan, { bang = true, refresh_explorers = false })
    fsops.rename_file = real_rename
    eq(renamed, 0, "a failed dependency renames nothing onto it")
    eq(body("aa.txt"), "AA", "…aa.txt keeps its own content")
    eq(body("a.txt"), "A", "…and a.txt stays where it was")
    ok(
      tostring(err):find("EBUSY", 1, true) ~= nil,
      "…the first failure is reported: " .. tostring(err)
    )

    -- Two items onto one destination: refused as a whole, nothing renamed.
    seed()
    plan = {
      { old = dir .. "a.txt", new = dir .. "z.txt" },
      { old = dir .. "aa.txt", new = dir .. "z.txt" },
    }
    renamed, err = bulk.execute(plan, { bang = true, refresh_explorers = false })
    eq(renamed, 0, "a duplicate destination renames nothing")
    ok(tostring(err):find("a.txt, aa.txt would all be renamed to", 1, true) ~= nil, tostring(err))
    eq(body("a.txt") .. body("aa.txt"), "AAA", "…both files untouched")

    -- A cycle whose last step fails: the parked file cannot go back either
    -- (the cycle filled its old name), so it stays on the temporary name, and
    -- that is said. Nothing is overwritten.
    for _, n in ipairs(fn.readdir(dir)) do
      fn.delete(dir .. n)
    end
    H.write_file(dir .. "ab.txt", "AB")
    H.write_file(dir .. "ba.txt", "BA")
    ---@diagnostic disable-next-line: duplicate-set-field
    fsops.rename_file = function(src, dst, o)
      if src:find(".fileops-swap-", 1, true) and dst:find("ba.txt", 1, true) then
        return false, "EPERM: operation not permitted"
      end
      return real_rename(src, dst, o)
    end
    local notes
    renamed, err, notes = bulk.execute({
      { old = dir .. "ab.txt", new = dir .. "ba.txt" },
      { old = dir .. "ba.txt", new = dir .. "ab.txt" },
    }, { refresh_explorers = false })
    fsops.rename_file = real_rename
    eq(renamed, 1, "the half of the cycle that could run, ran")
    eq(body("ab.txt"), "BA", "…ba.txt -> ab.txt")
    ok(tostring(err):find("EPERM", 1, true) ~= nil, "…the failure is reported: " .. tostring(err))
    ok(table.concat(notes, "\n"):find("is left at", 1, true) ~= nil, "…and where ab.txt is now")
    local parked = vim.tbl_filter(function(n)
      return n:find(".fileops-swap-", 1, true) ~= nil
    end, fn.readdir(dir))
    eq(#parked, 1, "the parked file still exists")
    eq(body(parked[1] or ""), "AB", "…with its content")
  end

  -- ── plan: a directory at the destination keeps its name ─────────────────
  -- `:p` appends a separator to an existing directory, which left the
  -- destination with an empty tail (preview `a_1.txt → `).
  do
    local dir = H.tmpdir()
    H.write_file(dir .. "a_1.txt", "a")
    fn.mkdir(dir .. "b_1.txt", "p")
    local plan = bulk.plan(dir, "^a_", "b_")
    eq(fn.fnamemodify(plan[1].new, ":t"), "b_1.txt", "the destination's tail is its name")
    eq(bulk.analyze(plan).status[1], "directory", "…and analyze calls it a directory")

    -- `execute` refuses it on its own too, `bang` or not: whatever the caller
    -- planned, a directory is never renamed over.
    local renamed, err = bulk.execute(plan, { bang = true, refresh_explorers = false })
    eq(renamed, 0, "execute never renames onto a directory")
    ok(tostring(err):find("is a directory", 1, true) ~= nil, tostring(err))
    eq(fn.filereadable(dir .. "a_1.txt"), 1, "…the file stays")
  end

  -- ── execute: open buffers on the destination ─────────────────────────────
  do
    local dir = H.tmpdir()
    -- A destination open with unsaved changes is refused at execution time
    -- as well (it may have been edited while the dialog was open).
    H.write_file(dir .. "a_1.txt", "new")
    H.write_file(dir .. "b_1.txt", "old")
    local dirty = H.edit(dir .. "b_1.txt")
    vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { "unsaved" })
    local renamed, err = bulk.execute(
      { { old = dir .. "a_1.txt", new = dir .. "b_1.txt", overwrite = true } },
      { refresh_explorers = false }
    )
    eq(renamed, 0, "a destination with unsaved changes is not overwritten")
    ok(tostring(err):find("unsaved changes", 1, true) ~= nil, tostring(err))
    eq(fn.readfile(dir .. "b_1.txt")[1], "old", "…the file keeps its content")
    vim.bo[dirty].modified = false
    vim.cmd("bwipeout! " .. dirty)

    -- A buffer named like the destination (never written, so no file is
    -- overwritten) keeps the renamed file's buffer from taking the name:
    -- E95. Not swallowed silently any more: a note says which buffer kept
    -- its old name.
    H.write_file(dir .. "a_9.txt", "nine")
    local ghost = H.edit(dir .. "b_9.txt")
    local src = H.edit(dir .. "a_9.txt")
    local notes
    renamed, err, notes = bulk.execute(
      { { old = dir .. "a_9.txt", new = dir .. "b_9.txt" } },
      { refresh_explorers = false }
    )
    eq(renamed, 1, "the file itself is renamed")
    eq(err, nil, "…without a failure")
    ok(
      table.concat(notes, "\n"):find("still shows", 1, true) ~= nil,
      "…and the buffer that could not follow is named: " .. table.concat(notes, " | ")
    )
    vim.cmd("bwipeout! " .. src)
    vim.cmd("bwipeout! " .. ghost)
  end

  -- ── execute: nothing to do ───────────────────────────────────────────────
  do
    local renamed, err = bulk.execute({}, {})
    eq(renamed, 0, "executing an empty plan renames nothing")
    eq(err, nil, "…and is not an error")
  end
end

return function(H)
  H.run_preserved(spec)
end
