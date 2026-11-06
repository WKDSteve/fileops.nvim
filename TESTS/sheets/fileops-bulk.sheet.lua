-- Live check: `:File bulk rename`: Lua pattern, preview, the real dialog, one directory only, collisions
-- and open buffers (task fileops.nvim/testblatt-bindings-checkliste, binding :File bulk rename; section
-- 7 of ALL/manual-test-checklists/fileops.md).
return {
  id = "fileops.bulk",
  title = "fileops.nvim: :File bulk rename",
  task = "fileops.nvim/testblatt-bindings-checkliste",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})
      _G.sandbox()
      local list_f = { "a.txt", "b.txt", "keep.lua", "sub/c.txt" }
      for i_f = 1, #list_f do
        local f = list_f[i_f]
        _G.put(f, f)
      end
      _G.open("a.txt")
      _G.tick = vim.b.changedtick]],
      note = "two matching files, one that does not match, one in a subdirectory; a.txt is open",
    },

    { keys = ":File bulk rename %.txt$ .md<CR>" },
    { wait = "_G.dialog()", note = "the dialog asks" },
    {
      expect = [[_G.noted("a.txt → a.md") and _G.noted("b.txt → b.md")]],
      note = "the preview",
    },
    { keys = "<Esc>", note = "declined" },
    {
      expect = [[_G.exists("a.txt") and not _G.exists("a.md")]],
      note = "a cancel renames nothing",
    },

    { keys = ":File bulk rename %.txt$ .md<CR>" },
    { wait = "_G.dialog()" },
    { expect = [[_G.float_text():find("Rename 2 file", 1, true) ~= nil]] },
    { keys = "h<CR>", note = "Rename 2 file(s)" },
    { expect = [[_G.get("a.md") == "a.txt" and _G.get("b.md") == "b.txt"]], note = "both renamed" },
    { expect = [[_G.exists("sub/c.txt") and _G.exists("keep.lua")]], note = "nothing else" },
    { expect = [[_G.noted("2 file(s) renamed")]] },

    -- the open buffer follows without a reload
    { expect = [[_G.here() == "a.md"]], note = "the open buffer is re-pointed" },
    { expect = [[vim.b.changedtick == _G.tick]], note = "and not reloaded" },

    -- a Lua pattern, not a glob: the unanchored dot is any character
    { lua = [[_G.put("footxt.md", "foo"); _G.put("real.txt", "real"); _G.notes = {}]] },
    { keys = ":File bulk rename .txt .md<CR>" },
    { wait = "_G.dialog()" },
    { expect = [[_G.noted("footxt.md → fo.md.md")]], note = "the dot matched the o" },
    { keys = "<Esc>" },

    -- a collision: the dialog offers to skip it, the rest goes through
    {
      lua = [[os.remove(_G.p("footxt.md"))
      _G.put("clash.txt", "new"); _G.put("clash.md", "old")
      _G.notes = {}]],
    },
    { keys = ":File bulk rename %.txt$ .md<CR>" },
    { wait = "_G.dialog()" },
    { expect = [[_G.noted("clash.txt → clash.md  (exists)")]], note = "the preview marks it" },
    { expect = [[_G.float_text():find("skip 1 existing", 1, true) ~= nil]], note = "skip offered" },
    { keys = "<CR>", note = "the harmless answer has the focus: skip" },
    { expect = [[_G.get("clash.md") == "old" and _G.get("clash.txt") == "new"]], note = "kept" },
    { expect = [[_G.get("real.md") == "real"]], note = "the rest of the batch went through" },
    { expect = [[_G.noted("kept clash.txt")]], note = "and the skip is reported" },

    -- ... or overwrites it, when asked for that
    { lua = [[_G.notes = {}]] },
    { keys = ":File bulk rename %.txt$ .md<CR>" },
    { wait = "_G.dialog()" },
    { keys = "<CR>", note = "only Cancel and overwrite are left: the focus is on Cancel" },
    { expect = [[_G.get("clash.md") == "old"]], note = "never the overwrite by default" },
    { keys = ":File bulk rename %.txt$ .md<CR>" },
    { wait = "_G.dialog()" },
    { keys = "l<CR>", note = "the overwrite button" },
    {
      expect = [[_G.get("clash.md") == "new" and not _G.exists("clash.txt")]],
      note = "on request",
    },

    -- nothing to do
    { lua = [[_G.notes = {}]] },
    { keys = ":File bulk rename %.nothing$ .x<CR>" },
    { expect = [[_G.noted("no files in")]], note = "no match: says so" },
  },
}
