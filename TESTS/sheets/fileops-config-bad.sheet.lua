-- Live check: a bad config is reported at `setup()` and dropped, the default applies (task
-- fileops.nvim/testblatt-bindings-checkliste; section 12 of ALL/manual-test-checklists/fileops.md).
return {
  id = "fileops.config-bad",
  title = "fileops.nvim: bad options are reported and dropped, the defaults apply",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({
        delete = { mode = "shred" },
        retry = { attempts = "many", backoff_ms = -1 },
        on_hold = { modes = 3, ignore_buftypes = "nofile" },
        tpyo = true,
      })
      _G.cfg = require("fileops.config").get()
      _G.issues = table.concat(require("fileops.config").issues(), "\n")]],
      note = "one bad value of each kind and a typo",
    },
    { expect = [[_G.cfg.delete.mode == "trash"]], note = "delete.mode: the default" },
    { expect = [[type(_G.cfg.retry.attempts) == "number" and _G.cfg.retry.attempts >= 1]] },
    { expect = [[_G.cfg.retry.backoff_ms == 60]], note = "retry.backoff_ms: the default" },
    { expect = [[_G.cfg.on_hold.modes == "n"]], note = "on_hold.modes: the default" },
    { expect = [[type(_G.cfg.on_hold.ignore_buftypes) == "table"]], note = "ignore_buftypes" },
    { expect = [[_G.issues:find("delete.mode", 1, true) ~= nil]], note = "reported: delete.mode" },
    { expect = [[_G.issues:find("retry.attempts", 1, true) ~= nil]], note = "reported: attempts" },
    { expect = [[_G.issues:find("retry.backoff_ms", 1, true) ~= nil]], note = "reported: backoff" },
    { expect = [[_G.issues:find("on_hold.modes", 1, true) ~= nil]], note = "reported: modes" },
    { expect = [[_G.issues:find("on_hold.ignore_buftypes", 1, true) ~= nil]], note = "reported" },
    { expect = [[_G.issues:find("tpyo", 1, true) ~= nil]], note = "reported: the typo" },
    { keys = ":checkhealth fileops<CR>" },
    { wait = [[_G.text():find("config: ", 1, true) ~= nil]], timeout = 5000 },
    { expect = [[_G.text():find("shred", 1, true) ~= nil]], note = "and in :checkhealth" },
    { keys = ":File help<CR>", note = "the plugin works with the defaults" },
    { expect = [[_G.noted(":File[!] {subcommand}")]] },
  },
}
