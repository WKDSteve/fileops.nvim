---@module 'fileops.features.on_hold'
-- handrolled-ok: one leading window per Neovim window (keyed by win id), which a single throttle handle cannot express
---Ambient, mode-aware line-diff preview on CursorHold/CursorHoldI.
---Prefers gitsigns' `preview_hunk_inline()` when available; otherwise falls
---back to rendering the previous committed content of the current line as
---EOL/right-aligned virtual text -- the blame half via gitsuite.nvim's
---`features.blame.for_location` (optional soft dep, GS-26) when installed,
---else fileops' own `git blame --porcelain`; the `git show` half is always
---fileops' own (argv-only -- no shell either way; gitsuite has no
---blob-content equivalent to delegate that to). Per-window throttling and a
---generation counter guard against stale scheduled runs after a mode change.

local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local autocmd = require("lib.nvim.bindings.autocmd")

local M = {}

---@type integer  Namespace for the fallback EOL/right-aligned virtual text
local NS = api.nvim_create_namespace("fileops_on_hold_preview")

---@internal
---Clear this feature's virtual text in a buffer.
---@param buf integer
---@return nil
local function clear_line_diff(buf)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end
end

---@internal
---@param name string
---@return integer
local function augroup(name)
  -- `autocmd.group(name, true)` drops this module's binding-table *records*
  -- along with its autocmds, so a re-run can't leave stale rows behind.
  return autocmd.group("fileops_on_hold_" .. name, true)
end

---@internal
---`max_len` is documented (DEFAULTS.lua, @types) as "this many characters",
---but a byte count and a character count only agree for pure ASCII: `#s` and
---`string.sub` both index bytes, so a previous line containing any
---multi-byte UTF-8 character (accented letters, an em dash, …) near the cut
---point used to be sliced mid-character, handing `nvim_buf_set_extmark` a
---malformed byte sequence for its `virt_text` (it does not reject one — it
---renders it, mangled). `strchars`/`strcharpart` count and slice by
---character instead, which for plain ASCII input is identical to the old
---byte math and so changes nothing for the common case.
---@param s string
---@param max_len integer
---@return string
local function truncate(s, max_len)
  if type(s) ~= "string" then
    return ""
  end
  local n = math.max(0, tonumber(max_len or 0) or 0)
  if fn.strchars(s) <= n then
    return s
  end
  if n <= 2 then
    return fn.strcharpart(s, 0, n)
  end
  return fn.strcharpart(s, 0, n - 2) .. " …"
end

---@internal
---@param first string|nil
---@return string|nil
local function parse_blame_sha(first)
  if type(first) ~= "string" or first == "" then
    return nil
  end
  local sha = first:match("^([0-9a-f]+)")
  if not sha then
    return nil
  end
  return (#sha >= 7 and #sha <= 40) and sha or nil
end

---@internal
---@param win integer
---@return integer
local function get_lnum(win)
  return api.nvim_win_get_cursor(win)[1]
end

---@internal
---Normalize Neovim's mode string to one of "n"|"v"|"i".
---@return "n"|"v"|"i"|nil
local function normalize_mode()
  local m = fn.mode(1)
  if m == "i" then
    return "i"
  end
  if m == "n" or m == "no" then
    return "n"
  end
  if m == "v" or m == "V" or m == "\022" then
    return "v"
  end
  return nil
end

---@internal
---@param modes string|string[]|nil
---@return boolean
local function mode_allowed(modes)
  if modes == nil then
    return normalize_mode() ~= "i"
  end
  local want = {}
  if type(modes) == "string" then
    for c in modes:gmatch(".") do
      want[c] = true
    end
  else
    for _, c in ipairs(modes) do
      want[c] = true
    end
  end
  local cur = normalize_mode()
  return cur ~= nil and want[cur] == true
end

---@internal
---@param stdout string|nil
---@return string[]
local function to_lines(stdout)
  if type(stdout) ~= "string" or stdout == "" then
    return {}
  end
  return vim.split((stdout:gsub("\n$", "")), "\n", { plain = true })
end

---@internal
---Async: never blocks the UI thread, even on a slow filesystem (network
---share, WSL interop) or a large repo — `cb` runs on the next main-loop tick
---via `vim.schedule`, exactly like `util/git.lua`'s `_async` twins.
---@param git_cmd string
---@param cwd string  Directory to run git in — the buffer's own directory, not
---Neovim's (possibly unrelated) global cwd. See `util/git.lua`, which uses
---the same pattern for the same reason.
---@param cb fun(is_repo: boolean)
---@return nil
local function in_git_repo_async(git_cmd, cwd, cb)
  local ok = pcall(function()
    vim.system(
      { git_cmd, "rev-parse", "--is-inside-work-tree" },
      { text = true, cwd = cwd },
      function(res)
        vim.schedule(function()
          cb(res.code == 0)
        end)
      end
    )
  end)
  if not ok then
    vim.schedule(function()
      cb(false)
    end)
  end
end

---@internal
---@param git_cmd string
---@param file string
---@param cwd string
---@param cb fun(tracked: boolean)
---@return nil
local function is_tracked_async(git_cmd, file, cwd, cb)
  local ok = pcall(function()
    vim.system(
      { git_cmd, "ls-files", "--error-unmatch", "--", file },
      { text = true, cwd = cwd },
      function(res)
        vim.schedule(function()
          cb(res.code == 0)
        end)
      end
    )
  end)
  if not ok then
    vim.schedule(function()
      cb(false)
    end)
  end
end

---@internal
---@param ignore_buftypes string[]|nil
---@return boolean
local function normal_buf_allowed(ignore_buftypes)
  local bt = vim.bo.buftype or ""
  if ignore_buftypes and vim.tbl_contains(ignore_buftypes, bt) then
    return false
  end
  return bt == "" or bt == "acwrite"
end

---@internal
---`git show <rev>:<path>` for line `lnum`, once a blame step (either path
---below) has resolved `sha` -- nil `sha` (blame found nothing, or the line
---is uncommitted, whose all-zero sha `git show` simply fails to resolve)
---calls `cb(nil)` without spawning anything.
---@param git_cmd string
---@param file string
---@param lnum integer
---@param cwd string
---@param cb fun(prev_line: string|nil)
---@param sha string|nil
---@return nil
local function show_line_at(git_cmd, file, lnum, cwd, cb, sha)
  if not sha then
    return vim.schedule(function()
      cb(nil)
    end)
  end
  -- `git show <rev>:<path>` resolves `<path>` against the repository
  -- root, never against the filesystem — an absolute path here always
  -- fails with "path '...' does not exist in '<rev>'" even though the
  -- exact same path is fine as `git blame`'s pathspec above. `cwd` is
  -- already this file's own directory, so `./<basename>` is the form
  -- git resolves relative to *that* instead.
  local show_started = pcall(function()
    vim.system(
      { git_cmd, "show", sha .. ":./" .. fn.fnamemodify(file, ":t") },
      { text = true, cwd = cwd },
      function(blob_res)
        vim.schedule(function()
          if blob_res.code ~= 0 then
            return cb(nil)
          end
          local blob = to_lines(blob_res.stdout)
          if #blob == 0 or lnum > #blob then
            return cb(nil)
          end
          cb(blob[lnum])
        end)
      end
    )
  end)
  if not show_started then
    vim.schedule(function()
      cb(nil)
    end)
  end
end

---@internal
---Async: resolves the sha that last touched `lnum`, then `git show`s it --
---neither step blocks the UI thread. `cb` is always called exactly once,
---scheduled onto the main loop.
---
---gitsuite.nvim (optional soft dep, GS-26) backs the blame step when
---installed, reusing its parser instead of fileops maintaining its own
---`git blame --porcelain` SHA extraction. That path always runs plain
---"git" internally, not `git_cmd` -- the `git show` step below still
---honours the configured one either way; gitsuite has no equivalent to
---delegate that half to (see gitsuite's own Querschnittsbefund #1).
---@param git_cmd string
---@param file string
---@param lnum integer
---@param cwd string
---@param cb fun(prev_line: string|nil)
---@return nil
local function get_previous_line_async(git_cmd, file, lnum, cwd, cb)
  local ok_gitsuite, gitsuite_blame = pcall(require, "gitsuite.features.blame")
  if ok_gitsuite then
    gitsuite_blame.for_location(cwd, file, lnum, function(entry, _err)
      show_line_at(git_cmd, file, lnum, cwd, cb, entry and entry.sha or nil)
    end)
    return
  end

  local started = pcall(function()
    vim.system(
      { git_cmd, "blame", "-L", lnum .. "," .. lnum, "--porcelain", "--", file },
      { text = true, cwd = cwd },
      function(blame_res)
        if blame_res.code ~= 0 then
          return vim.schedule(function()
            cb(nil)
          end)
        end
        local blame = to_lines(blame_res.stdout)
        local sha = #blame > 0 and parse_blame_sha(blame[1]) or nil
        show_line_at(git_cmd, file, lnum, cwd, cb, sha)
      end
    )
  end)
  if not started then
    vim.schedule(function()
      cb(nil)
    end)
  end
end

---@internal
---@param modes string|string[]|nil
---@param events_override string[]|nil
---@return string[]
local function effective_events(modes, events_override)
  if type(events_override) == "table" and #events_override > 0 then
    return events_override
  end
  local has_n, has_v, has_i = false, false, false
  if modes == nil then
    has_n, has_v = true, true
  elseif type(modes) == "string" then
    has_n = modes:find("n", 1, true) ~= nil
    has_v = modes:find("v", 1, true) ~= nil
    has_i = modes:find("i", 1, true) ~= nil
  else
    for _, c in ipairs(modes) do
      if c == "n" then
        has_n = true
      elseif c == "v" then
        has_v = true
      elseif c == "i" then
        has_i = true
      end
    end
  end
  local ev = {}
  if has_n or has_v then
    ev[#ev + 1] = "CursorHold"
  end
  if has_i then
    ev[#ev + 1] = "CursorHoldI"
  end
  if #ev == 0 then
    ev = { "CursorHold" }
  end
  return ev
end

---Register the CursorHold/CursorHoldI line-diff preview autocmds if enabled.
---@param cfg FileOps.OnHoldConfig
---@return nil
function M.setup(cfg)
  cfg = cfg or {}
  if cfg.enable == false then
    return
  end

  local prefer_inline = (cfg.prefer_inline ~= false)
  local restore_view = (cfg.restore_view ~= false)
  local throttle_ms = tonumber(cfg.throttle_ms or 800) or 800

  -- Per-window throttle and generation (to invalidate delayed runs on mode changes)
  local last_fire_ms_by_win = {}
  local gen_by_win = {}

  local function bump_gen(win)
    gen_by_win[win] = (gen_by_win[win] or 0) + 1
    return gen_by_win[win]
  end

  -- Lower updatetime so CursorHold fires promptly for this feature.
  vim.o.updatetime = 100

  local events = effective_events(cfg.modes, cfg.events_override)

  autocmd.create(events, function()
    if not mode_allowed(cfg.modes) then
      return
    end

    local win = api.nvim_get_current_win()
    local now_ms = math.floor((uv.hrtime() or 0) / 1e6)
    local last_ms = last_fire_ms_by_win[win] or 0
    if (now_ms - last_ms) < throttle_ms then
      return
    end
    last_fire_ms_by_win[win] = now_ms

    local buf = api.nvim_get_current_buf()
    if not normal_buf_allowed(cfg.ignore_buftypes) then
      return
    end
    if cfg.require_clean_buffer and vim.bo[buf].modified then
      return
    end

    local file = api.nvim_buf_get_name(buf)
    if file == "" then
      return
    end
    local dir = fn.fnamemodify(file, ":p:h")

    local git = cfg.git_cmd or "git"

    -- Bumped now, before the async git checks below start — not after them —
    -- so a mode change that happens *during* `in_git_repo_async`/
    -- `is_tracked_async` (both real subprocess round-trips) invalidates this
    -- pass too, the same way it already invalidated a delayed `run()`.
    local my_gen = bump_gen(win)

    ---@internal
    ---Re-validate everything that can go stale while waiting on an async
    ---git call: mode, generation (a later CursorHold or a mode change since),
    ---and buffer/window liveness.
    ---@return boolean
    local function still_valid()
      return mode_allowed(cfg.modes)
        and gen_by_win[win] == my_gen
        and api.nvim_buf_is_valid(buf)
        and api.nvim_win_is_valid(win)
    end

    local function run()
      if not still_valid() then
        return
      end

      clear_line_diff(buf)

      if prefer_inline then
        local ok_gs, gs = pcall(require, "gitsigns")
        if ok_gs and gs.preview_hunk_inline then
          local view = fn.winsaveview()
          local cur = api.nvim_win_get_cursor(win)
          local ok_inline = pcall(gs.preview_hunk_inline)
          if ok_inline then
            if restore_view then
              vim.schedule(function()
                if not api.nvim_win_is_valid(win) then
                  return
                end
                pcall(fn.winrestview, view)
                pcall(api.nvim_win_set_cursor, win, cur)
              end)
            end
            autocmd.create({ "CursorMoved", "BufHidden", "InsertEnter" }, function()
              clear_line_diff(buf)
            end, {
              group = augroup("cleanup"),
              buffer = buf,
              once = true,
              desc = "[fileops] Clear inline diff preview on next move",
            })
            return
          end
        end
      end

      local lnum = get_lnum(win)
      get_previous_line_async(git, file, lnum, dir, function(prev)
        if not prev or prev == "" or not still_valid() then
          return
        end
        -- `lnum` was captured before two subprocess round-trips
        -- (`git blame` -> `git show`); `still_valid()` re-checks buffer/window
        -- liveness but not line count, so a shrink in between (`:e!`, an
        -- external reload, undo of a large paste) would otherwise write this
        -- extmark past the buffer's last line instead of skipping a stale write.
        if lnum > api.nvim_buf_line_count(buf) then
          return
        end

        local virt = truncate(prev, tonumber(cfg.max_len or 160) or 160)
        local pos = (cfg.right_align and "right_align") or "eol"
        local pref = (cfg.prefix ~= nil) and tostring(cfg.prefix) or "previous: "

        pcall(api.nvim_buf_set_extmark, buf, NS, lnum - 1, 0, {
          virt_text = { { pref .. virt, cfg.hl_prev or "Comment" } },
          virt_text_pos = pos,
          priority = tonumber(cfg.virt_priority or 1000) or 1000,
        })

        autocmd.create({ "CursorMoved", "BufHidden", "InsertEnter" }, function()
          clear_line_diff(buf)
        end, {
          group = augroup("cleanup"),
          buffer = buf,
          once = true,
          desc = "[fileops] Clear previous-line preview on next move",
        })
      end)
    end

    ---@internal
    ---Schedule `run()` (honoring `cfg.delay`) now that the async git-state
    ---checks below have both passed.
    ---@return nil
    local function schedule_run()
      local extra = tonumber(cfg.delay or 0) or 0
      if extra > 0 then
        vim.defer_fn(run, extra)
      else
        run()
      end
    end

    in_git_repo_async(git, dir, function(is_repo)
      if not is_repo or not still_valid() then
        return
      end
      if cfg.only_tracked then
        is_tracked_async(git, file, dir, function(tracked)
          if not tracked or not still_valid() then
            return
          end
          schedule_run()
        end)
      else
        schedule_run()
      end
    end)
  end, {
    group = augroup("preview"),
    desc = "[fileops] Show line diff/previous content on CursorHold/CursorHoldI (mode-aware, throttled)",
  })

  autocmd.create("ModeChanged", function()
    local win = api.nvim_get_current_win()
    local buf = api.nvim_get_current_buf()
    if not mode_allowed(cfg.modes) then
      clear_line_diff(buf)
      bump_gen(win)
    end
  end, {
    group = augroup("modeclear"),
    desc = "[fileops] Clear/abort line diff preview when leaving allowed modes",
  })
end

return M
