-- Live check: the File fly-out of ui.nvim's real right-click menu (task
-- fileops.nvim/testblatt-bindings-checkliste; section 11 of ALL/manual-test-checklists/fileops.md). The
-- menu is built by the host and opened through its own entry point.
return {
  id = "fileops.menu",
  feature = "fileops.menu",
  title = "fileops.nvim: the File fly-out of ui.nvim's menu",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})
      _G.sandbox()
      _G.put("d/a.txt", "a")
      _G.put("d/b.txt", "b")
      -- The fly-out as the host composes it: its rows by trimmed name.
      function _G.flyout()
        for _, item in ipairs(require("ui.menu").items(0)) do
          local rows = {}
          for _, row in ipairs(type(item.items) == "table" and item.items or {}) do
            if type(row.name) == "string" then
              rows[vim.trim(row.name)] = row
            end
          end
          if rows["Next file in directory"] then
            return rows
          end
        end
      end
      function _G.has(...)
        local rows = _G.flyout() or {}
        for _, name in ipairs({ ... }) do
          if not rows[name] then
            return false
          end
        end
        return true
      end
      function _G.count()
        return #vim.tbl_keys(_G.flyout() or {})
      end
      function _G.pick(name)
        local cmd = _G.flyout()[name].cmd
        if type(cmd) == "function" then
          cmd()
        else
          vim.cmd(cmd)
        end
      end
      _G.open("d/a.txt")]],
      note = "a named file",
    },

    -- a named file: all entries
    {
      expect = [[_G.has("Rename file…", "Duplicate file…", "Delete file", "Copy path",
        "Show file info", "Next file in directory", "Previous file in directory")]],
      note = "the seven entries",
    },

    -- each runs its :File subcommand
    { lua = [[_G.pick("Copy path")]] },
    { expect = [[vim.fs.normalize(vim.fn.getreg('"')) == _G.p("d/a.txt")]], note = "Copy path" },
    { lua = [[_G.pick("Show file info")]] },
    { expect = [[_G.noted("size: 1 B")]], note = "Show file info" },
    { lua = [[_G.pick("Next file in directory")]] },
    { expect = [[_G.here() == "d/b.txt"]], note = "Next" },
    { lua = [[_G.pick("Previous file in directory")]] },
    { expect = [[_G.here() == "d/a.txt"]], note = "Previous" },
    { lua = [[vim.schedule(function() _G.pick("Rename file…") end)]] },
    { wait = "_G.prompting()", note = "Rename prompts for the destination" },
    { input = "<Esc>" },
    { wait = [[vim.api.nvim_win_get_config(0).relative == ""]] },
    { lua = [[vim.schedule(function() _G.pick("Duplicate file…") end)]] },
    { wait = "_G.prompting()", note = "Duplicate prompts for the destination" },
    { input = "<Esc>" },
    { wait = [[vim.api.nvim_win_get_config(0).relative == ""]] },
    { lua = [[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })]] },
    { lua = [[_G.pick("Delete file")]] },
    { wait = "_G.dialog()", note = "Delete goes through the confirm" },
    { keys = "<Esc>" },
    { expect = [[_G.exists("d/a.txt")]] },
    { lua = [[vim.cmd("silent! write")]] },

    -- the real menu opens and shows it
    { lua = [[require("ui.menu").open({})]] },
    {
      wait = [[_G.float_text():find("File", 1, true) ~= nil]],
      note = "the host's menu shows File",
    },
    { keys = "<Esc>" },
    { settle = 50 },

    -- an unnamed buffer: only the two that work everywhere
    { keys = ":enew<CR>" },
    { expect = [[_G.has("Next file in directory", "Previous file in directory")]] },
    { expect = [[_G.count() == 2]], note = "an unnamed buffer keeps Next and Previous only" },

    -- the switch
    { expect = [[require("fileops.integrations.menu").enabled() == true]] },
    { lua = [[require("fileops.config").get().integrations.ui_menu = false]] },
    {
      expect = [[require("fileops.integrations.menu").enabled() == false]],
      note = "ui_menu = false",
    },
    { expect = [[_G.flyout() == nil]], note = "the fly-out is gone from the host's menu" },
    {
      expect = [[#require("fileops.integrations.menu").items() > 0]],
      note = "other hosts calling items() are unaffected",
    },
  },
  manual = {
    "A real right click on a buffer with a file opens the fly-out at the pointer",
  },
}
