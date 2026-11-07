-- Live check: `:checkhealth fileops` on a complete install, and how `setup()` treats a bad config (task
-- fileops.nvim/testblatt-bindings-checkliste; section 12 and Setup of
-- ALL/manual-test-checklists/fileops.md).
return {
  id = "fileops.health",
  title = "fileops.nvim: :checkhealth fileops, config hardening",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})]],
      note = "a complete install: lib.nvim and ui.nvim on the runtimepath",
    },
    { keys = ":checkhealth fileops<CR>" },
    { wait = [[_G.text():find("lib.nvim detected", 1, true) ~= nil]], timeout = 5000 },
    { expect = [[_G.text():find("Neovim >= 0.9", 1, true) ~= nil]], note = "the version" },
    { expect = [[_G.text():find("libuv available", 1, true) ~= nil]], note = "libuv" },
    { expect = [[_G.text():find("vim.fs.dir is available", 1, true) ~= nil]], note = "vim.fs.dir" },
    { expect = [[_G.text():find("plugin loaded", 1, true) ~= nil]], note = "the guard" },
    { expect = [[_G.text():find("ui.nvim detected", 1, true) ~= nil]], note = "ui.nvim" },
    { expect = [[_G.text():find("which-key", 1, true) ~= nil]], note = "which-key is reported" },
    { expect = [[_G.text():find("git executable", 1, true) ~= nil]], note = "git is reported" },
    { expect = [[_G.text():find("gitsigns.nvim", 1, true) ~= nil]], note = "gitsigns is reported" },
    { expect = [[_G.text():find("config: no unknown", 1, true) ~= nil]], note = "a clean config" },
    { expect = [[not _G.text():find("ERROR", 1, true)]], note = "no ERROR on a complete install" },

    -- a second setup() warns, and is not applied
    { lua = [[require("fileops").setup({ delete = { mode = "permanent" } })]] },
    { expect = [[_G.noted("setup() already called; ignoring")]], note = "the second call warns" },
    {
      expect = [[require("fileops.config").get().delete.mode == "trash"]],
      note = "and is ignored",
    },
  },
}
