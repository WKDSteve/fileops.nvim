-- Live check: `:checkhealth fileops` with ui.nvim really off the runtimepath (task
-- fileops.nvim/testblatt-bindings-checkliste; section 12 of ALL/manual-test-checklists/fileops.md).
return {
  id = "fileops.health-no-ui",
  title = "fileops.nvim: :checkhealth fileops without ui.nvim",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.drop_rtp("ui.nvim")
      require("fileops").setup({})]],
      note = "ui.nvim taken off the runtimepath before anything loads it",
    },
    { expect = [[not pcall(require, "ui.kit")]], note = "really gone" },
    { keys = ":checkhealth fileops<CR>" },
    { wait = [[_G.text():find("ui.nvim not found", 1, true) ~= nil]], timeout = 5000 },
    {
      expect = [[_G.text():find("missing-destination prompt", 1, true)
        and _G.text():find("modified-buffer", 1, true)]],
      note = "names the prompts that stop working",
    },
    {
      expect = [[_G.text():find('Install "WKDSteve/ui.nvim"', 1, true) ~= nil]],
      note = "and the fix",
    },
  },
}
