-- Live check: a REAL Windows sharing violation: another process holds the file without sharing it, and
-- `:File rename` retries, fires `User FileopsRetry`, names the situation and leaves everything in place
-- (task fileops.nvim/testblatt-bindings-checkliste; section 4 of
-- ALL/manual-test-checklists/fileops.md). The holder ends by itself after 20 s if a step fails first.
return {
  id = "fileops.lock-retry",
  title = "fileops.nvim: a real sharing violation is retried and explained (Windows)",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  requires = {
    { lua = [[vim.fn.has("win32") == 1]], reason = "a sharing violation exists on Windows only" },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})
      _G.sandbox()
      _G.put("locked.txt", "x")
      _G.open("locked.txt")
      _G.retries = 0
      vim.api.nvim_create_autocmd("User", {
        pattern = "FileopsRetry",
        callback = function()
          _G.retries = _G.retries + 1
        end,
      })
      _G.hold("locked.txt")]],
      note = "a process holds the open file exclusively",
    },
    { wait = "_G.held", timeout = 6000, note = "the holder has the file" },

    { keys = ":File rename away.txt<CR>" },
    { expect = [[_G.exists("locked.txt") and not _G.exists("away.txt")]], note = "nothing moved" },
    { expect = [[_G.here() == "locked.txt"]], note = "the buffer keeps its name" },
    {
      expect = [[_G.retries == 5]],
      note = "retry.attempts = 6: User FileopsRetry before each retry",
    },
    {
      expect = [[_G.noted("another process is holding the file open")]],
      note = "names the situation",
    },

    -- The probe of :File lockinfo against the same lock. The holder lookup compiles a shim in a cold
    -- PowerShell: too slow for a sheet, a person's check.
    {
      lua = [[require("lib.nvim.cross.fs.lock").who = function(_, cb)
        cb({}, nil)
      end]],
    },
    { keys = ":File lockinfo<CR>" },
    { wait = [[_G.noted("NOT renameable")]], note = "the probe sees the lock" },
    { expect = [[_G.exists("locked.txt")]], note = "and leaves the file where it was" },

    { lua = [[_G.holder:kill(9)]], note = "our own holder, by its handle" },
    { wait = "_G.holder:is_closing()", timeout = 3000 },
    { keys = ":File rename away.txt<CR>", note = "the holder is gone" },
    { expect = [[_G.get("away.txt") == "x" and _G.here() == "away.txt"]], note = "now it goes" },
  },
}
