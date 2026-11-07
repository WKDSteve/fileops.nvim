-- Live check: `:File next/prev/first/last/open` and their targets (task
-- fileops.nvim/testblatt-bindings-checkliste, bindings :File next, prev, first, last, open; section 5
-- of ALL/manual-test-checklists/fileops.md). `cycle.open_target = "current"` is what the real config
-- sets.
return {
  id = "fileops.cycle",
  title = "fileops.nvim: :File next, prev, first, last, open",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({ cycle = { open_target = "current" } })
      _G.sandbox()
      local list_f = { "d/a.lua", "d/B.txt", "d/c.lua", "d/e.txt", "d/.hidden", "zzz.lua" }
      for i_f = 1, #list_f do
        local f = list_f[i_f]
        _G.put(f, f)
      end
      vim.fn.mkdir(_G.p("d/sub"), "p")
      _G.open("d/a.lua")]],
      note = "a directory below the cwd, a file at the cwd that must never come up",
    },

    { keys = ":File next<CR>" },
    { expect = [[_G.here() == "d/B.txt"]], note = "alphabetical, in the buffer's directory" },
    {
      expect = [[_G.listed("d/a.lua")]],
      note = "open_target current: the old buffer stays listed",
    },
    { keys = ":File prev<CR>" },
    { expect = [[_G.here() == "d/a.lua"]] },
    { keys = ":2File next<CR>" },
    { expect = [[_G.here() == "d/c.lua"]], note = ":2File next skips two" },
    { keys = ":File next *.txt<CR>" },
    { expect = [[_G.here() == "d/e.txt"]], note = "the glob narrows the listing" },
    { keys = ":File next *.lua<CR>", note = "past the end of the filtered list" },
    { expect = [[_G.here() == "d/a.lua"]], note = "wraps" },
    { keys = ":File prev<CR>" },
    { expect = [[_G.here() == "d/e.txt"]], note = "wraps backwards; no hidden file, no directory" },

    { keys = ":File first<CR>" },
    { expect = [[_G.here() == "d/a.lua"]] },
    { keys = ":File last<CR>" },
    { expect = [[_G.here() == "d/e.txt"]] },

    -- targets: replace throws the old buffer away, the others keep it
    { keys = ":File next replace<CR>" },
    { expect = [[_G.here() == "d/a.lua" and not _G.listed("d/e.txt")]], note = "replace" },
    { keys = ":File next vsplit *.txt<CR>" },
    { wait = "_G.wins() == 2", note = "a target and a glob" },
    { settle = 50 },
    { expect = [[_G.here() == "d/a.lua"]], note = "keep_focus: the old window keeps the focus" },
    { keys = ":only<CR>" },
    { keys = ":File next bg<CR>" },
    {
      expect = [[_G.here() == "d/a.lua" and _G.listed("d/B.txt") and _G.wins() == 1]],
      note = "bg",
    },

    -- open: the same file somewhere else
    { keys = ":File open split<CR>" },
    { wait = "_G.wins() == 2" },
    { keys = ":only<CR>" },
    { keys = ":File open tab<CR>" },
    { expect = [[vim.fn.tabpagenr("$") == 2 and _G.here() == "d/a.lua"]], note = "open tab" },
    { keys = ":tabonly<CR>" },

    -- an unnamed buffer has no place in a listing
    { keys = ":enew<CR>" },
    { lua = [[_G.notes = {}]] },
    { keys = ":File next<CR>" },
    { expect = [[#_G.notes == 1]], note = "says why instead of erroring" },
  },
}
