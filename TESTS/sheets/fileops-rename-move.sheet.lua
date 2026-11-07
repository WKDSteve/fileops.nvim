-- Live check: `:File rename` and `:File move`, their base directory and what happens to unsaved text
-- and undo history (task fileops.nvim/testblatt-bindings-checkliste; sections 1, 2 and 4 of
-- ALL/manual-test-checklists/fileops.md).
return {
  id = "fileops.rename-move",
  title = "fileops.nvim: :File rename and :File move",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})
      _G.sandbox()
      _G.put("src/deep/nested/file.lua", "one\n")
      _G.open("src/deep/nested/file.lua")]],
      note = "a file below the cwd",
    },

    -- rename: the buffer's directory is the base, unsaved text is written, the buffer follows
    { lua = [[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "two" })]] },
    { keys = ":File rename sibling2.lua<CR>" },
    { expect = [[_G.here() == "src/deep/nested/sibling2.lua"]], note = "next to the old file" },
    { expect = [[not _G.exists("sibling2.lua")]], note = "not at the cwd" },
    { expect = [[not _G.exists("src/deep/nested/file.lua")]], note = "the old name is gone" },
    { expect = [[_G.get("src/deep/nested/sibling2.lua"):find("two", 1, true)]], note = "written" },
    { expect = [[not vim.bo.modified]] },
    { expect = [[_G.noted("renamed file.lua")]], note = "the result message" },
    { expect = [[not _G.noted("git")]], note = "git_aware is off by default: no git in it" },

    -- move: a directory away, the buffer is not reloaded
    {
      lua = [[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "three" })
      _G.seq = vim.fn.undotree().seq_last]],
    },
    { keys = ":File move ../other/moved.lua<CR>" },
    { expect = [[_G.here() == "src/deep/other/moved.lua"]], note = "relative to the buffer" },
    { expect = [[_G.get("src/deep/other/moved.lua"):find("three", 1, true)]], note = "written" },
    { expect = [[vim.fn.undotree().seq_last == _G.seq]], note = "move adds no undo step" },
    { keys = "u", note = "undo after a move" },
    { expect = [[_G.text() ~= "three"]], note = "the change before the move is undone" },
    { lua = [[vim.cmd("silent! redo"); vim.cmd("silent! write")]] },

    -- rename reloads: observed, not assumed: what becomes of the undo history
    { lua = [[_G.seq = vim.fn.undotree().seq_last]] },
    { keys = ":File rename reloaded.lua<CR>" },
    { expect = [[_G.here() == "src/deep/other/reloaded.lua"]] },
    { expect = [[vim.fn.undotree().seq_last > _G.seq]], note = "the reload is a step of the tree" },
    { keys = "u", note = "undo the reload: the same text" },
    { keys = "u", note = "undo further" },
    { expect = [[_G.text() ~= "three"]], note = "the history survives a rename too" },

    -- neither form asks about unsaved text, with or without `!`: it is written
    { lua = [[vim.cmd("silent! redo"); vim.api.nvim_buf_set_lines(0, 0, -1, false, { "five" })]] },
    { keys = ":File! rename forced.lua<CR>" },
    { expect = "not _G.dialog()", note = "rename!: no dialog" },
    { expect = [[_G.get("src/deep/other/forced.lua"):find("five", 1, true)]], note = "written" },
    { lua = [[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "six" })]] },
    { keys = ":File! move forced2.lua<CR>" },
    { expect = "not _G.dialog()", note = "move!: no dialog" },
    { expect = [[_G.get("src/deep/other/forced2.lua"):find("six", 1, true)]], note = "written" },

    -- from a buffer without a file there is nothing to rename
    { keys = ":enew<CR>" },
    { keys = ":File rename x.lua<CR>" },
    { expect = [[_G.noted("current buffer has no file name")]] },

    -- a parent that does not exist yet
    { lua = [[_G.put("flat.txt", "f"); _G.open("flat.txt")]] },
    { keys = ":File move a/b/c/flat.txt<CR>" },
    { expect = [[_G.get("a/b/c/flat.txt") == "f"]], note = "move creates the parents" },
  },
}
