-- Live check: `delete.mode = "permanent"` skips the trash (task
-- fileops.nvim/testblatt-bindings-checkliste; section 3 of ALL/manual-test-checklists/fileops.md).
return {
  id = "fileops.delete-permanent",
  title = 'fileops.nvim: delete.mode = "permanent" goes around the trash',
  task = "fileops.nvim/testblatt-bindings-checkliste",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({ delete = { mode = "permanent" } })
      _G.sandbox()
      _G.put("gone.txt", "x")
      _G.open("gone.txt")]],
    },
    { keys = ":File delete<CR>" },
    { expect = [[not _G.exists("gone.txt")]], note = "the file is gone" },
    { expect = "#_G.trashed == 0", note = "the trash was not asked" },
    { expect = [[_G.noted("deleted gone.txt")]], note = 'the message says "deleted"' },
  },
}
