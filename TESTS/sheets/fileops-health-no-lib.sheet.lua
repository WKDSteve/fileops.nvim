-- Live check: `:checkhealth fileops` with lib.nvim really off the runtimepath (task
-- fileops.nvim/testblatt-bindings-checkliste; section 12 of ALL/manual-test-checklists/fileops.md).
-- ui.nvim goes too: its kit re-exports lib.nvim's. No `setup()`: it cannot run without lib.nvim.
return {
  id = "fileops.health-no-lib",
  title = "fileops.nvim: :checkhealth fileops without lib.nvim",
  task = "fileops.nvim/testblatt-bindings-checkliste",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.drop_rtp("lib.nvim")
      _G.drop_rtp("ui.nvim")
      for name in pairs(package.loaded) do
        if name:find("^lib%.") or name:find("^ui%.") then
          package.loaded[name] = nil
        end
      end]],
      note = "lib.nvim taken off the runtimepath",
    },
    { expect = [[not pcall(require, "lib.nvim.bindings.usercmd.composer")]], note = "really gone" },
    { keys = ":checkhealth fileops<CR>", ignore_errmsg = true },
    { wait = [[_G.text():find("fileops", 1, true) ~= nil]], timeout = 5000 },
    { settle = 100 },
    { expect = [[_G.text():find("lib.nvim not found", 1, true) ~= nil]], note = "names lib.nvim" },
    {
      expect = [[_G.text():find('Install "WKDSteve/lib.nvim"', 1, true) ~= nil]],
      note = "with a useful message",
    },
    { expect = [[not _G.text():find("Failed to run healthcheck", 1, true)]], note = "no crash" },
  },
}
