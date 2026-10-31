-- TESTS/harness.lua — tiny assertion helper shared by the spec files.
-- Handed to each spec by testing.nvim (dialect "h", see .testing.lua).

local H = {}

--- How many assertions have run so far, across every spec.
---
--- Counted rather than read off the source: most specs assert inside loops or
--- helper functions, so the number of `eq`/`ok` call *sites* says very little
--- about how much was actually checked. testing.nvim reports the per-spec result
--- and the total.
---@type integer
H.checks = 0

--- Assert equality; raises a descriptive error on mismatch (caught by the runner).
---@param a any # actual
---@param b any # expected
---@param msg string|nil
function H.eq(a, b, msg)
  H.checks = H.checks + 1
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

--- Assert a truthy value.
---@param v any
---@param msg string|nil
function H.ok(v, msg)
  H.checks = H.checks + 1
  if not v then
    error(("FAIL %s: expected truthy, got %q"):format(msg or "", tostring(v)), 2)
  end
end

--- Create a fresh, empty scratch directory under vim.fn.tempname().
---
--- Handed out with symlinks already resolved, which is what makes this suite
--- comparable to the paths the plugin reports. On macOS `$TMPDIR` is
--- `/var/folders/…` and `/var` is a symlink to `/private/var`: Neovim resolves
--- that when it names a buffer on Unix (`fix_fname`) and `getcwd()` reports
--- the resolved form too, while `fnamemodify(…, ":p")` leaves the raw
--- spelling alone. A spec that joined an expected path onto the
--- raw `tempname()` and compared it against a path the plugin had read off a
--- buffer was therefore comparing the two spellings of one directory and
--- failing on the difference alone.
---
--- Resolving here rather than at each assertion keeps the fixture in the one
--- spelling the platform itself uses, so both sides of such a comparison start
--- out equal and a real disagreement still shows. A no-op on Linux and
--- Windows, where the temp directory is not reached through a symlink.
---@return string dir  Absolute path with a trailing slash.
function H.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local uv = vim.uv or vim.loop
  local real = uv.fs_realpath and uv.fs_realpath(dir)
  if type(real) == "string" and real ~= "" then
    dir = real
  end
  return vim.fn.fnamemodify(dir, ":p")
end

--- Write `content` to `path`, creating parent directories.
---@param path string
---@param content string|nil
function H.write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(content or "")
  fd:close()
end

--- Open `path` as the current buffer of the current window (scratch, no swap noise).
---@param path string
---@return integer bufnr
function H.edit(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

--- Whether this suite is running on native Windows.
---
--- Used by the specs that pin platform-specific path behaviour: a path is
--- joined with `/` in several places here and compared against a buffer name
--- Neovim spells with `\`, which only differ on Windows.
---@return boolean
function H.is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

--- Run `fn` with `vim.notify` captured, and return everything it emitted.
---
--- The seam is `vim.notify` rather than `fileops.util.notify`: every module
--- here binds that module's functions at load time, so replacing the module
--- in `package.loaded` afterwards would capture nothing. lib.nvim's notifier
--- (which `util/notify.lua` upgrades to when lib.nvim is present, as it is in
--- this suite) ends at `vim.notify` too, so both paths land here.
---
--- Deliberately swallowed rather than forwarded: Neovim renders an
--- ERROR-level notification as a real error message, and one raised from
--- inside a `:File …` invocation would abort `vim.cmd` — turning "the command
--- reported a failure", which several cases here assert, into a spec crash.
---@param fn fun()
---@return { msg: string, level: integer|nil }[]
function H.notifications(fn)
  local seen = {}
  local real = vim.notify
  vim.notify = function(msg, level, _opts)
    seen[#seen + 1] = { msg = tostring(msg), level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = real
  if not ok then
    error(err, 0)
  end
  return seen
end

--- Whether any captured notification contains `needle` (plain substring).
---@param seen { msg: string, level: integer|nil }[]
---@param needle string
---@return boolean
function H.notified(seen, needle)
  for _, n in ipairs(seen) do
    if n.msg:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- Put `value` on `package.loaded[name]` and return a restore function.
---
--- The specs stub modules that are not on this suite's runtimepath (`ui.kit`,
--- `ui.contextmenu`, `filetree.refs`) or that would shell out to the OS
--- (`lib.nvim.fs.trash`, `lib.nvim.cross.fs.lock`). Always paired with its
--- restore so the next spec sees the real module again.
---@param name string
---@param value any
---@return fun() restore
function H.stub(name, value)
  local previous = package.loaded[name]
  package.loaded[name] = value
  return function()
    package.loaded[name] = previous
  end
end

--- Modes whose global keymaps `H.preserve` snapshots (the ones the state guard of testing.nvim reads).
local KEYMAP_MODES = { "n", "i", "x", "s", "o", "c", "t", "l" }

---@return table<string, table>
local function global_keymaps()
  local res = {}
  for _, mode in ipairs(KEYMAP_MODES) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      res[mode .. "\0" .. m.lhs] = m
    end
  end
  return res
end

---@param mode string
---@param m table a map as `nvim_get_keymap` returns it
local function put_keymap(mode, m)
  pcall(vim.api.nvim_set_keymap, mode, m.lhs, m.rhs or "", {
    noremap = m.noremap == 1,
    silent = m.silent == 1,
    expr = m.expr == 1,
    nowait = m.nowait == 1,
    desc = m.desc,
    callback = m.callback,
  })
end

---@return table<integer, true>
local function id_set(list)
  local res = {}
  for _, v in ipairs(list) do
    res[v] = true
  end
  return res
end

--- Snapshot the editor state a spec may change and return the function that puts it back.
---
--- The whole suite shares one Neovim (`isolated = "none"`) and testing.nvim's state guard runs on
--- `error`: a spec that leaves a buffer, a window, a tab page, an autocmd, a user command, a global
--- keymap or a changed working directory behind turns the run red. Every spec takes this snapshot
--- first and calls the returned function last, so what it created (buffers of its fixtures, the
--- `:File` command, the keymap preset, the autocmds and `vim.g.loaded_fileops` that `setup()`
--- leaves) is gone again and what it replaced is restored. Windows and tab pages the spec closed itself cannot be brought back: a
--- spec keeps the window and tab page it started in.
---@return fun() restore
function H.preserve()
  local api = vim.api
  local before = {
    cwd = vim.fn.getcwd(),
    -- The one `vim.g` key `setup()` sets: the guard `plugin/fileops.lua` checks.
    loaded = vim.g.loaded_fileops,
    tabs = id_set(api.nvim_list_tabpages()),
    wins = id_set(api.nvim_list_wins()),
    bufs = id_set(api.nvim_list_bufs()),
    usercmds = api.nvim_get_commands({ builtin = false }),
    keymaps = global_keymaps(),
    autocmds = {},
  }
  for _, au in ipairs(api.nvim_get_autocmds({})) do
    if au.id then
      before.autocmds[au.id] = true
    end
  end

  return function()
    for _, t in ipairs(api.nvim_list_tabpages()) do
      if not before.tabs[t] and #api.nvim_list_tabpages() > 1 then
        pcall(vim.cmd, "tabclose! " .. api.nvim_tabpage_get_number(t))
      end
    end
    for _, w in ipairs(api.nvim_list_wins()) do
      if not before.wins[w] and api.nvim_win_is_valid(w) then
        pcall(api.nvim_win_close, w, true)
      end
    end
    for _, b in ipairs(api.nvim_list_bufs()) do
      if not before.bufs[b] and api.nvim_buf_is_valid(b) then
        pcall(api.nvim_buf_delete, b, { force = true })
      end
    end
    vim.g.loaded_fileops = before.loaded
    if vim.fn.getcwd() ~= before.cwd then
      pcall(api.nvim_set_current_dir, before.cwd)
    end
    for _, au in ipairs(api.nvim_get_autocmds({})) do
      -- The editor's own lazily created groups (`nvim.*`) stay: the runtime module that made one
      -- keeps its id, so deleting it would break that module for the rest of the run.
      local runtime = type(au.group_name) == "string" and au.group_name:sub(1, 5) == "nvim."
      if au.id and not before.autocmds[au.id] and not runtime then
        pcall(api.nvim_del_autocmd, au.id)
      end
    end
    for name in pairs(api.nvim_get_commands({ builtin = false })) do
      if before.usercmds[name] == nil then
        pcall(api.nvim_del_user_command, name)
      end
    end
    local after = global_keymaps()
    for key, m in pairs(after) do
      local mode = key:match("^[^%z]+")
      local old = before.keymaps[key]
      if old == nil then
        pcall(api.nvim_del_keymap, mode, m.lhs)
      elseif
        old.rhs ~= m.rhs
        or old.callback ~= m.callback
        or old.desc ~= m.desc
        or old.expr ~= m.expr
      then
        pcall(api.nvim_del_keymap, mode, m.lhs)
        put_keymap(mode, old)
      end
    end
    for key, old in pairs(before.keymaps) do
      if after[key] == nil then
        put_keymap(key:match("^[^%z]+"), old)
      end
    end
  end
end

--- Run a spec body between `H.preserve()` and its restore, also when the body raises.
---
--- Every spec file hands its body to this, so its early exits (a skip when `git` cannot run) and
--- its failures clean up as well; the error is raised again unchanged after the restore.
---@param spec fun(H: table)
function H.run_preserved(spec)
  local restore = H.preserve()
  local ok, err = xpcall(spec, debug.traceback, H)
  restore()
  if not ok then
    error(err, 0)
  end
end

return H
