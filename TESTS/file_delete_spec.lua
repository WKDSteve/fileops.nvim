-- TESTS/file_delete_spec.lua — ops/file.lua's destructive half: the
-- trash/permanent policy, `delete_path`, the unsaved-changes guard, the
-- window bookkeeping a delete has to do, and `diagnose_lock`.
--
-- The OS trash is never actually used: `lib.nvim.fs.trash` shells out to
-- PowerShell/osascript/`gio trash`, which is slow, environment-dependent, and
-- would leave fixtures in the machine's real recycle bin. It is stubbed at
-- `package.loaded` — resolved inside the delete call, so the stub is seen —
-- and the spec asserts the path fileops hands it.
--
-- Everything here operates strictly inside `vim.fn.tempname()` directories.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local file = require("fileops.ops.file")
  local fn = vim.fn

  -- ── trash mode ───────────────────────────────────────────────────────────
  do
    local dir = H.tmpdir()
    local victim = dir .. "trashme.txt"
    H.write_file(victim, "bye")
    H.edit(victim)

    local trashed_path = nil
    local restore = H.stub("lib.nvim.fs.trash", {
      trash_blocking = function(path)
        trashed_path = path
        vim.fn.delete(path)
        return true, nil
      end,
    })

    local tok, tmsg = file.delete_current({ mode = "trash" })
    restore()

    ok(tok, "delete_current in trash mode succeeds: " .. tostring(tmsg))
    eq(trashed_path, fn.fnamemodify(victim, ":p"), "trash mode hands the OS trash the full path")
    ok(
      tostring(tmsg):find("trashed ", 1, true) ~= nil,
      "trash mode's message says 'trashed', not 'deleted': " .. tostring(tmsg)
    )
    eq(fn.filereadable(victim), 0, "trash mode: the file is gone from its original location")
  end

  -- A trash backend that refuses (no `gio`/`trash-put` on a headless Linux
  -- box, a locked file on Windows) must surface as fileops's own sentence.
  do
    local dir = H.tmpdir()
    local victim = dir .. "untrashable.txt"
    H.write_file(victim, "stay")
    H.edit(victim)

    local restore = H.stub("lib.nvim.fs.trash", {
      trash_blocking = function()
        return false, "EACCES: permission denied"
      end,
    })

    local tok, tmsg = file.delete_current({ mode = "trash" })
    restore()

    ok(not tok, "a failing trash backend is reported as a failure")
    ok(
      tostring(tmsg):find("trash failed:", 1, true) ~= nil,
      "the failure is worded as a trash failure: " .. tostring(tmsg)
    )
    ok(
      tostring(tmsg):find("another process is holding the file open", 1, true) ~= nil,
      "an EACCES from the trash backend is explained, not left as a bare code"
    )
    eq(fn.filereadable(victim), 1, "a failed trash leaves the file alone")
    ok(vim.api.nvim_buf_is_valid(vim.api.nvim_get_current_buf()), "a failed trash keeps the buffer")
  end

  -- ── the unsaved-changes guard ────────────────────────────────────────────
  do
    local dir = H.tmpdir()
    local victim = dir .. "dirty.txt"
    H.write_file(victim, "saved content")
    local buf = H.edit(victim)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved edit" })
    ok(vim.bo[buf].modified, "setup: the buffer really is modified")

    local dok, dmsg = file.delete_current({ mode = "permanent" })
    ok(not dok, "delete_current refuses a modified buffer without force")
    ok(
      tostring(dmsg):find(":File! delete", 1, true) ~= nil,
      "the refusal points at the forced form: " .. tostring(dmsg)
    )
    eq(fn.filereadable(victim), 1, "the refused delete left the file on disk")
    ok(vim.api.nvim_buf_is_valid(buf), "the refused delete left the buffer open")

    -- Which is the point of refusing rather than deleting: the follow-up
    -- `:File! delete` still has a file to delete.
    local fok = file.delete_current({ mode = "permanent", force = true })
    ok(fok, "delete_current with force=true deletes the modified buffer's file")
    eq(fn.filereadable(victim), 0, "forced delete removed the file")
  end

  -- ── window bookkeeping ───────────────────────────────────────────────────
  -- Deleting the current buffer must not leave the window on a throwaway
  -- no-name buffer while other real buffers exist: `switch_windows_off` steers
  -- every window showing it onto an alternate first.
  do
    local dir = H.tmpdir()
    local keeper = dir .. "keeper.txt"
    local goner = dir .. "goner.txt"
    H.write_file(keeper, "keep")
    H.write_file(goner, "go")

    local keeper_buf = H.edit(keeper)
    H.edit(goner)
    local win = vim.api.nvim_get_current_win()

    ok(file.delete_current({ mode = "permanent" }), "delete_current succeeds")
    eq(fn.filereadable(goner), 0, "the deleted file is gone")
    eq(
      vim.api.nvim_win_get_buf(win),
      keeper_buf,
      "the window fell back to the alternate file, not to an empty scratch buffer"
    )
    ok(vim.api.nvim_buf_get_name(0) ~= "", "the current buffer still has a file name")
  end

  -- ── delete_path ──────────────────────────────────────────────────────────
  do
    local dir = H.tmpdir()

    local missing = dir .. "never_existed.txt"
    local mok, mmsg = file.delete_path(missing, { mode = "permanent" })
    ok(not mok, "delete_path refuses a path that does not exist")
    ok(
      tostring(mmsg):find("path does not exist", 1, true) ~= nil,
      "delete_path names the missing path: " .. tostring(mmsg)
    )

    local asset = dir .. "assets/orphan.png"
    H.write_file(asset, "png")
    local events = {}
    local group = vim.api.nvim_create_augroup("fileops_delete_path_spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "FileopsChanged",
      callback = function(ev)
        events[#events + 1] = ev.data
      end,
    })

    local aok, amsg = file.delete_path(asset, { mode = "permanent" })
    ok(aok, "delete_path removes a file that has no buffer of its own: " .. tostring(amsg))
    eq(fn.filereadable(asset), 0, "delete_path: the file is gone")
    eq(#events, 1, "delete_path fires FileopsChanged so explorers still refresh")
    eq(events[1].action, "delete", "delete_path's event action is 'delete'")

    -- A failed delete must NOT announce a change.
    local failed_count = #events
    file.delete_path(missing, { mode = "permanent" })
    eq(#events, failed_count, "a failed delete_path fires no FileopsChanged event")

    vim.api.nvim_del_augroup_by_id(group)

    -- Regression: `delete_path`'s existence check accepts a directory
    -- (`fn.isdirectory(path) ~= 1` is half of its guard, and
    -- `filetree_assets` can hand it any resolved link target), but the
    -- permanent deletion is `fsops.delete_file` → `uv.fs_unlink`, which can
    -- never remove one. libuv answers EPERM there, lib.nvim's retry loop read
    -- that as a transient sharing violation and burned the whole retry budget,
    -- and `explain_fs_error` then blamed a virus scanner for what is really
    -- "this is a directory". It is refused up front now, with that reason.
    local adir = dir .. "a_directory"
    fn.mkdir(adir, "p")
    local dok, dmsg = file.delete_path(adir, { mode = "permanent", retry = { attempts = 1 } })
    ok(not dok, "delete_path refuses a directory on the permanent path")
    eq(fn.isdirectory(adir), 1, "and leaves it alone")
    ok(
      tostring(dmsg):find("is a directory", 1, true) ~= nil,
      "saying so, rather than blaming a process holding it open: " .. tostring(dmsg)
    )
  end

  -- ── the on_before_delete veto runs before anything touches the disk ──────
  do
    local dir = H.tmpdir()
    local victim = dir .. "vetoed.txt"
    H.write_file(victim, "keep")
    H.edit(victim)

    local restore = H.stub("lib.nvim.fs.trash", {
      trash_blocking = function()
        error("the trash backend must not be reached once the hook vetoed")
      end,
    })
    local vok, vmsg = file.delete_current({
      mode = "trash",
      on_before_delete = function()
        return false
      end,
    })
    restore()

    ok(not vok, "a vetoing hook aborts the delete")
    ok(
      tostring(vmsg):find("cancelled by on_before_delete", 1, true) ~= nil,
      "the veto is named in the message: " .. tostring(vmsg)
    )
    eq(fn.filereadable(victim), 1, "the vetoed file is untouched")

    -- Only an explicit `false` vetoes; a hook that returns nothing is the
    -- common "just observe it" case and must not block the delete.
    local observed = nil
    local rok = file.delete_current({
      mode = "permanent",
      on_before_delete = function(p)
        observed = p
      end,
    })
    ok(rok, "a hook returning nil does not veto")
    eq(observed, fn.fnamemodify(victim, ":p"), "the hook was handed the absolute path")
    eq(fn.filereadable(victim), 0, "the delete went through")
  end

  -- ── diagnose_lock ────────────────────────────────────────────────────────
  -- The holder lookup spawns a helper process, so the real
  -- `lib.nvim.cross.fs.lock` is stubbed: what is under test is fileops's own
  -- path resolution and callback contract, not lib.nvim's process code.
  do
    local dir = H.tmpdir()
    local locked = dir .. "locked.txt"
    H.write_file(locked, "x")
    H.edit(locked)

    local asked_for = nil
    local restore = H.stub("lib.nvim.cross.fs.lock", {
      report = function(path, cb)
        asked_for = path
        cb({ "line one", "line two" })
      end,
    })

    local seen_ok, seen_msg
    file.diagnose_lock(function(o, m)
      seen_ok, seen_msg = o, m
    end)
    eq(asked_for, fn.fnamemodify(locked, ":p"), "diagnose_lock defaults to the buffer's own file")
    eq(seen_ok, true, "diagnose_lock reports success once lib.nvim answered")
    eq(seen_msg, "line one\nline two", "diagnose_lock joins the report lines")

    -- An explicit path wins over the buffer's file.
    local other = dir .. "other.txt"
    H.write_file(other, "x")
    file.diagnose_lock(function() end, other)
    eq(asked_for, other, "diagnose_lock uses an explicitly passed path as-is")

    restore()

    vim.cmd("enew")
    local nok, nmsg
    file.diagnose_lock(function(o, m)
      nok, nmsg = o, m
    end)
    eq(nok, false, "diagnose_lock on a nameless buffer answers through the callback")
    eq(nmsg, "current buffer has no file name", "diagnose_lock names the missing file name")
  end

  -- ── a source that vanished under an open buffer ──────────────────────────
  -- Every buffer-bound op has to notice that the file it is about to touch is
  -- no longer there, and say so in its own words.
  do
    local dir = H.tmpdir()
    local ghost = dir .. "ghost.txt"
    H.write_file(ghost, "x")
    H.edit(ghost)
    fn.delete(ghost)

    local cok, cmsg = file.copy(dir .. "ghost_copy.txt")
    ok(not cok, "copy notices the vanished source")
    ok(tostring(cmsg):find("source file does not exist", 1, true) ~= nil, "copy says so: " .. cmsg)

    local rok, rmsg = file.rename(dir .. "ghost_renamed.txt")
    ok(not rok, "rename notices the vanished source")
    ok(
      tostring(rmsg):find("source file does not exist or is not readable", 1, true) ~= nil,
      "rename says so: " .. tostring(rmsg)
    )

    local dok, dmsg = file.delete_current({ mode = "permanent" })
    ok(not dok, "delete_current notices the vanished file")
    ok(
      tostring(dmsg):find("file does not exist or is not readable", 1, true) ~= nil,
      "delete_current says so: " .. tostring(dmsg)
    )

    eq(fn.filereadable(dir .. "ghost_copy.txt"), 0, "nothing was created from a vanished source")
  end
end

return function(H)
  H.run_preserved(spec)
end
