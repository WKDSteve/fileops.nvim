-- Live check: `:File path`, `cd`, `info`, `help` (task fileops.nvim/testblatt-bindings-checkliste,
-- bindings :File path, cd, info, help; section 9 of ALL/manual-test-checklists/fileops.md). The system
-- clipboard is stubbed (TESTS/sheets/_helpers.lua).
return {
  id = "fileops.info",
  title = "fileops.nvim: :File path, cd, info, help",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})
      _G.sandbox()
      _G.put("d/e/note.txt", "1234")
      _G.open("d/e/note.txt")
      function _G.both(want)
        return vim.fs.normalize(vim.fn.getreg('"')) == want
          and vim.fs.normalize(_G.clipboard["+"][1] or "") == want
      end]],
      note = "a 4 byte file two levels down",
    },

    { keys = ":File path<CR>" },
    { expect = [[_G.both(_G.p("d/e/note.txt"))]], note = "abs: unnamed register and clipboard" },
    { keys = ":File path rel<CR>" },
    { expect = [[_G.both("d/e/note.txt")]], note = "rel" },
    { keys = ":File path name<CR>" },
    { expect = [[_G.both("note.txt")]], note = "name" },
    { keys = ":File path dir<CR>" },
    { expect = [[_G.both(_G.p("d/e"))]], note = "dir" },

    { keys = ":File info<CR>" },
    { expect = [[_G.noted("size: 4 B (4 bytes)")]], note = "size, human and raw" },
    {
      expect = [[_G.noted("modified: 2") and _G.noted("permissions: ")]],
      note = "mtime, permissions",
    },

    { keys = ":File help<CR>" },
    {
      expect = [[_G.noted(":File[!] {subcommand}") and _G.noted("bulk rename {pat}")]],
      note = "help",
    },

    -- cd: one window by default, wider when asked
    { lua = [[vim.cmd("wincmd v")]] },
    { keys = ":File cd<CR>" },
    {
      expect = [[vim.fs.normalize(vim.fn.getcwd()) == _G.p("d/e")]],
      note = "this window is there",
    },
    { expect = [[vim.fn.haslocaldir() == 1]], note = "default scope: window" },
    { keys = "<C-w>w" },
    { expect = [[vim.fs.normalize(vim.fn.getcwd()) == _G.root]], note = "the other window is not" },
    { keys = ":File cd tab<CR>" },
    {
      expect = [[vim.fn.haslocaldir(-1, 0) == 1 and vim.fn.haslocaldir() == 0]],
      note = "tab: :tcd",
    },
    { keys = ":File cd global<CR>" },
    { expect = [[vim.fs.normalize(vim.fn.getcwd(-1, -1)) == _G.p("d/e")]], note = "global: :cd" },
  },
}
