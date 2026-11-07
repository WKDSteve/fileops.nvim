-- Live check: with the real gitsuite.nvim on the runtimepath: it highlights the conflict instead of
-- fileops' fallback, and its real events refresh the explorer (task
-- fileops.nvim/testblatt-bindings-checkliste; section 10 of ALL/manual-test-checklists/fileops.md).
-- gitsuite.nvim is a CI checkout beside this repo and on no other sheet's runtimepath.
return {
  id = "fileops.gitsuite",
  title = "fileops.nvim: conflict markers and explorer refresh with the real gitsuite.nvim",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  requires = {
    {
      lua = [[vim.fn.isdirectory(vim.env.GITSUITE_NVIM_DIR
        or (vim.fs.dirname(vim.fn.getcwd()) .. "/gitsuite.nvim")) == 1]],
      reason = "gitsuite.nvim is not beside this repo",
    },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      vim.opt.rtp:append(vim.env.GITSUITE_NVIM_DIR
        or (vim.fs.dirname(vim.fn.getcwd()) .. "/gitsuite.nvim"))
      require("fileops").setup({})
      _G.sandbox()
      _G.explorer()
      _G.put("c.txt", table.concat({
        "<<<<<<< HEAD", "ours", "||||||| base", "bottom", "=======", "theirs", ">>>>>>> other", "",
      }, "\n"))
      _G.conflict_ns = vim.api.nvim_create_namespace("gitsuite_conflict")]],
      note = "gitsuite.nvim on the runtimepath; a diff3-style conflict as git writes it",
    },

    { keys = ":edit c.txt<CR>" },
    { expect = [[#vim.fn.getmatches() == 0]], note = "not fileops' three fixed patterns" },
    {
      expect = [[#vim.api.nvim_buf_get_extmarks(0, _G.conflict_ns, 0, -1, {}) > 0]],
      note = "gitsuite's extmarks",
    },
    {
      expect = [[#vim.api.nvim_buf_get_extmarks(0, _G.conflict_ns, { 2, 0 }, { 3, -1 }, {}) > 0]],
      note = "the ||||||| base section is recognised",
    },

    -- the real events: choose() resolves the last region and fires
    { expect = [[_G.reloads == 0]] },
    { lua = [[vim.api.nvim_win_set_cursor(0, { 2, 0 })]] },
    { lua = [[require("gitsuite.features.conflict").choose("ours")]] },
    {
      expect = [[_G.text():find("^ours") and not _G.text():find("<<<", 1, true)]],
      note = "gitsuite resolved it",
    },
    { expect = [[_G.reloads == 1]], note = "GitsuiteConflictsResolved refreshed the explorer" },
    { expect = [[_G.changed[#_G.changed].action == "git-conflict-resolved"]] },
    { lua = [[require("gitsuite.events").branch_switched(_G.root, "other")]] },
    { expect = [[_G.reloads == 2]], note = "GitsuiteBranchSwitched refreshed the explorer" },
    {
      expect = [[vim.fs.normalize(_G.changed[#_G.changed].path) == _G.root]],
      note = "for the root",
    },
  },
  manual = {
    "A conflict from a real merge, seen through gitsuite.nvim: the colours of the sides read well",
  },
}
