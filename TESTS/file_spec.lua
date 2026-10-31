-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
--
-- `fsops.rename_file` is replaced below as a test double, for the length of
-- one case, and restored right after.
---@diagnostic disable: duplicate-set-field
-- TESTS/file_spec.lua — ops/file.lua: copy/move/touch and friends.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local file = require("fileops.ops.file")

  local dir = H.tmpdir()
  local src = dir .. "src.lua"
  H.write_file(src, "-- src")

  -- copy: creates the destination, does NOT switch the current buffer
  H.edit(src)
  local dest = dir .. "src_copy.lua"
  local cok, cmsg = file.copy(dest)
  ok(cok, "copy succeeds: " .. tostring(cmsg))
  eq(vim.fn.filereadable(dest), 1, "copy: destination file exists")
  eq(vim.fn.expand("%:p"), vim.fn.fnamemodify(src, ":p"), "copy: current buffer name unchanged")

  -- copy refuses to overwrite without bang
  local cok2, cmsg2 = file.copy(dest)
  ok(not cok2, "copy without bang refuses existing destination: " .. tostring(cmsg2))

  -- copy! overwrites
  local cok3 = file.copy(dest, { bang = true })
  ok(cok3, "copy! overwrites existing destination")

  -- move: renames on disk, updates the buffer name, does NOT reload the
  -- buffer (undo history survives — a fresh :edit would reset it to 0)
  local src2 = dir .. "movable.lua"
  H.write_file(src2, "line1")
  H.edit(src2)
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "line1 changed" })
  ok(vim.fn.undotree().seq_cur > 0, "setup: buffer has undo history before move")

  local dest2 = dir .. "moved.lua"
  local mok, mmsg = file.move(dest2)
  ok(mok, "move succeeds: " .. tostring(mmsg))
  eq(vim.fn.filereadable(dest2), 1, "move: destination file exists")
  eq(vim.fn.filereadable(src2), 0, "move: source file no longer exists")
  eq(vim.fn.expand("%:p"), vim.fn.fnamemodify(dest2, ":p"), "move: buffer renamed to destination")
  ok(vim.fn.undotree().seq_cur > 0, "move: undo history preserved (buffer not reloaded)")

  -- move refuses to overwrite without bang, move! overwrites
  local other = dir .. "other.lua"
  H.write_file(other, "other")
  H.edit(other)
  local mok2, mmsg2 = file.move(dest2)
  ok(not mok2, "move without bang refuses existing destination: " .. tostring(mmsg2))
  local mok3 = file.move(dest2, { bang = true })
  ok(mok3, "move! overwrites existing destination")

  -- rename with a bare name resolves against the *file's* directory, not the
  -- cwd — otherwise editing a file from elsewhere in the tree silently moves
  -- it into the cwd instead of renaming it in place.
  do
    local elsewhere = H.tmpdir()
    local rel_src = dir .. "rel_src.lua"
    H.write_file(rel_src, "-- rel")
    H.edit(rel_src)

    local prev_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(elsewhere))
    local rok, rmsg = file.rename("rel_dest.lua")
    vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))

    ok(rok, "rename with a relative name succeeds: " .. tostring(rmsg))
    eq(
      vim.fn.filereadable(dir .. "rel_dest.lua"),
      1,
      "rename: relative destination lands next to the source file"
    )
    eq(
      vim.fn.filereadable(elsewhere .. "rel_dest.lua"),
      0,
      "rename: relative destination is NOT resolved against the cwd"
    )
    eq(vim.fn.filereadable(rel_src), 0, "rename: source file no longer exists")
  end

  -- A Windows sharing violation can't be provoked from inside this process
  -- (libuv opens files with FILE_SHARE_DELETE), so the retry contract is
  -- checked by swapping the primitive: fileops must hand its configured
  -- budget plus an on_retry hook down to lib.nvim, and must not surrender a
  -- bare "EBUSY" to the user.
  do
    local fsops = require("lib.nvim.cross.fs.mutate")
    local real_rename = fsops.rename_file

    local seen_opts, calls, retry_events = nil, 0, 0
    local aug = vim.api.nvim_create_augroup("FileopsRetrySpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = aug,
      pattern = "FileopsRetry",
      callback = function()
        retry_events = retry_events + 1
      end,
    })

    fsops.rename_file = function(_, _, o)
      seen_opts = o
      calls = calls + 1
      -- Mimic lib.nvim's own retry loop closely enough to prove the hook runs.
      for attempt = 1, (o and o.attempts or 1) - 1 do
        if o.on_retry then
          o.on_retry(attempt, "EBUSY: resource busy or locked")
        end
      end
      return false, "EBUSY: resource busy or locked"
    end

    local busy = dir .. "busy.lua"
    H.write_file(busy, "-- busy")
    H.edit(busy)
    local bok, bmsg =
      file.rename(dir .. "busy_renamed.lua", { retry = { attempts = 4, backoff_ms = 10 } })

    fsops.rename_file = real_rename
    vim.api.nvim_del_augroup_by_id(aug)

    ok(not bok, "rename reports failure when the filesystem keeps saying EBUSY")
    eq(calls, 1, "rename delegates to lib.nvim's retrying primitive")
    eq(seen_opts and seen_opts.attempts, 4, "rename passes the configured attempt budget down")
    eq(seen_opts and seen_opts.backoff_ms, 10, "rename passes the configured backoff down")
    eq(retry_events, 3, "each retry fires a User FileopsRetry event so listeners can drop handles")
    ok(
      tostring(bmsg):find("another process is holding the file open", 1, true) ~= nil,
      "EBUSY is explained rather than surfaced as a bare libuv code: " .. tostring(bmsg)
    )
  end

  -- touch: creates a 0-byte file, doesn't need a buffer
  local touched = dir .. "touched.lua"
  eq(vim.fn.filereadable(touched), 0, "setup: touch target does not exist yet")
  local tok, tmsg = file.touch(touched)
  ok(tok, "touch succeeds: " .. tostring(tmsg))
  eq(vim.fn.filereadable(touched), 1, "touch: file now exists")
  eq(vim.fn.getfsize(touched), 0, "touch: file is 0 bytes")

  -- touch on an existing file is a no-op (does not truncate)
  H.write_file(touched, "not empty")
  local tok2, tmsg2 = file.touch(touched)
  ok(tok2, "touch on existing file still reports success: " .. tostring(tmsg2))
  eq(vim.fn.getfsize(touched), 9, "touch: existing file content untouched")

  -- touch creates parent directories
  local nested = dir .. "nested/dir/new.lua"
  local tok3 = file.touch(nested)
  ok(tok3, "touch creates missing parent directories")
  eq(vim.fn.filereadable(nested), 1, "touch: nested file exists")

  -- delete_current: on_before_delete returning false aborts before disk/buffer
  -- are touched; default mode ("permanent"/unset) actually deletes.
  local vetoed = dir .. "vetoed.lua"
  H.write_file(vetoed, "keep me")
  local vbuf = H.edit(vetoed)
  local dok1, dmsg1 = file.delete_current({
    on_before_delete = function()
      return false
    end,
  })
  ok(not dok1, "delete_current: on_before_delete=false aborts: " .. tostring(dmsg1))
  eq(vim.fn.filereadable(vetoed), 1, "delete_current: vetoed file still exists")
  ok(vim.api.nvim_buf_is_valid(vbuf), "delete_current: vetoed buffer still valid")

  local deletable = dir .. "deletable.lua"
  H.write_file(deletable, "bye")
  H.edit(deletable)
  local seen_path = nil
  local dok2, dmsg2 = file.delete_current({
    on_before_delete = function(p)
      seen_path = p
      return true
    end,
  })
  ok(dok2, "delete_current: on_before_delete=true proceeds: " .. tostring(dmsg2))
  eq(vim.fn.filereadable(deletable), 0, "delete_current: file actually deleted")
  eq(seen_path, vim.fn.fnamemodify(deletable, ":p"), "delete_current: hook received the file path")

  -- copy_path: writes the requested representation to the unnamed register
  local pathed = dir .. "pathed.lua"
  H.write_file(pathed, "-- pathed")
  H.edit(pathed)

  local abs_ok = file.copy_path("abs")
  ok(abs_ok, "copy_path abs succeeds")
  eq(
    vim.fn.getreg('"'),
    vim.fn.fnamemodify(pathed, ":p"),
    "copy_path abs: register holds absolute path"
  )

  local name_ok = file.copy_path("name")
  ok(name_ok, "copy_path name succeeds")
  eq(vim.fn.getreg('"'), "pathed.lua", "copy_path name: register holds file name only")

  local dir_ok = file.copy_path("dir")
  ok(dir_ok, "copy_path dir succeeds")
  eq(
    vim.fn.getreg('"'),
    vim.fn.fnamemodify(pathed, ":p:h"),
    "copy_path dir: register holds containing directory"
  )

  -- default mode (no arg) behaves like "abs"
  local default_ok = file.copy_path(nil)
  ok(default_ok, "copy_path with no mode succeeds")
  eq(vim.fn.getreg('"'), vim.fn.fnamemodify(pathed, ":p"), "copy_path nil: defaults to abs")

  -- Deliberately outside the alias: rejecting an unknown mode is the point.
  ---@diagnostic disable-next-line: param-type-mismatch
  local bad_ok, bad_msg = file.copy_path("bogus")
  ok(not bad_ok, "copy_path rejects unknown mode: " .. tostring(bad_msg))

  -- info: reports size/mtime/permissions for the current buffer's file
  local infoed = dir .. "infoed.lua"
  H.write_file(infoed, "0123456789") -- 10 bytes
  H.edit(infoed)
  local iok, imsg = file.info()
  ok(iok, "info succeeds: " .. tostring(imsg))
  ok(imsg:find("infoed.lua", 1, true) ~= nil, "info: message includes the file path")
  ok(imsg:find("10 bytes", 1, true) ~= nil, "info: message includes the byte size")

  -- touch/rename/delete fire a "User FileopsChanged" autocmd with {action, path}
  local seen = {}
  local group = vim.api.nvim_create_augroup("fileops_spec_changed", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FileopsChanged",
    callback = function(ev)
      seen[#seen + 1] = ev.data
    end,
  })

  local touched2 = dir .. "changed_touch.lua"
  ok(file.touch(touched2), "touch (for event test) succeeds")
  eq(#seen, 1, "touch fired exactly one FileopsChanged event")
  eq(seen[1].action, "touch", "touch event action is 'touch'")
  eq(seen[1].path, vim.fn.fnamemodify(touched2, ":p"), "touch event path matches")

  H.edit(touched2)
  local renamed2 = dir .. "changed_renamed.lua"
  ok(file.rename(renamed2), "rename (for event test) succeeds")
  eq(#seen, 2, "rename fired a second FileopsChanged event")
  eq(seen[2].action, "rename", "rename event action is 'rename'")

  ok(file.delete_current({ force = true }), "delete_current (for event test) succeeds")
  eq(#seen, 3, "delete fired a third FileopsChanged event")
  eq(seen[3].action, "delete", "delete event action is 'delete'")

  -- refresh_explorers = false suppresses the reload call but NOT the event
  seen = {}
  local no_reload = dir .. "changed_no_reload.lua"
  ok(
    file.touch(no_reload, { refresh_explorers = false }),
    "touch with refresh_explorers=false succeeds"
  )
  eq(#seen, 1, "event still fires when refresh_explorers = false")

  vim.api.nvim_del_augroup_by_id(group)

  -- git_aware: warn_only notes tracked-ness without shelling out to mutate;
  -- warn_only=false actually uses git mv/git rm. Skips cleanly if git isn't usable.
  local gitdir = H.tmpdir()
  local function git_run(...)
    return vim.system({ ... }, { text = true, cwd = gitdir }):wait()
  end
  local init_res = git_run("git", "init", "-q")
  if init_res.code ~= 0 then
    print("skip  file_spec.lua git_aware section: git not usable")
  else
    git_run("git", "config", "user.email", "test@example.com")
    git_run("git", "config", "user.name", "Test")

    local tracked1 = gitdir .. "tracked1.txt"
    local tracked2 = gitdir .. "tracked2.txt"
    H.write_file(tracked1, "hello 1")
    H.write_file(tracked2, "hello 2")
    git_run("git", "add", "tracked1.txt", "tracked2.txt")
    git_run("git", "commit", "-q", "-m", "add tracked1/2.txt")

    -- warn_only (default): still uses libuv, message notes tracked-ness
    H.edit(tracked1)
    local renamed_a = gitdir .. "renamed_a.txt"
    local wok, wmsg = file.rename(renamed_a, { git_aware = true, git_warn_only = true })
    ok(wok, "git_aware warn_only rename succeeds: " .. tostring(wmsg))
    ok(
      wmsg:find("(git-tracked)", 1, true) ~= nil,
      "warn_only message notes git-tracked: " .. tostring(wmsg)
    )
    -- libuv rename doesn't update the git index, so the old name shows as deleted
    local status_a = git_run("git", "status", "--porcelain")
    ok(
      status_a.stdout:find("tracked1.txt", 1, true) ~= nil,
      "warn_only: git index wasn't updated (plain libuv rename)"
    )

    -- warn_only = false: uses git mv, which keeps the index in sync
    H.edit(tracked2)
    local renamed_b = gitdir .. "renamed_b.txt"
    local gok, gmsg = file.rename(renamed_b, { git_aware = true, git_warn_only = false })
    ok(gok, "git_aware git-mv rename succeeds: " .. tostring(gmsg))
    ok(gmsg:find("(git mv)", 1, true) ~= nil, "git-mv message notes git mv: " .. tostring(gmsg))
    local status_b = git_run("git", "status", "--porcelain", "--", "tracked2.txt", "renamed_b.txt")
    ok(
      status_b.stdout:match("^R"),
      "git mv: staged as a rename, not delete+add: " .. tostring(status_b.stdout)
    )

    -- delete: warn_only=false uses git rm
    H.edit(renamed_b)
    local dgok, dgmsg = file.delete_current({
      force = true,
      mode = "permanent",
      git_aware = true,
      git_warn_only = false,
    })
    ok(dgok, "git_aware git-rm delete succeeds: " .. tostring(dgmsg))
    ok(dgmsg:find("(git rm)", 1, true) ~= nil, "git-rm message notes git rm: " .. tostring(dgmsg))
    eq(vim.fn.filereadable(renamed_b), 0, "git rm: file removed from disk")
  end

  -- session_compat: rename/move resave the active `:mksession` session
  -- (v:this_session) only when opts.session_compat = true AND a session is
  -- active; otherwise it's a no-op. Restores v:this_session afterwards so
  -- this doesn't leak into specs that run after this one.
  do
    local prev_session = vim.v.this_session
    local sess_dir = H.tmpdir()
    local sess_file = sess_dir .. "Session.vim"

    -- no active session: session_compat = true is a silent no-op, not an error
    vim.v.this_session = ""
    local a = dir .. "sess_a.lua"
    H.write_file(a, "-- a")
    H.edit(a)
    local sok1 = file.rename(dir .. "sess_a2.lua", { session_compat = true })
    ok(sok1, "rename with session_compat=true but no active session still succeeds")
    eq(vim.v.this_session, "", "no active session: v:this_session stays empty")

    -- active session + session_compat = true: resaves, new path lands in the file
    H.edit(dir .. "sess_a2.lua")
    vim.cmd("mksession! " .. vim.fn.fnameescape(sess_file))
    eq(
      vim.v.this_session,
      vim.fn.fnamemodify(sess_file, ":p"),
      "setup: mksession! sets v:this_session"
    )

    local sess_b_old = dir .. "sess_b.lua"
    H.write_file(sess_b_old, "-- b")
    H.edit(sess_b_old)
    vim.cmd("mksession! " .. vim.fn.fnameescape(sess_file)) -- capture sess_b as part of the session

    local sess_b_new = dir .. "sess_b_renamed.lua"
    local sok2, smsg2 = file.rename(sess_b_new, { session_compat = true })
    ok(sok2, "rename with session_compat=true succeeds: " .. tostring(smsg2))

    local resaved = table.concat(vim.fn.readfile(sess_file), "\n")
    ok(
      resaved:find("sess_b_renamed.lua", 1, true) ~= nil,
      "session_compat=true: resaved session references the new path"
    )
    ok(
      resaved:find("/sess_b.lua", 1, true) == nil and resaved:find("\\sess_b.lua", 1, true) == nil,
      "session_compat=true: resaved session no longer references the old path"
    )

    -- session_compat unset/false: leaves the session file untouched
    local before = table.concat(vim.fn.readfile(sess_file), "\n")
    H.edit(sess_b_new)
    local sess_c_new = dir .. "sess_c_renamed.lua"
    local sok3 = file.rename(sess_c_new, {})
    ok(sok3, "rename without session_compat still succeeds")
    local after = table.concat(vim.fn.readfile(sess_file), "\n")
    eq(after, before, "session_compat unset: session file left untouched")

    vim.v.this_session = prev_session
  end
end

return function(H)
  H.run_preserved(spec)
end
