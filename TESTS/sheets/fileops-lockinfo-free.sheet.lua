-- Live check: `:File lockinfo` on a file nobody holds, as it runs everywhere (task
-- fileops.nvim/testblatt-bindings-checkliste, binding :File lockinfo; section 8 of
-- ALL/manual-test-checklists/fileops.md).
return {
  id = "fileops.lockinfo-free",
  feature = "fileops.lockinfo",
  title = "fileops.nvim: :File lockinfo on a free file",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})
      _G.sandbox()
      _G.put("free.txt", "x")
      _G.open("free.txt")
      -- The holder lookup compiles a shim in a cold PowerShell: too slow for a sheet, a person's check.
      require("lib.nvim.cross.fs.lock").who = function(_, cb)
        cb({}, nil)
      end]],
    },
    { keys = ":File lockinfo<CR>" },
    { wait = [[_G.noted("renameable right now")]], note = "the probe" },
    { expect = [[_G.noted("free.txt")]], note = "about the current file" },
    {
      expect = [[vim.fn.execute("messages"):find("rename probe", 1, true) ~= nil]],
      note = "the report is in :messages too",
    },
    {
      expect = [[_G.exists("free.txt") and _G.get("free.txt") == "x"]],
      note = "the probe leaves the file where it was",
    },
  },
}
