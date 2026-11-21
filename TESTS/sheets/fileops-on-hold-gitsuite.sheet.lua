-- Feature sheet: `on_hold` with the real gitsuite.nvim on the runtimepath. The blame half goes through gitsuite's
-- `features.blame.for_location`, the `git show` half stays fileops' own; the preview looks the same as without it.
-- gitsuite.nvim is a CI checkout (TESTS/sheets/_deps.lua finds it). git runs for real.
local MARKS =
  [[vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("fileops_on_hold_preview"), 0, -1, {})]]

return {
  id = "fileops.on-hold-gitsuite",
  feature = "fileops.on-hold",
  title = "fileops.nvim: on_hold takes the blame from gitsuite.nvim when it is installed",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  requires = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_deps.lua")("gitsuite.nvim") ~= nil]],
      reason = "gitsuite.nvim is neither in $GITSUITE_NVIM_DIR, .deps/ nor beside this repo",
    },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      vim.opt.rtp:append(dofile(vim.fn.getcwd() .. "/TESTS/sheets/_deps.lua")("gitsuite.nvim"))
      require("fileops").setup({ on_hold = { enable = true, delay = 0, throttle_ms = 0 } })
      _G.sandbox()
      _G.repo({ ["n.txt"] = "old one\nold two\n" })
      _G.blamed = 0
      local blame = require("gitsuite.features.blame")
      local for_location = blame.for_location
      blame.for_location = function(...)
        _G.blamed = _G.blamed + 1
        return for_location(...)
      end]],
      note = "gitsuite.nvim on the runtimepath (its blame counted); on_hold on; a committed file",
    },
    { keys = ":edit n.txt<CR>" },
    { keys = "jccnew two<Esc>", note = "change the second line, do not save" },
    { wait = "#" .. MARKS .. " == 1", timeout = 8000, note = "the preview appears" },
    { expect = [[_G.blamed >= 1]], note = "the blame came from gitsuite" },
    {
      hl = { text = "previous: old two", group = "Comment" },
      note = "the same committed line as without gitsuite",
    },
  },
}
