---@module 'fileops.features.save_prompt'
---Interactive "save as" for a buffer that has no file name yet (`[No Name]`).
---
---`:write` on such a buffer only raises E32. This asks instead, in three
---steps, each of which can be cancelled without an error message:
---
---  1. the file name (`kit.input`);
---  2. where to put it: one of the folders below the cwd (the cwd itself is
---     first and preselected), "Enter path manually…" or "Cancel"
---     (`kit.select`);
---  3. only when the file exists already: overwrite or not (`kit.confirm`).
---
---A name that already carries a folder (`notes/todo.md`, `~/x.md`, an
---absolute path) skips step 2: the user has said where it goes.
---
---The write itself is `ops.file.save_as`, run in the buffer's own context,
---so the buffer may be a background one (a tabline chip that is closed).
local M = {}

local api = vim.api
local uv = vim.uv or vim.loop

---Test seam: replaces `lib.nvim.ui.kit` when set.
---@type table|nil
M._kit = nil

---Test seam: replaces the folder walk (`fun(root, cb)`, `cb(dirs)`) when set.
---@type (fun(root: string, cb: fun(dirs: string[])))|nil
M._list_dirs = nil

---@internal
---@return table
local function kit()
  return M._kit or require("lib.nvim.ui.kit")
end

---How many folder levels below the cwd the selection lists. A cwd that holds
---many projects (a repos root) would otherwise be walked to the bottom before
---the list opens; anything deeper is one "Enter path manually…" away.
local MAX_DEPTH = 3

---@internal
---The walk's `ignore` predicate for `root`: dot folders, the usual
---build/vendor folders, and everything deeper than `MAX_DEPTH`.
---@param root string
---@return fun(abs_path: string, is_dir: boolean): boolean
function M.__ignore(root)
  local skip = require("lib.nvim.fs.collect_recursive").skip({ hidden = false })
  local base = #(root:gsub("[\\/]+$", "")) + 1
  return function(abs_path, is_dir)
    if skip(abs_path, is_dir) then
      return true
    end
    local _, depth = abs_path:sub(base + 1):gsub("[\\/]+", "")
    return depth >= MAX_DEPTH
  end
end

---@internal
---All folders below `root`, without dot folders and the usual build/vendor
---folders (`lib.nvim.fs.ignore.list`), at most `MAX_DEPTH` levels deep. Non-blocking.
---@param root string
---@param cb fun(dirs: string[])
local function list_dirs(root, cb)
  if M._list_dirs then
    return M._list_dirs(root, cb)
  end
  require("lib.nvim.fs.collect_recursive").dirs_async(
    root,
    { ignore = M.__ignore(root) },
    function(paths)
      cb(paths or {})
    end
  )
end

---@internal
---Whether `name` already says where the file goes (a folder part, `~`, or
---an absolute path) -- then there is nothing to pick.
---@param name string
---@return boolean
local function has_location(name)
  return name:find("[/\\]") ~= nil or name:sub(1, 1) == "~"
end

---@internal
---`path` relative to `root` with `/` separators, or nil when it is not below it.
---@param path string
---@param root string
---@return string|nil
local function relative(path, root)
  local p = path:gsub("\\", "/")
  local r = root:gsub("\\", "/"):gsub("/+$", "")
  if p:sub(1, #r + 1):lower() == (r .. "/"):lower() then
    return p:sub(#r + 2)
  end
  return nil
end

---@internal
---Write `bufnr` to `dest` and report it.
---@param bufnr integer
---@param dest string
---@param bang boolean
---@param finish fun(saved: boolean)
local function write(bufnr, dest, bang, finish)
  if not api.nvim_buf_is_valid(bufnr) then
    return finish(false)
  end
  local file = require("fileops.ops.file")
  local ok, msg
  local called, err = pcall(api.nvim_buf_call, bufnr, function()
    ok, msg = file.save_as(dest, { bang = bang, refresh_explorers = true })
  end)
  if not called then
    ok, msg = false, "saveas failed: " .. tostring(err)
  end
  require("fileops.util.notify").report(ok, msg)
  finish(ok == true and not vim.bo[bufnr].modified)
end

---@internal
---Write `bufnr` to `dest`, asking first when `dest` exists already.
---@param bufnr integer
---@param dest string
---@param finish fun(saved: boolean)
local function save_to(bufnr, dest, finish)
  local abs = vim.fn.fnamemodify(require("lib.nvim.cross.fs.expand_path")(dest) or dest, ":p")
  if not uv.fs_stat(abs) then
    return write(bufnr, dest, false, finish)
  end
  kit().confirm({
    question = ("%s exists already. Overwrite it?"):format(vim.fn.fnamemodify(abs, ":~:.")),
    choices = { "Cancel", "Overwrite" },
    default = "Cancel",
    on_answer = function(choice)
      if choice == "Overwrite" then
        write(bufnr, dest, true, finish)
      else
        finish(false)
      end
    end,
  })
end

---@internal
---Ask for a full path, prefilled with `<cwd>/<name>`.
---@param bufnr integer
---@param default string
---@param finish fun(saved: boolean)
local function ask_path(bufnr, default, finish)
  kit().input({
    title = "Save as (path)",
    default = default,
    on_submit = function(path)
      if type(path) ~= "string" or vim.trim(path) == "" then
        return finish(false)
      end
      save_to(bufnr, vim.trim(path), finish)
    end,
    on_cancel = function()
      finish(false)
    end,
  })
end

---@internal
---Step 2: where `name` goes.
---@param bufnr integer
---@param name string
---@param finish fun(saved: boolean)
local function pick_folder(bufnr, name, finish)
  local cwd = vim.fn.getcwd()
  list_dirs(cwd, function(dirs)
    ---@type { kind: "dir"|"manual"|"cancel", path?: string, label: string }[]
    local items = {
      { kind = "dir", path = cwd, label = "./  (cwd: " .. vim.fn.fnamemodify(cwd, ":~") .. ")" },
      { kind = "manual", label = "Enter path manually…" },
      { kind = "cancel", label = "Cancel" },
    }
    local rels = {}
    for _, d in ipairs(dirs) do
      local rel = relative(d, cwd)
      if rel and rel ~= "" then
        rels[#rels + 1] = rel
      end
    end
    table.sort(rels)
    for _, rel in ipairs(rels) do
      items[#items + 1] = { kind = "dir", path = cwd .. "/" .. rel, label = rel .. "/" }
    end

    kit().select({
      items = items,
      title = ('Save "%s" in which folder?'):format(name),
      initial_index = 1,
      format_item = function(item)
        return item.label
      end,
      on_select = function(item)
        if item.kind == "dir" then
          save_to(bufnr, item.path .. "/" .. name, finish)
        elseif item.kind == "manual" then
          -- Opened once the chooser has fully closed: opened from inside its
          -- pick, the prompt stood in Normal mode, where the path typed next
          -- ran as commands (found by TESTS/sheets/fileops-save.sheet.lua).
          vim.schedule(function()
            ask_path(bufnr, cwd .. "/" .. name, finish)
          end)
        else
          finish(false)
        end
      end,
      on_cancel = function()
        finish(false)
      end,
    })
  end)
end

---Ask where to save `bufnr` (default: the current buffer) and save it there.
---
---`on_done(saved)` is called exactly once: `true` when the buffer was
---written and is no longer modified, `false` when the user cancelled at any
---step or the write failed (the failure itself is notified).
---@param bufnr? integer
---@param on_done? fun(saved: boolean)
---@return nil
function M.run(bufnr, on_done)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  local done = false
  local function finish(saved)
    if done then
      return
    end
    done = true
    if on_done then
      on_done(saved)
    end
  end
  if not api.nvim_buf_is_valid(bufnr) then
    return finish(false)
  end

  local current = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
  kit().input({
    title = ("Save %s as (file name)"):format(
      current == "" and "[No Name]" or ('"' .. current .. '"')
    ),
    on_submit = function(name)
      name = type(name) == "string" and vim.trim(name) or ""
      if name == "" then
        return finish(false)
      end
      if has_location(name) then
        save_to(bufnr, name, finish)
      else
        pick_folder(bufnr, name, finish)
      end
    end,
    on_cancel = function()
      finish(false)
    end,
  })
end

---Save `bufnr` (default: the current buffer): `:write` when it has a file
---name, the `run` prompt when it has none. Buffers that are not files
---(`buftype` set, e.g. a terminal or a prompt) are written as `:write` would.
---@param bufnr? integer
---@param on_done? fun(saved: boolean)
---@return nil
function M.save(bufnr, on_done)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  if api.nvim_buf_get_name(bufnr) == "" and vim.bo[bufnr].buftype == "" then
    return M.run(bufnr, on_done)
  end
  local ok, err = pcall(api.nvim_buf_call, bufnr, function()
    vim.cmd("write")
  end)
  if not ok then
    require("fileops.util.notify").error("write failed: " .. tostring(err))
  end
  if on_done then
    on_done(ok and not vim.bo[bufnr].modified)
  end
end

return M
