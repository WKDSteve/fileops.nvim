-- TESTS/sheets/_helpers.lua -- what every fileops test sheet needs in its child editor. Not a sheet
-- (`testing.sheet` only reads *.sheet.lua); a sheet's first step runs it with `dofile`, the child's cwd
-- is the project root. The directory is in the spec's @cache-inputs, so a change here re-runs the sheets.
--
-- Everything lands in a throwaway directory. Stubbed are only the two things that leave the machine:
-- the system clipboard and the OS trash.

local uv = vim.uv or vim.loop

vim.opt.shortmess:append("I")
vim.o.swapfile = false

-- The project root, for what a step needs from beside it after it left for the sandbox.
vim.env.FILEOPS_ROOT = vim.fs.normalize(vim.fn.getcwd())

-- An in-memory clipboard: no provider on a runner, and the real one is the developer's.
_G.clipboard = { ["+"] = {}, ["*"] = {} }
vim.g.clipboard = {
  name = "sheet",
  copy = {
    ["+"] = function(lines)
      _G.clipboard["+"] = lines
    end,
    ["*"] = function(lines)
      _G.clipboard["*"] = lines
    end,
  },
  paste = {
    ["+"] = function()
      return _G.clipboard["+"]
    end,
    ["*"] = function()
      return _G.clipboard["*"]
    end,
  },
}

-- The OS trash: records the path and takes the file away, as the real one does from where it was.
_G.trashed = {}
package.loaded["lib.nvim.fs.trash"] = {
  trash_blocking = function(path)
    _G.trashed[#_G.trashed + 1] = vim.fn.fnamemodify(path, ":t")
    return os.remove(path) and true or false, "stub trash could not remove " .. path
  end,
}

-- Every notification, for the steps that look at the wording.
_G.notes = {}
vim.notify = function(msg)
  _G.notes[#_G.notes + 1] = tostring(msg)
end

---Whether a notification so far holds `text` (plain).
---@param text string
---@return boolean
function _G.noted(text)
  for _, n in ipairs(_G.notes) do
    if n:find(text, 1, true) then
      return true
    end
  end
  return false
end

---A fresh, resolved temp directory as the cwd (resolved: a runner's temp path can be an 8.3 alias).
---@return string
function _G.sandbox()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  _G.root = vim.fs.normalize(uv.fs_realpath(dir) or dir)
  vim.api.nvim_set_current_dir(_G.root)
  return _G.root
end

---@param rel string  Path below the sandbox.
---@return string
function _G.p(rel)
  return _G.root .. "/" .. rel
end

---Write a file below the sandbox, parents included.
---@param rel string
---@param text? string
function _G.put(rel, text)
  local path = _G.p(rel)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text or "")
  f:close()
end

---The content of a file below the sandbox, nil when it does not exist.
---@param rel string
---@return string|nil
function _G.get(rel)
  local f = io.open(_G.p(rel), "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

---@param rel string
---@return boolean
function _G.exists(rel)
  return uv.fs_stat(_G.p(rel)) ~= nil
end

---Open a file below the sandbox in the current window.
---@param rel string
function _G.open(rel)
  vim.cmd.edit(vim.fn.fnameescape(_G.p(rel)))
end

---The current buffer's path relative to the sandbox.
---@return string
function _G.here()
  local name = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  return (name:gsub("^" .. vim.pesc(_G.root) .. "/", ""))
end

---The current buffer's text.
---@return string
function _G.text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

---Whether the kit's button dialog is open.
---@return boolean
function _G.dialog()
  return require("lib.nvim.ui.kit.confirm").is_open()
end

---The lines of the open float.
---@return string
function _G.float_text()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(win)
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  end
  return ""
end

---Whether a typed prompt stands open: the current window is a float, in Insert mode.
---@return boolean
function _G.prompting()
  return vim.api.nvim_win_get_config(0).relative ~= "" and vim.fn.mode() == "i"
end

---Number of windows that are not floats.
---@return integer
function _G.wins()
  local n = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      n = n + 1
    end
  end
  return n
end

---Whether a loaded, listed buffer of that sandbox-relative name exists.
---@param rel string
---@return boolean
function _G.listed(rel)
  local nr = vim.fn.bufnr("^" .. vim.fn.escape(_G.p(rel), "\\") .. "$")
  if nr == -1 then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == _G.p(rel) then
        nr = b
      end
    end
  end
  return nr ~= -1 and vim.bo[nr].buflisted
end

---Take a dependency off the runtimepath (for a sheet about an install without it).
---@param tail string  Directory name, e.g. "ui.nvim".
function _G.drop_rtp(tail)
  local kept = {}
  for _, dir in ipairs(vim.split(vim.o.runtimepath, ",", { plain = true })) do
    if vim.fs.basename(vim.fs.normalize(dir)) ~= tail then
      kept[#kept + 1] = dir
    end
  end
  vim.o.runtimepath = table.concat(kept, ",")
end

---A registered explorer that counts its reloads, and a record of `User FileopsChanged`.
function _G.explorer()
  _G.reloads, _G.changed = 0, {}
  package.loaded["sheet.explorer"] = {}
  require("fileops.ops.file").register_explorer({
    name = "sheet",
    module = "sheet.explorer",
    reload = function()
      _G.reloads = _G.reloads + 1
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = "FileopsChanged",
    callback = function(ev)
      _G.changed[#_G.changed + 1] = ev.data
    end,
  })
end

---Start a real process that holds a sandbox file open without sharing it (`_G.holder`, `_G.held`).
---Windows only. It ends by itself after 20 s, so a failed step leaves nothing behind.
---@param rel string
function _G.hold(rel)
  local path = _G.p(rel):gsub("/", "\\")
  local script = ("$f = [IO.File]::Open('%s', 'Open', 'ReadWrite', 'None'); "):format(path)
    .. "[Console]::Out.WriteLine('locked'); [Console]::Out.Flush(); Start-Sleep 20"
  _G.held = false
  _G.holder = vim.system({ "powershell", "-NoProfile", "-NonInteractive", "-Command", script }, {
    text = true,
    stdout = function(_, data)
      if data and data:find("locked", 1, true) then
        _G.held = true
      end
    end,
  })
end
