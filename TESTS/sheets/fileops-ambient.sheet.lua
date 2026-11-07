-- Live check: what runs without a command: auto_mkdir, the conflict-marker fallback, the gitsuite event
-- listener and the inert on_hold (task fileops.nvim/testblatt-bindings-checkliste; section 10 of
-- ALL/manual-test-checklists/fileops.md). gitsuite.nvim is not on this sheet's runtimepath.
return {
  id = "fileops.ambient",
  title = "fileops.nvim: auto_mkdir, conflict markers without gitsuite, events, on_hold off",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})
      _G.sandbox()
      _G.explorer()]],
      note = "defaults; an explorer that counts its reloads",
    },

    -- auto_mkdir
    { keys = ":edit new/dir/here.txt<CR>" },
    { lua = [[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x" })]] },
    { keys = ":write<CR>", note = "the parents do not exist" },
    {
      expect = [[_G.get("new/dir/here.txt"):find("x", 1, true) ~= nil]],
      note = "created, written",
    },
    { expect = [[#_G.notes == 0]], note = "without a warning" },
    {
      lua = [[vim.api.nvim_exec_autocmds("BufWritePre", { pattern = "ssh://host/remote/x.txt" })]],
      note = "a remote-looking name",
    },
    { expect = [[vim.fn.isdirectory(_G.p("ssh:")) == 0]], note = "no local mkdir for it" },
    { expect = [[vim.fn.isdirectory("ssh:") == 0]] },

    -- the conflict-marker fallback, per window
    {
      lua = [[_G.put("c.txt", "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> other\n")
      _G.put("plain.txt", "x")]],
    },
    { expect = [[not pcall(require, "gitsuite.features.conflict")]], note = "gitsuite is absent" },
    { keys = ":edit c.txt<CR>" },
    {
      expect = [[vim.deep_equal(vim.tbl_map(function(m)
        return m.group
      end, vim.fn.getmatches()), { "DiffDelete", "DiffChange", "DiffAdd" })]],
      note = "the three fallback highlights",
    },
    { keys = ":edit plain.txt<CR>", note = "leaving the window's buffer" },
    { expect = [[#vim.fn.getmatches() == 3]], note = "cleared and set afresh for the new buffer" },
    { keys = ":vsplit<CR>" },
    { keys = ":close<CR>" },
    { expect = [[#vim.fn.getmatches() == 3]], note = "no pile-up" },
    {
      lua = [[vim.api.nvim_exec_autocmds("BufWinLeave", { buffer = 0 })]],
      note = "the BufWinLeave half",
    },
    { expect = [[#vim.fn.getmatches() == 0]], note = "cleared" },

    -- the gitsuite events: the listener, with gitsuite absent
    { expect = [[_G.reloads == 0]] },
    {
      lua = [[vim.api.nvim_exec_autocmds("User", {
        pattern = "GitsuiteBranchSwitched",
        data = { dir = _G.root, branch = "x" },
      })]],
    },
    { expect = [[_G.reloads == 1]], note = "a branch switch refreshes the explorer" },
    { expect = [[_G.changed[#_G.changed].action == "git-checkout"]] },
    {
      expect = [[vim.fs.normalize(_G.changed[#_G.changed].path) == _G.root]],
      note = "for the root",
    },
    {
      lua = [[vim.api.nvim_exec_autocmds("User", {
        pattern = "GitsuiteConflictsResolved",
        data = { bufnr = vim.api.nvim_get_current_buf() },
      })]],
    },
    { expect = [[_G.reloads == 2]], note = "a resolved conflict refreshes it" },
    { expect = [[_G.changed[#_G.changed].action == "git-conflict-resolved"]] },
    {
      expect = [[vim.fs.basename(_G.changed[#_G.changed].path) == "plain.txt"]],
      note = "for that file",
    },
    { expect = [[#_G.notes == 0]], note = "nothing errors" },

    -- on_hold off: entirely inert
    {
      expect = [[#vim.tbl_filter(function(a)
        return (a.group_name or ""):find("fileops", 1, true) ~= nil
      end, vim.api.nvim_get_autocmds({ event = { "CursorHold", "CursorHoldI" } })) == 0]],
      note = "no CursorHold autocmd of this plugin at all",
    },
    { lua = [[vim.api.nvim_exec_autocmds("CursorHold", {})]] },
    { settle = 50 },
    {
      expect = [[#vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {}) == 0]],
      note = "no line-diff preview",
    },
  },
}
