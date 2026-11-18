---@module 'fileops'
---Entry point for fileops. Call M.setup() once in your Neovim config.
local M = {}

local _setup_done = false

---Configure and activate fileops.
---
---A second call is a no-op by design: bindings (keymaps, user commands,
---autocmds) are registered once, and re-registering them is not supported.
---It says so explicitly instead of discarding the argument in silence.
---@param user_opts FileOps.Config|nil
function M.setup(user_opts)
  if _setup_done then
    require("fileops.util.notify").warn(
      "setup() already called; ignoring this call and its options "
        .. "(re-configuring after the first setup() is not supported)"
    )
    return
  end
  _setup_done = true

  local cfg = require("fileops.config").setup(user_opts)
  require("fileops.bindings").setup(cfg)

  vim.g.loaded_fileops = 1
end

-- ─── Public Lua API ──────────────────────────────────────────────────────────

---Navigate to the next file in the current directory.
---@param opts? FileOps.CycleConfig
---@param count? integer
---@return boolean ok
function M.next(opts, count)
  local cfg = require("fileops.config").get()
  local copts = vim.tbl_deep_extend("force", vim.deepcopy(cfg.cycle or {}), opts or {})
  local cycle = require("fileops.ops.cycle")
  local notify = require("fileops.util.notify")
  local dir, err = cycle.get_root_dir(copts)
  if not dir then
    notify.warn(err or "no root dir")
    return false
  end
  return notify.report(cycle.navigate(dir, "next", copts, count))
end

---Navigate to the previous file in the current directory.
---@param opts? FileOps.CycleConfig
---@param count? integer
---@return boolean ok
function M.prev(opts, count)
  local cfg = require("fileops.config").get()
  local copts = vim.tbl_deep_extend("force", vim.deepcopy(cfg.cycle or {}), opts or {})
  local cycle = require("fileops.ops.cycle")
  local notify = require("fileops.util.notify")
  local dir, err = cycle.get_root_dir(copts)
  if not dir then
    notify.warn(err or "no root dir")
    return false
  end
  return notify.report(cycle.navigate(dir, "prev", copts, count))
end

---Jump straight to the first file in the current directory listing.
---@param opts? FileOps.CycleConfig
---@return boolean ok
function M.first(opts)
  local cfg = require("fileops.config").get()
  local copts = vim.tbl_deep_extend("force", vim.deepcopy(cfg.cycle or {}), opts or {})
  local cycle = require("fileops.ops.cycle")
  local notify = require("fileops.util.notify")
  local dir, err = cycle.get_root_dir(copts)
  if not dir then
    notify.warn(err or "no root dir")
    return false
  end
  return notify.report(cycle.jump_edge(dir, "first", copts))
end

---Jump straight to the last file in the current directory listing.
---@param opts? FileOps.CycleConfig
---@return boolean ok
function M.last(opts)
  local cfg = require("fileops.config").get()
  local copts = vim.tbl_deep_extend("force", vim.deepcopy(cfg.cycle or {}), opts or {})
  local cycle = require("fileops.ops.cycle")
  local notify = require("fileops.util.notify")
  local dir, err = cycle.get_root_dir(copts)
  if not dir then
    notify.warn(err or "no root dir")
    return false
  end
  return notify.report(cycle.jump_edge(dir, "last", copts))
end

---Reopen the current buffer's own path in a different window target
---(split/vsplit/tab/background/…), without changing which file is shown.
---@param opts? FileOps.CycleConfig
---@return boolean ok
function M.open(opts)
  local cfg = require("fileops.config").get()
  local copts = vim.tbl_deep_extend("force", vim.deepcopy(cfg.cycle or {}), opts or {})
  local cycle = require("fileops.ops.cycle")
  local notify = require("fileops.util.notify")
  return notify.report(cycle.open_current(copts))
end

---Save `bufnr` (default: the current buffer). A buffer with a file name is
---written (`:write`); a `[No Name]` buffer asks for a file name, then for the
---folder below the cwd (cwd preselected, a path by hand, or cancel), and
---confirms before overwriting. `on_done(saved)` is called exactly once.
---@param bufnr? integer
---@param on_done? fun(saved: boolean)
---@return nil
function M.save(bufnr, on_done)
  require("fileops.features.save_prompt").save(bufnr, on_done)
end

---Ask for a name and a folder and save `bufnr` there, even when it already
---has a file name (the prompt half of `save`). `on_done` as for `save`.
---@param bufnr? integer
---@param on_done? fun(saved: boolean)
---@return nil
function M.save_as_prompt(bufnr, on_done)
  require("fileops.features.save_prompt").run(bufnr, on_done)
end

---Create a new file (set buffer name + optionally write).
---@param path string
---@param opts? { write?: boolean, bang?: boolean }
---@return boolean ok
function M.new_file(path, opts)
  return require("fileops.util.notify").report(require("fileops.ops.file").edit_new(path, opts))
end

---Create an empty file at `path` if it doesn't already exist. Does not
---require or touch a buffer.
---@param path string
---@return boolean ok
function M.touch(path)
  return require("fileops.util.notify").report(require("fileops.ops.file").touch(path))
end

---Rename the current file on disk.
---@param new_path string
---@param opts? { bang?: boolean }
---@return boolean ok
function M.rename(new_path, opts)
  return require("fileops.util.notify").report(require("fileops.ops.file").rename(new_path, opts))
end

---Move the current file on disk (possibly to a different directory) without
---reloading the buffer from disk.
---@param new_path string
---@param opts? { bang?: boolean }
---@return boolean ok
function M.move(new_path, opts)
  return require("fileops.util.notify").report(require("fileops.ops.file").move(new_path, opts))
end

---Duplicate the current file to a new path.
---@param new_path string
---@param opts? { bang?: boolean, open?: boolean }
---@return boolean ok
function M.duplicate(new_path, opts)
  return require("fileops.util.notify").report(
    require("fileops.ops.file").duplicate(new_path, opts)
  )
end

---Copy the current buffer's file to a new path without opening the copy.
---@param new_path string
---@param opts? { bang?: boolean }
---@return boolean ok
function M.copy(new_path, opts)
  return require("fileops.util.notify").report(require("fileops.ops.file").copy(new_path, opts))
end

---Delete the current file from disk and close the buffer.
---@param opts? { force?: boolean, mode?: "trash"|"permanent", on_before_delete?: (fun(path: string): boolean|nil) }
---@return boolean ok
function M.delete_current(opts)
  return require("fileops.util.notify").report(require("fileops.ops.file").delete_current(opts))
end

---Copy the current buffer's file path to the unnamed + system clipboard
---registers.
---@param mode? "abs"|"rel"|"name"|"dir"  Defaults to "abs".
---@return boolean ok
function M.copy_path(mode)
  return require("fileops.util.notify").report(require("fileops.ops.file").copy_path(mode))
end

---Show size/mtime/permissions for the current buffer's file.
---@return boolean ok
function M.info()
  return require("fileops.util.notify").report(require("fileops.ops.file").info())
end

---Diagnose who holds a file open when a mutation fails with a sharing
---violation (`EBUSY`/`EPERM`/`EACCES`). Asynchronous — the holder lookup
---spawns a helper process — so the result arrives via `cb` instead of a
---return value.
---@param cb? fun(ok: boolean, msg: string)  Defaults to reporting via notify.
---@param path? string  Defaults to the current buffer's file.
function M.diagnose_lock(cb, path)
  require("fileops.ops.file").diagnose_lock(cb or function(ok, msg)
    require("fileops.util.notify").report(ok, msg)
  end, path)
end

---Change the working directory to the current buffer's directory and refresh
---any open file explorer (neo-tree/nvim-tree/netrw).
---@param opts? { scope?: "lcd"|"cd"|"tcd", refresh?: boolean }
---@return boolean ok
function M.cd_here(opts)
  return require("fileops.util.notify").report(require("fileops.ops.file").cd_here(opts))
end

return M
