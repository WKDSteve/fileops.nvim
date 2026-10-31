-- TESTS/git_async_spec.lua — util/git.lua: is_tracked_async/mv_async/rm_async
-- against a real temp git repo. Mirrors git_spec.lua's blocking coverage; the
-- point here is only that the async twins agree with it and never block the
-- caller past the callback (waited for via vim.wait, same as any other
-- vim.system callback consumer would).

local function spec(H)
  local eq, ok = H.eq, H.ok
  local git = require("fileops.util.git")

  local dir = H.tmpdir()

  local function run(...)
    return vim.system({ ... }, { text = true, cwd = dir }):wait()
  end

  local init_res = run("git", "init", "-q")
  if init_res.code ~= 0 then
    print("skip  git_async_spec.lua: git not usable (" .. tostring(init_res.stderr) .. ")")
    return
  end
  run("git", "config", "user.email", "test@example.com")
  run("git", "config", "user.name", "Test")

  local tracked_path = dir .. "tracked.txt"
  H.write_file(tracked_path, "hello")
  run("git", "add", "tracked.txt")
  run("git", "commit", "-q", "-m", "add tracked.txt")

  local untracked_path = dir .. "untracked.txt"
  H.write_file(untracked_path, "hello")

  ---@internal
  ---Drive an `_async` call to completion and return whatever it passed its
  ---callback, the same way `git_spec.lua` calls the blocking function directly.
  ---@param fn fun(cb: fun(...))
  ---@return any ...
  local function await(fn)
    local done, results = false, {}
    fn(function(...)
      done = true
      results = { ... }
    end)
    local ok_wait = vim.wait(2000, function()
      return done
    end, 10)
    ok(ok_wait, "async call completed within timeout")
    return results[1], results[2]
  end

  -- is_tracked_async
  ok(
    await(function(cb)
      git.is_tracked_async(tracked_path, cb)
    end),
    "is_tracked_async: true for a committed file"
  )
  ok(not await(function(cb)
    git.is_tracked_async(untracked_path, cb)
  end), "is_tracked_async: false for a never-added file")

  -- mv_async: renames on disk AND keeps the new name tracked
  local dest_path = dir .. "renamed.txt"
  local mv_ok, mv_err = await(function(cb)
    git.mv_async(tracked_path, dest_path, cb)
  end)
  ok(mv_ok, "mv_async succeeds: " .. tostring(mv_err))
  eq(vim.fn.filereadable(tracked_path), 0, "mv_async: old path no longer exists")
  eq(vim.fn.filereadable(dest_path), 1, "mv_async: new path exists")
  ok(
    await(function(cb)
      git.is_tracked_async(dest_path, cb)
    end),
    "mv_async: new path is still tracked"
  )

  -- rm_async: removes from disk and the index
  local rm_ok, rm_err = await(function(cb)
    git.rm_async(dest_path, cb)
  end)
  ok(rm_ok, "rm_async succeeds: " .. tostring(rm_err))
  eq(vim.fn.filereadable(dest_path), 0, "rm_async: file removed from disk")
  local status = run("git", "status", "--porcelain")
  eq(
    status.stdout:match("renamed%.txt"),
    nil,
    "rm_async: no longer shows up in git status (fully removed)"
  )
end

return function(H)
  H.run_preserved(spec)
end
