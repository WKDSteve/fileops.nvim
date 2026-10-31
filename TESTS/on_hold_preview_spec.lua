-- TESTS/on_hold_preview_spec.lua — features/on_hold.lua: the preview it
-- actually renders, which autocmds_spec.lua's event-wiring section
-- deliberately leaves out ("the preview itself chains `git blame` → `git
-- show` in two subprocesses").
--
-- That exclusion is narrower than it used to read: git is real in
-- git_spec.lua/git_async_spec.lua too, against a real temp repo, skipping
-- itself when git is unusable — the same trade this file makes. Nothing
-- here needs vim.system stubbed; a real repo drives the real two-subprocess
-- chain end to end, exactly like it does for a user.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local fn, api = vim.fn, vim.api

  local dir = H.tmpdir()

  local function run(...)
    return vim.system({ ... }, { text = true, cwd = dir }):wait()
  end

  local init_res = run("git", "init", "-q")
  if init_res.code ~= 0 then
    print("skip  on_hold_preview_spec.lua: git not usable (" .. tostring(init_res.stderr) .. ")")
    return
  end
  run("git", "config", "user.email", "test@example.com")
  run("git", "config", "user.name", "Test")

  local on_hold = require("fileops.features.on_hold")
  local NS = api.nvim_create_namespace("fileops_on_hold_preview")

  ---@param group string
  local function drop_group(group)
    pcall(api.nvim_del_augroup_by_name, group)
  end

  ---@param group string
  ---@return table[]
  local function autocmds_of(group)
    local got, res = pcall(api.nvim_get_autocmds, { group = group })
    return (got and res) or {}
  end

  ---@param buf integer
  ---@return table[]
  local function extmarks_of(buf)
    return api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })
  end

  -- Upper bound for a preview that is supposed to appear. `vim.wait` returns the moment the
  -- condition holds, so a generous bound costs nothing on a green run; it only has to outlast the
  -- chain of real git subprocesses (rev-parse, blame, show) on a loaded Windows machine, where a
  -- single git call takes ~0.5 s and a whole chain has been measured at 7 s.
  local APPEAR_TIMEOUT_MS = 20000

  ---@param buf integer
  ---@param want integer
  ---@return table[]
  local function wait_for_extmarks(buf, want)
    local marks = {}
    vim.wait(APPEAR_TIMEOUT_MS, function()
      marks = extmarks_of(buf)
      return #marks >= want
    end, 20)
    return marks
  end

  local prev_updatetime = vim.o.updatetime

  local function teardown()
    drop_group("fileops_on_hold_preview")
    drop_group("fileops_on_hold_modeclear")
    drop_group("fileops_on_hold_cleanup")
    vim.o.updatetime = prev_updatetime
    package.loaded["gitsigns"] = nil
    package.loaded["gitsuite.features.blame"] = nil
  end

  -- ── happy path: a clean, committed line previews as virtual text ───────────
  do
    local target = dir .. "held.txt"
    H.write_file(target, "committed one\ncommitted two\n")
    run("git", "add", "held.txt")
    run("git", "commit", "-q", "-m", "add held.txt")

    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "git",
      prefer_inline = false,
    })

    vim.cmd("only")
    local buf = H.edit(target)
    -- Buffer-only edit: disk (and therefore git blame's view of the file)
    -- still says "committed one" — the point of the feature is to show that
    -- committed content beside an in-progress, unsaved edit.
    api.nvim_buf_set_lines(buf, 0, 1, false, { "buffer-only edit, never written" })
    api.nvim_win_set_cursor(0, { 1, 0 })

    ok(
      pcall(api.nvim_exec_autocmds, "CursorHold", {}),
      "firing on a clean committed line does not error"
    )
    local marks = wait_for_extmarks(buf, 1)
    eq(#marks, 1, "the committed content of the cursor line renders as one extmark")
    local virt = marks[1][4].virt_text
    local text = virt[1][1]
    eq(text, "previous: committed one", "default prefix, and the committed (not buffer) text")
    eq(marks[1][4].virt_text_pos, "eol", "default position is end-of-line")
    eq(virt[1][2], "Comment", "default highlight group is Comment")
    eq(marks[1][2], 0, "placed on row 0 (0-indexed), matching the 1-indexed cursor line")

    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end

  -- ── config is honoured: position, prefix, highlight, truncation ────────────
  do
    local target = dir .. "configured.txt"
    local long_line = ("x"):rep(200)
    H.write_file(target, long_line .. "\nsecond\n")
    run("git", "add", "configured.txt")
    run("git", "commit", "-q", "-m", "add configured.txt")

    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "git",
      prefer_inline = false,
      right_align = true,
      prefix = "was: ",
      hl_prev = "WarningMsg",
      max_len = 20,
    })

    vim.cmd("only")
    local buf = H.edit(target)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "edited, unsaved" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    api.nvim_exec_autocmds("CursorHold", {})

    local marks = wait_for_extmarks(buf, 1)
    eq(#marks, 1, "a configured preview still renders exactly once")
    local virt = marks[1][4].virt_text
    eq(marks[1][4].virt_text_pos, "right_align", "right_align = true is honoured")
    eq(virt[1][2], "WarningMsg", "hl_prev is honoured")
    ok(virt[1][1]:sub(1, 5) == "was: ", "the custom prefix is honoured: " .. virt[1][1])
    local body = virt[1][1]:sub(6)
    -- max_len is documented as "this many characters", not bytes — checked by
    -- character count so this holds for the plain-ASCII case here too.
    eq(
      fn.strchars(body),
      20,
      "max_len truncates the committed line to exactly that many characters"
    )
    ok(body:sub(-4) == " …", "truncation marks itself with a trailing ellipsis: " .. body)

    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end

  -- BUG: `truncate()` used `#s`/`string.sub` (byte-indexed) against a limit
  -- documented as a character count. Harmless for ASCII, but a previous line
  -- with any multi-byte UTF-8 character could be sliced mid-character right
  -- at the cut point, hand `nvim_buf_set_extmark` a malformed byte sequence
  -- for its `virt_text` (it does not reject one — it silently renders the
  -- mangled bytes). Fixed to slice and count by character
  -- (`strchars`/`strcharpart`), which is a no-op for the ASCII case above.
  do
    local target = dir .. "unicode.txt"
    -- 20 "é" (U+00E9, 2 bytes each): byte-slicing at n-2=7 lands inside the
    -- 4th character; character-slicing at 7 does not.
    H.write_file(target, string.rep("é", 20) .. "\nsecond\n")
    run("git", "add", "unicode.txt")
    run("git", "commit", "-q", "-m", "add unicode.txt")

    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "git",
      prefer_inline = false,
      max_len = 9,
    })

    vim.cmd("only")
    local buf = H.edit(target)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "edited, unsaved" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    api.nvim_exec_autocmds("CursorHold", {})

    local marks = wait_for_extmarks(buf, 1)
    eq(#marks, 1, "a multi-byte committed line still renders a preview")
    local body = marks[1][4].virt_text[1][1]:sub(#"previous: " + 1)
    eq(fn.strchars(body), 9, "max_len = 9 counts 9 CHARACTERS, not 9 bytes, for multi-byte content")
    eq(body, "ééééééé …", "…and none of the multi-byte characters were sliced in half")

    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end

  -- ── an uncommitted line previews nothing, silently ──────────────────────────
  do
    local target = dir .. "dirty.txt"
    H.write_file(target, "committed content\nsecond\n")
    run("git", "add", "dirty.txt")
    run("git", "commit", "-q", "-m", "add dirty.txt")
    -- Changed on disk (not just in a buffer) without committing: `git blame`
    -- attributes this line to the all-zero "not committed yet" placeholder,
    -- `git show <that>:file` cannot resolve it, and the chain must end at
    -- `cb(nil)` rather than render stale or garbage content.
    H.write_file(target, "UNCOMMITTED on-disk change\nsecond\n")

    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "git",
      prefer_inline = false,
    })

    vim.cmd("only")
    local buf = H.edit(target)
    api.nvim_win_set_cursor(0, { 1, 0 })
    api.nvim_exec_autocmds("CursorHold", {})
    vim.wait(1500)
    eq(#extmarks_of(buf), 0, "an uncommitted line renders no preview at all")
  end

  -- ── only_tracked gates an untracked file ────────────────────────────────────
  do
    local target = dir .. "untracked.txt"
    H.write_file(target, "never added\nsecond\n")

    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "git",
      prefer_inline = false,
      only_tracked = true,
    })

    vim.cmd("only")
    local buf = H.edit(target)
    api.nvim_win_set_cursor(0, { 1, 0 })
    api.nvim_exec_autocmds("CursorHold", {})
    vim.wait(1500)
    eq(#extmarks_of(buf), 0, "only_tracked = true skips a file git has never added")
  end

  -- ── gitsigns' inline preview takes priority, and restores the view ─────────
  do
    -- Its own file, not a reuse of "held.txt": an earlier case in this suite
    -- leaves buffers it dirtied on purpose sitting there unsaved, and
    -- re-`:edit`-ing the same path would hit "E37: No write since last
    -- change" rather than exercising anything about on_hold.
    local target = dir .. "gs_ok.txt"
    H.write_file(target, "committed one\ncommitted two\n")
    run("git", "add", "gs_ok.txt")
    run("git", "commit", "-q", "-m", "add gs_ok.txt")

    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "git",
      prefer_inline = true,
      restore_view = true,
    })

    local moved_to = nil
    package.loaded["gitsigns"] = {
      preview_hunk_inline = function()
        moved_to = { 2, 0 }
        api.nvim_win_set_cursor(0, moved_to)
      end,
    }

    vim.cmd("only")
    local buf = H.edit(target)
    api.nvim_win_set_cursor(0, { 1, 0 })
    api.nvim_exec_autocmds("CursorHold", {})

    -- The route to gitsigns still goes through the same async `in_git_repo_async`
    -- git check as the fallback path, so it is no more synchronous than that.
    local win = api.nvim_get_current_win()
    vim.wait(APPEAR_TIMEOUT_MS, function()
      return moved_to ~= nil
    end, 10)
    ok(moved_to ~= nil, "gitsigns.preview_hunk_inline is preferred and actually called")
    local restored = vim.wait(500, function()
      return api.nvim_win_get_cursor(win)[1] == 1
    end, 10)
    ok(restored, "restore_view = true puts the cursor back after gitsigns previews")
    eq(#extmarks_of(buf), 0, "the fallback NS extmark is never set once gitsigns has handled it")
    ok(
      #autocmds_of("fileops_on_hold_cleanup") > 0,
      "a cleanup autocmd is registered for the inline preview too"
    )

    package.loaded["gitsigns"] = nil
  end

  -- ── a broken gitsigns preview falls back to the git blame/show chain ───────
  do
    local target = dir .. "gs_broken.txt"
    H.write_file(target, "committed one\ncommitted two\n")
    run("git", "add", "gs_broken.txt")
    run("git", "commit", "-q", "-m", "add gs_broken.txt")

    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "git",
      prefer_inline = true,
    })

    package.loaded["gitsigns"] = {
      preview_hunk_inline = function()
        error("boom: gitsigns blew up")
      end,
    }

    vim.cmd("only")
    local buf = H.edit(target)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "buffer-only edit again" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    ok(
      pcall(api.nvim_exec_autocmds, "CursorHold", {}),
      "a gitsigns error never escapes as a spec-crashing error"
    )

    local marks = wait_for_extmarks(buf, 1)
    eq(#marks, 1, "…and the git blame/show fallback still renders the preview")

    package.loaded["gitsigns"] = nil
    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end

  -- ── the cleanup autocmd actually clears the rendered preview ────────────────
  do
    local target = dir .. "cleanup.txt"
    H.write_file(target, "committed one\ncommitted two\n")
    run("git", "add", "cleanup.txt")
    run("git", "commit", "-q", "-m", "add cleanup.txt")

    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "git",
      prefer_inline = false,
    })

    vim.cmd("only")
    local buf = H.edit(target)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "buffer-only edit once more" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    api.nvim_exec_autocmds("CursorHold", {})
    wait_for_extmarks(buf, 1)
    eq(#extmarks_of(buf), 1, "setup: the preview is showing")

    api.nvim_exec_autocmds("CursorMoved", {})
    eq(#extmarks_of(buf), 0, "CursorMoved clears it")
  end

  -- ── the blame half can be delegated to gitsuite.nvim (optional, GS-26) ───
  do
    local target = dir .. "held_gitsuite.txt"
    H.write_file(target, "committed one\ncommitted two\n")
    run("git", "add", "held_gitsuite.txt")
    run("git", "commit", "-q", "-m", "add held_gitsuite.txt")
    local head = run("git", "rev-parse", "HEAD")
    local sha = vim.trim(head.stdout)

    on_hold.setup({
      enable = true,
      modes = "n",
      throttle_ms = 0,
      git_cmd = "git",
      prefer_inline = false,
    })

    local for_location_calls = {}
    package.loaded["gitsuite.features.blame"] = {
      for_location = function(cwd_arg, path_arg, lnum_arg, cb)
        for_location_calls[#for_location_calls + 1] =
          { cwd = cwd_arg, path = path_arg, lnum = lnum_arg }
        cb({ sha = sha }, nil)
      end,
    }

    vim.cmd("only")
    local buf = H.edit(target)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "buffer-only edit, never written" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    api.nvim_exec_autocmds("CursorHold", {})

    local marks = wait_for_extmarks(buf, 1)
    eq(#marks, 1, "gitsuite.nvim's blame.for_location backs the preview when installed")
    eq(#for_location_calls, 1, "...and is actually called, exactly once")
    eq(for_location_calls[1].lnum, 1, "...for the cursor's line")
    local text = marks[1][4].virt_text[1][1]
    eq(text, "previous: committed one", "...and the git-show half still renders the real content")

    package.loaded["gitsuite.features.blame"] = nil
    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end

  teardown()
end

return function(H)
  H.run_preserved(spec)
end
