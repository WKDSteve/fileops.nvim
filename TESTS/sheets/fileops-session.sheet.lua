-- Live check: rename and move keep an active `:mksession` session up to date, and do nothing without
-- one (task fileops.nvim/testblatt-bindings-checkliste; section 4 of
-- ALL/manual-test-checklists/fileops.md).
return {
  id = "fileops.session",
  title = "fileops.nvim: session_compat resaves the active session, and only that",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})
      _G.sandbox()
      _G.put("one.txt", "1")
      _G.put("two.txt", "2")
      _G.open("one.txt")]],
    },

    -- no session: nothing appears anywhere
    { expect = [[vim.v.this_session == ""]] },
    { keys = ":File rename one-b.txt<CR>" },
    { keys = ":File move sub/one-c.txt<CR>" },
    { expect = [[_G.get("sub/one-c.txt") == "1"]] },
    {
      expect = [[not _G.exists("Session.vim") and not _G.exists("sub/Session.vim")]],
      note = "no session: no Session.vim",
    },

    -- a session elsewhere: it is resaved in place, and the cwd stays clean
    { lua = [[vim.fn.mkdir(_G.p("store"), "p"); vim.cmd("mksession " .. _G.p("store/my.vim"))]] },
    { expect = [[vim.fs.normalize(vim.v.this_session) == _G.p("store/my.vim")]] },
    { expect = [[not _G.get("store/my.vim"):find("one-d", 1, true)]], note = "the old session" },
    { keys = ":File rename one-d.txt<CR>" },
    {
      expect = [[_G.get("store/my.vim"):find("one-d.txt", 1, true) ~= nil]],
      note = "rename resaves",
    },
    { expect = [[not _G.exists("Session.vim")]], note = "not the bare :mksession! trap" },
    { keys = ":File move one-e.txt<CR>" },
    {
      expect = [[_G.get("store/my.vim"):find("one-e.txt", 1, true) ~= nil]],
      note = "move resaves",
    },
    { expect = [[not _G.exists("Session.vim") and not _G.exists("sub/Session.vim")]] },
  },
}
