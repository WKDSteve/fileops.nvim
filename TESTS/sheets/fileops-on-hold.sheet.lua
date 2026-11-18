-- Feature sheet: `on_hold` switched on. Resting the cursor on a changed line of a tracked file shows the line as it was
-- committed at the end of the line (git rev-parse, ls-files, blame and show, all asynchronous); moving on clears it.
-- gitsuite.nvim and gitsigns are not on this sheet's runtimepath, so fileops' own blame runs. git runs for real.
local MARKS =
  [[vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("fileops_on_hold_preview"), 0, -1, {})]]

return {
  id = "fileops.on-hold",
  feature = "fileops.on-hold",
  title = "fileops.nvim: on_hold shows the committed version of the line under the cursor",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({ on_hold = { enable = true, delay = 0, throttle_ms = 0 } })
      _G.sandbox()
      _G.repo({ ["n.txt"] = "old one\nold two\n" })]],
      note = "on_hold on, without the extra delay; a committed file",
    },
    { expect = [[not pcall(require, "gitsuite.features.blame")]], note = "gitsuite is absent" },
    { expect = [[vim.o.updatetime == 100]], note = "CursorHold comes quickly" },

    { keys = ":edit n.txt<CR>" },
    { keys = "jccnew two<Esc>", note = "change the second line, do not save" },
    {
      wait = "#" .. MARKS .. " == 1",
      timeout = 8000,
      note = "the cursor rests: the preview appears",
    },
    {
      hl = { text = "previous: old two", group = "Comment" },
      note = "the committed line, drawn as a comment",
    },
    {
      expect = [[vim.api.nvim_get_current_line() == "new two"]],
      note = "the buffer keeps its text",
    },

    { keys = "k", note = "moving on" },
    { expect = "#" .. MARKS .. " == 0", note = "clears the preview" },

    -- an untracked file shows nothing
    { lua = [[_G.put("loose.txt", "loose\n")]] },
    { keys = ":edit loose.txt<CR>" },
    { keys = "ccchanged<Esc>" },
    { settle = 600 },
    { expect = "#" .. MARKS .. " == 0", note = "only_tracked: nothing for an untracked file" },
  },
}
