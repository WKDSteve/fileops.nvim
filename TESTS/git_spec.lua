-- TESTS/git_spec.lua — util/git.lua: is_tracked/mv/rm against a real repo.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local git = require("fileops.util.git")

  local dir = H.tmpdir()

  local function run(...)
    return vim.system({ ... }, { text = true, cwd = dir }):wait()
  end

  local init_res = run("git", "init", "-q")
  if init_res.code ~= 0 then
    -- No git available in this environment; skip rather than fail the suite.
    print("skip  git_spec.lua: git not usable (" .. tostring(init_res.stderr) .. ")")
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

  -- is_tracked
  ok(git.is_tracked(tracked_path), "is_tracked: true for a committed file")
  ok(not git.is_tracked(untracked_path), "is_tracked: false for a never-added file")
  ok(not git.is_tracked(dir .. "does_not_exist.txt"), "is_tracked: false for a missing file")

  -- mv: renames on disk AND keeps the new name tracked
  local dest_path = dir .. "renamed.txt"
  local mv_ok, mv_err = git.mv(tracked_path, dest_path)
  ok(mv_ok, "mv succeeds: " .. tostring(mv_err))
  eq(vim.fn.filereadable(tracked_path), 0, "mv: old path no longer exists")
  eq(vim.fn.filereadable(dest_path), 1, "mv: new path exists")
  ok(git.is_tracked(dest_path), "mv: new path is still tracked")

  -- A git that cannot be started is "not tracked", not a crash: every caller
  -- treats unknown the same as untracked.
  ok(
    not git.is_tracked(tracked_path, "fileops-no-such-git-executable"),
    "is_tracked: false when the configured git executable cannot run"
  )

  -- mv/rm surface git's own stderr instead of a bare "failed".
  local bad_mv_ok, bad_mv_err = git.mv(dir .. "does_not_exist.txt", dir .. "elsewhere.txt")
  ok(not bad_mv_ok, "mv: fails for a source git does not know")
  ok(type(bad_mv_err) == "string" and bad_mv_err ~= "", "mv: reports why: " .. tostring(bad_mv_err))

  local bad_rm_ok, bad_rm_err = git.rm(dir .. "does_not_exist.txt")
  ok(not bad_rm_ok, "rm: fails for a path git does not know")
  ok(type(bad_rm_err) == "string" and bad_rm_err ~= "", "rm: reports why: " .. tostring(bad_rm_err))

  local unstartable_ok, unstartable_err = git.rm(untracked_path, "fileops-no-such-git-executable")
  ok(not unstartable_ok, "rm: fails when the configured git executable cannot run")
  ok(type(unstartable_err) == "string", "…with an error string rather than a raised error")

  -- rm: removes from disk and the index
  local rm_ok, rm_err = git.rm(dest_path)
  ok(rm_ok, "rm succeeds: " .. tostring(rm_err))
  eq(vim.fn.filereadable(dest_path), 0, "rm: file removed from disk")
  local status = run("git", "status", "--porcelain")
  eq(
    status.stdout:match("renamed%.txt"),
    nil,
    "rm: no longer shows up in git status (fully removed)"
  )
end

return function(H)
  H.run_preserved(spec)
end
