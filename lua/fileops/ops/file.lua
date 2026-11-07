---@module 'fileops.ops.file'
---File create / rename / duplicate / delete operations.
---All ops validate API handles and use libuv for I/O (no shell injection).
---
---Every public function returns `ok, msg`: `msg` is a human-readable string
---to relay regardless of outcome (success or failure), and the caller (the
---UI/binding layer) decides whether/how to notify it. This module never
---calls notify itself, so it can be reused from contexts that want silence
---or a different presentation.
local M = {}

local fsops = require("lib.nvim.cross.fs.mutate")
local expand_path = require("lib.nvim.cross.fs.expand_path")
local excmd = require("fileops.util.excmd")
local git = require("fileops.util.git")
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop

-- ─── Internal helpers ─────────────────────────────────────────────────────────

---@internal
---Return current buffer number, validated.
---@return integer|nil
local function cur_buf()
  local b = api.nvim_get_current_buf()
  return (b and api.nvim_buf_is_valid(b)) and b or nil
end

---@internal
---Return the file path associated with `bufnr`, or nil.
---@param bufnr integer
---@return string|nil
local function buf_path(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local p = api.nvim_buf_get_name(bufnr)
  return (type(p) == "string" and p ~= "") and p or nil
end

---@internal
---Whether `p` already denotes an absolute location (POSIX root, Windows
---drive letter or UNC share). `~` is not checked here — `expand_path` has
---already turned it into an absolute path by the time this is called.
---@param p string
---@return boolean
local function is_absolute(p)
  return p:match("^/") ~= nil or p:match("^\\") ~= nil or p:match("^%a:[\\/]") ~= nil
end

---@internal
---Expand and validate a user-supplied path.
---
---`base` anchors *relative* input. Ops that act on the current buffer's file
---pass that file's directory, so `:File rename NEW.md` means "same folder,
---new name" — which is both what the command reads like and what the
---bufdir-relative completion in `bindings.usrcmds` offers. Without a base,
---a relative path resolves against Neovim's cwd, which for a buffer opened
---from elsewhere in the tree silently lands the file in a different folder.
---
---The expansion is `lib.nvim.cross.fs.expand_path` — the same one the `path`
---argument type in `bindings.usrcmds` uses — and deliberately *not*
---`fn.expand`. This string is a destination the user typed: `~` and `$VAR`
---in it are references to expand, but `*`, `?`, `[` and `{` are characters in
---a file name. `fn.expand` globs them, so `:File rename note[1].md` resolved
---to whichever existing file the pattern `note[1].md` matched — `note1.md` —
---and renamed to that, or refused with "destination already exists" naming a
---path the user never typed. A glob is also the wrong tool by definition
---here: the destination of a rename does not exist yet, so there is nothing
---for it to match.
---
---Separators are unified afterwards, which `fn.expand` used to do as a side
---effect of globbing. That half of it is worth keeping and is the point of
---this function: the result is a buffer name, a notification, and the key the
---rest of the plugin compares paths on, and this is where the second spelling
---of one path was being minted. A relative destination is joined onto its base
---with `/`, so `:File rename NEW.md` on Windows produced
---`C:\dir\sub/NEW.md` — the same file as `C:\dir\sub\NEW.md` and unequal to it
---as a string. `ops/bulk.lua` and `ops/cycle.lua` both carry a normalizing
---`comparable` for exactly this; unifying at the source is what makes those
---belt-and-braces rather than load-bearing.
---
---Only on Windows: a backslash is an ordinary character in a POSIX file name,
---so rewriting one there would corrupt the path rather than respell it.
---@param raw string
---@param base? string  Directory to resolve relative input against.
---@return string|nil abs  Absolute path, or nil on error.
local function resolve_path(raw, base)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local exp = expand_path(raw)
  if type(exp) ~= "string" or exp == "" then
    return nil
  end
  if base and base ~= "" and not is_absolute(exp) then
    exp = base .. "/" .. exp
  end
  local abs = fn.fnamemodify(exp, ":p")
  if abs == "" then
    return nil
  end
  if fn.has("win32") == 1 then
    -- The separator Neovim itself writes into a buffer name: `\`, unless
    -- 'shellslash' tells it otherwise.
    abs = (abs:gsub("[\\/]", vim.o.shellslash and "/" or "\\"))
  end
  return abs
end

---@internal
---Build the `lib.nvim.cross.fs.mutate` retry options for a mutation on
---`path`. Beyond the attempt budget, the `on_retry` hook does the two things
---that make retrying worthwhile at all — waiting alone cannot outlast a
---handle held inside this very Neovim process:
---
---  1. Releases neo-tree's leaked `fs_event` handles on the path via
---     `lib.nvim.neotree.watch`. Neo-tree only ever `:stop()`s those, never
---     `:close()`s them, so on Windows the directory stays open at the OS
---     level until the GC runs. A no-op when that guard isn't installed.
---  2. Fires `User FileopsRetry`, so any other plugin can drop its own
---     handle. `lib.nvim` waits with `vim.wait`, which keeps the event loop
---     running — libuv closes handles on the next tick, so a handle released
---     here really is gone by the following attempt.
---@param path string  Path the mutation acts on.
---@param retry? FileOps.RetryConfig
---@return table
local function retry_opts(path, retry)
  retry = retry or {}
  return {
    attempts = retry.attempts,
    backoff_ms = retry.backoff_ms,
    on_retry = function(attempt, err)
      pcall(function()
        require("lib.nvim.neotree.watch").release(path)
      end)
      pcall(api.nvim_exec_autocmds, "User", {
        pattern = "FileopsRetry",
        data = { path = path, attempt = attempt, err = err },
      })
    end,
  }
end

---@internal
---libuv reports a Windows sharing violation as `EBUSY`/`EPERM`/`EACCES`.
---Once the retry budget is spent, the bare code is a dead end for the user,
---so name the actual situation: some *other* process holds the file open. An
---open Neovim buffer is never the cause — Neovim closes the file after
---reading it and only keeps its swap file open.
---@param err string|nil
---@return string
local function explain_fs_error(err)
  local msg = tostring(err)
  local code = msg:match("^(%u+):")
  if code == "EBUSY" or code == "EPERM" or code == "EACCES" then
    return msg
      .. " — another process is holding the file open"
      .. " (virus scanner, search indexer, OneDrive, a file watcher);"
      .. " the open buffer itself is not the cause"
  end
  return msg
end

-- ─── Explorer refresh / change events ──────────────────────────────────────────

---@class FileOps.ExplorerAdapter
---@field name string        Label for `M.explorers()`
---@field module string      `package.loaded` key; the adapter is skipped until that module is loaded
---@field reload fun()       Reload the explorer in place (no root change)

---Register a file-explorer adapter on `lib.nvim.explorer` (replaces one of the same `name`).
---Kept as the stable entry point; fileops adapters only need to reload, so a
---missing `filetypes`/`detect` is filled with a detector that never claims a buffer.
---@param adapter FileOps.ExplorerAdapter
function M.register_explorer(adapter)
  vim.validate("name", adapter.name, "string")
  vim.validate("module", adapter.module, "string")
  vim.validate("reload", adapter.reload, "function")
  local entry = vim.tbl_extend("keep", {}, adapter)
  if entry.filetypes == nil and entry.detect == nil then
    entry.detect = function()
      return false
    end
  end
  require("lib.nvim.explorer").register(entry)
end

---Names of the registered explorer adapters, in reload order.
---@return string[]
function M.explorers()
  local out = {}
  for i, a in ipairs(require("lib.nvim.explorer").adapters()) do
    out[i] = a.name
  end
  return out
end

---@internal
---Reload known file-explorer plugins in place (no root change) so they pick
---up a file that was just created/renamed/moved/copied/deleted elsewhere in
---the tree. `lib.nvim.explorer.reload_all` guards every call; plugins that
---are not loaded are silently skipped.
local function reload_explorers()
  require("lib.nvim.explorer").reload_all()
end

---Notify listeners that a file op changed the tree: always emits a
---`User FileopsChanged` autocmd (so any plugin/user config can react), and
---additionally reloads neo-tree/nvim-tree in place unless
---`opts.refresh_explorers == false`. Exported (not just local) so other ops
---modules (e.g. `ops.bulk`) can reuse it for the same behavior.
---@param action string  e.g. "touch", "rename", "move", "duplicate", "copy", "delete", "new", "mkdir".
---@param path string    Absolute path the op acted on (its resulting location for renames/moves).
---@param opts? { refresh_explorers?: boolean }
function M.notify_change(action, path, opts)
  opts = opts or {}
  pcall(api.nvim_exec_autocmds, "User", {
    pattern = "FileopsChanged",
    data = { action = action, path = path },
  })
  if opts.refresh_explorers ~= false then
    reload_explorers()
  end
end

-- ─── Create / open operations ─────────────────────────────────────────────────

---Ensure the parent directory of `path` exists (create recursively if needed).
---@param path string  Absolute path.
---@return boolean ok
---@return string|nil err
function M.ensure_parent(path)
  local dir = fn.fnamemodify(path, ":p:h")
  if dir == "" then
    return false, "cannot resolve parent directory"
  end
  if fn.isdirectory(dir) == 1 then
    return true, nil
  end
  if not fsops.mkdir_p(dir) then
    return false, "cannot create directory: " .. dir
  end
  return true, nil
end

---Set the current buffer's file name (creates parent dirs if needed).
---Does NOT write the buffer to disk.
---@param path string  Destination path (may be relative or use ~).
---@param opts? { write?: boolean, bang?: boolean, refresh_explorers?: boolean }
---@return boolean ok
---@return string|nil msg
function M.edit_new(path, opts)
  opts = opts or {}
  local abs = resolve_path(path)
  if not abs then
    return false, "invalid path: " .. tostring(path)
  end
  local pok, perr = M.ensure_parent(abs)
  if not pok then
    return false, perr
  end

  -- `nvim_buf_set_name` is `:file` without the command line: the name is used
  -- exactly as resolved, instead of being expanded a second time. See
  -- `util/excmd.lua` for why that second expansion is never wanted here.
  local ok, err = pcall(api.nvim_buf_set_name, 0, abs)
  if not ok then
    return false, "file command failed: " .. tostring(err)
  end

  if opts.write then
    local write_cmd = opts.bang and "write!" or "write"
    local wok, werr = pcall(function()
      vim.cmd(write_cmd)
    end)
    if not wok then
      return false, "write failed: " .. tostring(werr)
    end
  end

  M.notify_change("new", abs, opts)
  return true, "created " .. abs
end

---Save a copy of the current buffer under a new path (like `:saveas`).
---Creates parent directories automatically.
---@param path string
---@param opts? { bang?: boolean, refresh_explorers?: boolean }
---@return boolean ok
---@return string|nil msg
function M.save_as(path, opts)
  opts = opts or {}
  local abs = resolve_path(path)
  if not abs then
    return false, "invalid path: " .. tostring(path)
  end
  local pok, perr = M.ensure_parent(abs)
  if not pok then
    return false, perr
  end

  local ok, err = pcall(excmd.with_path, "saveas", abs, { bang = opts.bang })
  if not ok then
    return false, "saveas failed: " .. tostring(err)
  end

  M.notify_change("saveas", abs, opts)
  return true, "saved as " .. abs
end

---Write a copy of the current buffer to `path` without changing buffer name.
---Creates parent directories automatically.
---@param path string
---@param opts? { bang?: boolean, refresh_explorers?: boolean }
---@return boolean ok
---@return string|nil msg
function M.write_to(path, opts)
  opts = opts or {}
  local abs = resolve_path(path)
  if not abs then
    return false, "invalid path: " .. tostring(path)
  end
  local pok, perr = M.ensure_parent(abs)
  if not pok then
    return false, perr
  end

  local ok, err = pcall(excmd.with_path, "write", abs, { bang = opts.bang })
  if not ok then
    return false, "write to failed: " .. tostring(err)
  end

  M.notify_change("writeto", abs, opts)
  return true, "written to " .. abs
end

---Ensure the parent directory of the current buffer's file exists.
---@param opts? { refresh_explorers?: boolean }
---@return boolean ok
---@return string|nil msg
function M.mk_parent(opts)
  local b = cur_buf()
  if not b then
    return false, "no valid buffer"
  end
  local p = buf_path(b)
  if not p then
    return false, "current buffer has no file name"
  end
  local ok, msg = M.ensure_parent(p)
  if ok then
    M.notify_change("mkdir", p, opts)
  end
  return ok, msg
end

-- ─── Touch ────────────────────────────────────────────────────────────────────

---Create an empty file at `path` if it doesn't already exist (creates parent
---directories). Real `touch` semantics: an existing file is left untouched,
---never truncated. Does not require or open a buffer.
---@param path string  Destination path (may be relative or use ~).
---@param opts? { refresh_explorers?: boolean }
---@return boolean ok
---@return string|nil msg
function M.touch(path, opts)
  local abs = resolve_path(path)
  if not abs then
    return false, "invalid path: " .. tostring(path)
  end

  if fn.filereadable(abs) == 1 then
    return true, "already exists: " .. abs
  end

  local pok, perr = M.ensure_parent(abs)
  if not pok then
    return false, perr
  end

  local fd, err = uv.fs_open(abs, "wx", 420) -- O_CREAT|O_EXCL, mode 0644
  if not fd then
    -- Lost a create race to something else between the filereadable check
    -- and here; the file existing is the outcome we wanted either way.
    if type(err) == "string" and err:match("^EEXIST") then
      return true, "already exists: " .. abs
    end
    return false, "touch failed: " .. tostring(err)
  end
  uv.fs_close(fd)

  M.notify_change("touch", abs, opts)
  return true, "touched " .. abs
end

-- ─── Rename / Move ────────────────────────────────────────────────────────────

---@internal
---Shared implementation for `M.rename` and `M.move`: rename the file of the
---current buffer on disk via `fsops.rename_file` (works across directories
---too, so this also covers "move") and re-point the buffer at the new path.
---The only behavioral difference between the two public entry points is
---whether the buffer is reloaded from disk afterwards (`opts.reload`):
---`rename` resets signs/diagnostics via a fresh `:edit`, `move` leaves the
---buffer's content/undo history untouched.
---@param new_path string  New path (may be relative or use ~).
---@param opts? { bang?: boolean, reload?: boolean, action?: string, git_aware?: boolean, git_warn_only?: boolean, git_cmd?: string, session_compat?: boolean, retry?: FileOps.RetryConfig }
---@return boolean ok
---@return string|nil msg
local function move_or_rename(new_path, opts)
  opts = opts or {}
  local reload = opts.reload ~= false
  local action = opts.action or "rename"

  local b = cur_buf()
  if not b then
    return false, "no valid buffer"
  end

  local old = buf_path(b)
  if not old then
    return false, "current buffer has no file name"
  end

  if fn.filereadable(old) ~= 1 then
    return false, "source file does not exist or is not readable: " .. old
  end

  local abs = resolve_path(new_path, fn.fnamemodify(old, ":p:h"))
  if not abs then
    return false, "invalid destination: " .. tostring(new_path)
  end

  if fn.filereadable(abs) == 1 and not opts.bang then
    return false, "destination already exists (use ! to overwrite): " .. abs
  end

  local pok, perr = M.ensure_parent(abs)
  if not pok then
    return false, perr
  end

  -- Write unsaved changes before renaming so no data is lost
  if vim.bo[b].modified then
    local ok, err = pcall(function()
      vim.cmd("write")
    end)
    if not ok then
      return false, "save failed before " .. action .. ": " .. tostring(err)
    end
  end

  local tracked = opts.git_aware and git.is_tracked(old, opts.git_cmd)
  local used_git = false

  if tracked and not opts.git_warn_only then
    local gok, gerr = git.mv(old, abs, opts.git_cmd)
    if not gok then
      return false, action .. " failed (git mv): " .. tostring(gerr)
    end
    used_git = true
  end

  if not used_git then
    local ok, err = fsops.rename_file(old, abs, retry_opts(old, opts.retry))
    if not ok then
      return false, action .. " failed: " .. explain_fs_error(err)
    end
  end

  -- Update buffer to point at new path. `nvim_buf_set_name` rather than
  -- `:file`, so the name is the one just resolved and not whatever a second
  -- round of wildcard expansion made of it (see `util/excmd.lua`).
  pcall(api.nvim_buf_set_name, b, abs)
  if reload then
    -- reload from disk so signs/diagnostics reset
    pcall(function()
      vim.cmd("edit")
    end)
  end

  M.notify_change(action, abs, opts)

  -- Keep an active `:mksession` session pointed at the new path instead of a
  -- now-stale one. `v:this_session` is set by Vim/Neovim itself whenever a
  -- session was loaded or saved; resaving it is a no-op when none is active.
  -- The session file must be passed explicitly: bare `:mksession!` ignores
  -- `v:this_session` and writes `./Session.vim` in the cwd instead.
  -- Third-party session managers (possession.nvim, sessions.nvim, ...) can
  -- react to the `User FileopsChanged` autocmd fired just above instead.
  if opts.session_compat and vim.v.this_session ~= "" then
    pcall(excmd.with_path, "mksession", vim.v.this_session, { bang = true })
  end

  local suffix = tracked and (used_git and " (git mv)" or " (git-tracked)") or ""
  return true,
    (action .. "d %s → %s%s"):format(fn.fnamemodify(old, ":t"), fn.fnamemodify(abs, ":t"), suffix)
end

---Rename the file of the current buffer on disk and update the buffer name.
---Reloads the buffer from disk afterwards (resets signs/diagnostics).
---@param new_path string  New path (may be relative or use ~).
---@param opts? { bang?: boolean, refresh_explorers?: boolean, git_aware?: boolean, git_warn_only?: boolean, git_cmd?: string, session_compat?: boolean, retry?: FileOps.RetryConfig }
---@return boolean ok
---@return string|nil msg
function M.rename(new_path, opts)
  opts = opts or {}
  return move_or_rename(new_path, {
    bang = opts.bang,
    reload = true,
    action = "rename",
    refresh_explorers = opts.refresh_explorers,
    git_aware = opts.git_aware,
    git_warn_only = opts.git_warn_only,
    git_cmd = opts.git_cmd,
    session_compat = opts.session_compat,
    retry = opts.retry,
  })
end

---Move the file of the current buffer on disk to a (possibly different)
---directory and update the buffer name. Unlike `M.rename`, the buffer is
---NOT reloaded from disk afterwards — its content and undo history stay
---exactly as they were, only the on-disk location and buffer name change.
---@param new_path string  New path (may be relative or use ~).
---@param opts? { bang?: boolean, refresh_explorers?: boolean, git_aware?: boolean, git_warn_only?: boolean, git_cmd?: string, session_compat?: boolean, retry?: FileOps.RetryConfig }
---@return boolean ok
---@return string|nil msg
function M.move(new_path, opts)
  opts = opts or {}
  return move_or_rename(new_path, {
    bang = opts.bang,
    reload = false,
    action = "move",
    refresh_explorers = opts.refresh_explorers,
    git_aware = opts.git_aware,
    git_warn_only = opts.git_warn_only,
    git_cmd = opts.git_cmd,
    session_compat = opts.session_compat,
    retry = opts.retry,
  })
end

-- ─── Duplicate ────────────────────────────────────────────────────────────────

---Copy the current buffer's file to `new_path` and open the duplicate. No
---git command is run for tracked sources (there's no `git`-native "copy" —
---the new file just isn't tracked yet); `opts.git_aware` only adds a note
---to the returned message so the caller can warn if it wants to.
---@param new_path string
---@param opts? { bang?: boolean, open?: boolean, verb?: string, refresh_explorers?: boolean, git_aware?: boolean, git_cmd?: string, retry?: FileOps.RetryConfig }
---@return boolean ok
---@return string|nil msg
function M.duplicate(new_path, opts)
  opts = opts or {}
  local open = opts.open ~= false -- open by default
  local verb = opts.verb or "duplicated"

  local b = cur_buf()
  if not b then
    return false, "no valid buffer"
  end

  local src = buf_path(b)
  if not src then
    return false, "current buffer has no file name"
  end

  if fn.filereadable(src) ~= 1 then
    return false, "source file does not exist: " .. src
  end

  local abs = resolve_path(new_path, fn.fnamemodify(src, ":p:h"))
  if not abs then
    return false, "invalid destination: " .. tostring(new_path)
  end

  if fn.filereadable(abs) == 1 and not opts.bang then
    return false, "destination already exists (use ! to overwrite): " .. abs
  end

  local pok, perr = M.ensure_parent(abs)
  if not pok then
    return false, perr
  end

  -- Flush unsaved content first
  if vim.bo[b].modified then
    local ok, err = pcall(function()
      vim.cmd("write")
    end)
    if not ok then
      return false, "save failed before duplicate: " .. tostring(err)
    end
  end

  local ok, err = fsops.copy_file(src, abs, retry_opts(src, opts.retry))
  if not ok then
    return false, "copy failed: " .. explain_fs_error(err)
  end

  if open then
    pcall(excmd.with_path, "edit", abs)
  end

  M.notify_change(verb == "copied" and "copy" or "duplicate", abs, opts)
  local tracked = opts.git_aware and git.is_tracked(src, opts.git_cmd)
  local suffix = tracked and " (source is git-tracked)" or ""
  return true,
    ("%s %s → %s%s"):format(verb, fn.fnamemodify(src, ":t"), fn.fnamemodify(abs, ":t"), suffix)
end

-- ─── Copy ─────────────────────────────────────────────────────────────────────

---Copy the current buffer's file to `new_path` without opening the copy.
---Silent counterpart to `M.duplicate` — same validation and libuv copy, just
---`opts.open` forced off.
---@param new_path string
---@param opts? { bang?: boolean, refresh_explorers?: boolean, git_aware?: boolean, git_cmd?: string, retry?: FileOps.RetryConfig }
---@return boolean ok
---@return string|nil msg
function M.copy(new_path, opts)
  opts = opts or {}
  return M.duplicate(new_path, {
    bang = opts.bang,
    open = false,
    verb = "copied",
    refresh_explorers = opts.refresh_explorers,
    git_aware = opts.git_aware,
    git_cmd = opts.git_cmd,
    retry = opts.retry,
  })
end

-- ─── Delete ───────────────────────────────────────────────────────────────────

---@internal
---Move every window currently displaying `bufnr` onto an alternate listed
---buffer, so that deleting `bufnr` does not spawn a throwaway empty buffer when
---other buffers still exist. Prefers the alternate file (`#`) for a natural
---"return to where I was" feel. Candidates must have a real file name, so
---Neovim's original empty no-name scratch buffer is never picked as the alt.
---@param bufnr integer
---@return boolean switched  True if an alternate was found and applied.
local function switch_windows_off(bufnr)
  local alt = nil

  local altfile = fn.bufnr("#")
  if
    altfile ~= -1
    and altfile ~= bufnr
    and api.nvim_buf_is_valid(altfile)
    and vim.bo[altfile].buflisted
    and buf_path(altfile)
  then
    alt = altfile
  end

  if not alt then
    for _, b in ipairs(api.nvim_list_bufs()) do
      if
        b ~= bufnr
        and api.nvim_buf_is_valid(b)
        and vim.bo[b].buflisted
        and vim.bo[b].buftype == ""
        and buf_path(b)
      then
        alt = b
        break
      end
    end
  end

  if not alt then
    return false
  end

  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
      pcall(api.nvim_win_set_buf, win, alt)
    end
  end
  return true
end

---@internal
---Actually remove `path` from disk per the trash/permanent + git-awareness
---policy — the part of a delete that is the same whether the path came from
---the current buffer (`delete_current`) or was resolved some other way
---(`delete_path`, e.g. an asset a linking file pointed at). `path` is
---assumed to already exist; callers check that first (their "does not
---exist" wording differs slightly, and `delete_current`'s check happens
---before the unsaved-changes/on_before_delete guards, which apply only
---there).
---@param path string
---@param opts { mode?: "trash"|"permanent", git_aware?: boolean, git_warn_only?: boolean, git_cmd?: string, retry?: FileOps.RetryConfig }
---@return boolean ok, string msg
local function delete_path_from_disk(path, opts)
  -- Anything other than the literal "permanent" degrades to the documented
  -- default ("trash"): unset (a caller of the public Lua API that never
  -- merged in `config.get().delete`) and an invalid/mistyped value must both
  -- land on the safer behavior, not on permanent, unrecoverable deletion.
  local trash = opts.mode ~= "permanent"
  local tracked = opts.git_aware and git.is_tracked(path, opts.git_cmd)
  local used_git = false
  local ok, err

  local ropts = retry_opts(path, opts.retry)

  if trash then
    ok, err = require("lib.nvim.fs.trash").trash_blocking(path)
  elseif tracked and not opts.git_warn_only then
    ok, err = git.rm(path, opts.git_cmd)
    used_git = ok
    if not ok then
      -- Fall back to a plain delete rather than leaving the file untouched.
      ok, err = fsops.delete_file(path, ropts)
    end
  else
    ok, err = fsops.delete_file(path, ropts)
  end
  if not ok then
    return false, (trash and "trash failed: " or "delete failed: ") .. explain_fs_error(err)
  end

  local suffix = tracked and (used_git and " (git rm)" or " (git-tracked)") or ""
  return true, (trash and "trashed " or "deleted ") .. fn.fnamemodify(path, ":t") .. suffix
end

---Absolute path of the current buffer's file, or nil if it has none / the
---buffer is invalid. Exported for a caller that needs to know what
---`delete_current`/other buffer-bound ops would act on before calling them —
---e.g. a soft integration deciding whether to scan the file first.
---@return string|nil
function M.current_path()
  local b = cur_buf()
  return b and buf_path(b)
end

---Delete the file of the current buffer from disk and close the buffer.
---Git-aware deletion (`opts.git_aware` + not `opts.git_warn_only`) only
---applies when `opts.mode` is `"permanent"` — an unset or unrecognized mode
---defaults to `"trash"` (see `delete_path_from_disk`), and trashing a file is
---a different operation than `git rm`, so trash mode always uses the trash
---path and just notes tracked-ness in the message.
---@param opts? { force?: boolean, mode?: "trash"|"permanent", on_before_delete?: (fun(path: string): boolean|nil), refresh_explorers?: boolean, git_aware?: boolean, git_warn_only?: boolean, git_cmd?: string, retry?: FileOps.RetryConfig }
---@return boolean ok
---@return string|nil msg
function M.delete_current(opts)
  opts = opts or {}
  local b = cur_buf()
  if not b then
    return false, "no valid buffer"
  end

  local path = buf_path(b)
  if not path then
    return false, "current buffer has no file name"
  end

  if fn.filereadable(path) ~= 1 then
    return false, "file does not exist or is not readable: " .. path
  end

  -- Guard unsaved changes BEFORE touching the disk: abort unless forced, so a
  -- follow-up `:File! delete` still has a file to delete and can force-close.
  if vim.bo[b].modified and not opts.force then
    return false, "buffer has unsaved changes — use :File! delete to delete and force-close"
  end

  -- Give the hook a chance to veto (e.g. warn on git-tracked files) before
  -- anything touches the disk.
  if opts.on_before_delete and opts.on_before_delete(path) == false then
    return false, "deletion cancelled by on_before_delete hook: " .. path
  end

  local ok, msg = delete_path_from_disk(path, opts)
  if not ok then
    return false, msg
  end

  -- Close the buffer (force already implied by the guard above for modified ones).
  if api.nvim_buf_is_valid(b) then
    -- Steer any window off this buffer first, so closing it reuses an existing
    -- buffer instead of spawning an empty one when other buffers exist.
    switch_windows_off(b)
    pcall(api.nvim_buf_delete, b, { force = opts.force or false })
  end

  M.notify_change("delete", path, opts)
  return true, msg
end

---Delete an arbitrary path from disk with the same trash/permanent + git-
---awareness policy `delete_current` applies to the current buffer's file —
---for a caller that resolved the path some other way and has no buffer of
---its own to close (e.g. an asset a just-deleted file linked to; see
---`fileops.integrations.filetree_assets`). Fires the same `User
---FileopsChanged` autocmd via `notify_change`, so an explorer refresh still
---happens. Does not run `on_before_delete` — the caller already decided to
---delete this specific path, there is nothing left to veto.
---@param path string
---@param opts? { mode?: "trash"|"permanent", git_aware?: boolean, git_warn_only?: boolean, git_cmd?: string, retry?: FileOps.RetryConfig }
---@return boolean ok
---@return string|nil msg
function M.delete_path(path, opts)
  opts = opts or {}
  if fn.filereadable(path) ~= 1 and fn.isdirectory(path) ~= 1 then
    return false, "path does not exist: " .. path
  end

  -- A directory passes the existence check above but the permanent path ends
  -- in `uv.fs_unlink`, which cannot remove one: libuv answers `EPERM` on
  -- Windows, the retry loop reads that as a transient sharing violation and
  -- spends its whole budget on it, and the message then blames a virus
  -- scanner. Say what is actually wrong instead. Trashing a directory is a
  -- different matter -- the OS trash backend handles it -- so only the
  -- permanent path is refused here.
  -- Kept in sync with `delete_path_from_disk`'s own trash/permanent decision:
  -- only an explicit "permanent" takes the fs_unlink path this guards against.
  if opts.mode == "permanent" and fn.isdirectory(path) == 1 then
    return false, "delete failed: " .. path .. " is a directory"
  end

  local ok, msg = delete_path_from_disk(path, opts)
  if ok then
    M.notify_change("delete", path, opts)
  end
  return ok, msg
end

-- ─── Lock diagnosis ───────────────────────────────────────────────────────────

---Diagnose why a mutation on the current buffer's file fails with a sharing
---violation: is it locked *right now*, and which process holds it?
---
---Asynchronous, because the holder lookup spawns a helper process — hence a
---callback instead of this module's usual `(ok, msg)` return. The heavy
---lifting lives in `lib.nvim.cross.fs.lock`, so filetree.nvim and any other
---consumer report the same findings in the same words.
---@param cb fun(ok: boolean, msg: string)
---@param path? string  Defaults to the current buffer's file.
function M.diagnose_lock(cb, path)
  if not path or path == "" then
    local b = cur_buf()
    if not b then
      return cb(false, "no valid buffer")
    end
    path = buf_path(b)
    if not path then
      return cb(false, "current buffer has no file name")
    end
  end

  local ok_lock, lock = pcall(require, "lib.nvim.cross.fs.lock")
  if not ok_lock then
    return cb(false, "lib.nvim.cross.fs.lock unavailable — update lib.nvim")
  end

  lock.report(path, function(lines)
    -- lib.nvim names the holder; what a holder called `nvim` means is fileops's
    -- own knowledge (docs/WORKFLOW.md), so the hint is added here.
    for _, line in ipairs(lines) do
      if line:lower():match("^%s*pid%s+%d+%s+nvim%f[^%w_-]") then
        lines[#lines + 1] = ""
        lines[#lines + 1] =
          "holder nvim: not an open buffer (Neovim keeps only the swap file open)."
        lines[#lines + 1] = "It is a leaked watcher, such as neo-tree's: no retry outwaits it,"
        lines[#lines + 1] = "close the watcher or restart that Neovim."
        break
      end
    end
    cb(true, table.concat(lines, "\n"))
  end)
end

-- ─── Info ─────────────────────────────────────────────────────────────────────

---@internal
---Human-readable byte size (binary units, e.g. "12.3 KiB").
---@param bytes integer
---@return string
local function human_size(bytes)
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local size = bytes
  local i = 1
  while size >= 1024 and i < #units do
    size = size / 1024
    i = i + 1
  end
  if i == 1 then
    return ("%d %s"):format(size, units[i])
  end
  return ("%.1f %s"):format(size, units[i])
end

---Return file size/mtime/permissions for the current buffer's file, via
---libuv `fs_stat` (cross-platform: works on Windows too, though the
---permission bits there are libuv's synthesized approximation).
---@return boolean ok
---@return string|nil msg
function M.info()
  local b = cur_buf()
  if not b then
    return false, "no valid buffer"
  end

  local p = buf_path(b)
  if not p then
    return false, "current buffer has no file name"
  end

  local st = uv.fs_stat(p)
  if not st then
    return false, "cannot stat file: " .. p
  end

  local mtime = st.mtime and st.mtime.sec
  local mtime_str = mtime and os.date("%Y-%m-%d %H:%M:%S", mtime) or "unknown"
  local perms = st.mode and ("%o"):format(st.mode % 512) or "unknown"

  local lines = {
    p,
    ("size: %s (%d bytes)"):format(human_size(st.size), st.size),
    ("modified: %s"):format(mtime_str),
    ("permissions: %s"):format(perms),
  }

  return true, table.concat(lines, "\n")
end

-- ─── Path ─────────────────────────────────────────────────────────────────────

---Copy the current buffer's file path to the unnamed + system clipboard
---registers, in the requested `mode`.
---@param mode "abs"|"rel"|"name"|"dir"|nil  Defaults to "abs".
---@return boolean ok
---@return string|nil msg
function M.copy_path(mode)
  local b = cur_buf()
  if not b then
    return false, "no valid buffer"
  end

  local p = buf_path(b)
  if not p then
    return false, "current buffer has no file name"
  end

  local out
  if mode == "rel" then
    out = fn.fnamemodify(p, ":.")
  elseif mode == "name" then
    out = fn.fnamemodify(p, ":t")
  elseif mode == "dir" then
    out = fn.fnamemodify(p, ":p:h")
  elseif mode == nil or mode == "abs" then
    out = fn.fnamemodify(p, ":p")
  else
    return false, "unknown path mode: " .. tostring(mode)
  end

  fn.setreg('"', out)
  fn.setreg("+", out)

  return true, "copied path (" .. (mode or "abs") .. "): " .. out
end

-- ─── Change directory ──────────────────────────────────────────────────────────

---@internal
---Refresh known file-explorer plugins so they reflect `dir` as the new root.
---All calls are guarded; plugins that are not loaded are silently skipped.
---@param dir string  Absolute directory.
local function refresh_explorers(dir)
  -- nvim-tree: change root then reload to repaint.
  if package.loaded["nvim-tree"] then
    pcall(function()
      local nt = require("nvim-tree.api")
      nt.tree.change_root(dir)
      nt.tree.reload()
    end)
  end

  -- neo-tree: refresh the filesystem source (picks up the new cwd).
  if package.loaded["neo-tree"] then
    pcall(function()
      require("neo-tree.sources.manager").refresh("filesystem")
    end)
  end

  -- netrw: reload any visible netrw listing in place.
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) then
      local buf = api.nvim_win_get_buf(win)
      if api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "netrw" then
        pcall(api.nvim_win_call, win, function()
          pcall(excmd.with_path, "edit", dir)
        end)
      end
    end
  end
end

---Change the working directory to the directory of the current buffer's file,
---then refresh any open file explorer so it tracks the new root.
---@param opts? { scope?: "lcd"|"cd"|"tcd", refresh?: boolean }
---@return boolean ok
---@return string|nil msg
function M.cd_here(opts)
  opts = opts or {}
  local b = cur_buf()
  if not b then
    return false, "no valid buffer"
  end

  local p = buf_path(b)
  if not p then
    return false, "current buffer has no file name"
  end

  local dir = fn.fnamemodify(p, ":p:h")
  if dir == "" or fn.isdirectory(dir) ~= 1 then
    return false, "cannot resolve buffer directory"
  end

  local scope = opts.scope
  local cmd = (scope == "cd" or scope == "tcd") and scope or "lcd"
  local ok, err = pcall(excmd.with_path, cmd, dir)
  if not ok then
    return false, "cd failed: " .. tostring(err)
  end

  if opts.refresh ~= false then
    refresh_explorers(dir)
  end

  return true, "cwd → " .. dir
end

return M
