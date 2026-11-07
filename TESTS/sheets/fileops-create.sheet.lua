-- Live check: the create family of `:File` and its base directory (task
-- fileops.nvim/testblatt-bindings-checkliste, bindings :File touch, new, write, saveas, writeto, mkdir;
-- section 1 of ALL/manual-test-checklists/fileops.md).
return {
  id = "fileops.create",
  title = "fileops.nvim: :File touch, new, write, saveas, writeto, mkdir resolve against the cwd",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({})
      _G.sandbox()]],
      note = "fileops.nvim with its defaults, in a throwaway cwd",
    },

    -- touch
    { keys = ":File touch scratch.txt<CR>" },
    { expect = [[_G.get("scratch.txt") == ""]], note = "touch creates an empty file" },
    {
      expect = [[vim.api.nvim_buf_get_name(0) == ""]],
      note = "touch neither opens nor names a buffer",
    },
    { lua = [[_G.put("scratch.txt", "kept")]] },
    { keys = ":File touch scratch.txt<CR>", note = "a second touch on the same path" },
    {
      expect = [[_G.get("scratch.txt") == "kept"]],
      note = "real touch semantics: nothing truncated",
    },
    { keys = ":File touch a/b/c.txt<CR>" },
    { expect = [[_G.get("a/b/c.txt") == ""]], note = "touch creates the missing parents" },

    -- new: name only, no write
    { keys = ":File new deep1/draft.md<CR>" },
    { expect = [[_G.here() == "deep1/draft.md"]], note = "new sets the buffer name" },
    {
      expect = [[vim.fn.isdirectory(_G.p("deep1")) == 1]],
      note = "new creates the missing parent",
    },
    { expect = [[not _G.exists("deep1/draft.md")]], note = "new does not write" },

    -- write: name and write
    { keys = ":enew<CR>" },
    { lua = [[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "out" })]] },
    { keys = ":File write deep2/x/out.txt<CR>" },
    { expect = [[_G.here() == "deep2/x/out.txt"]], note = "write sets the buffer name" },
    {
      expect = [[_G.get("deep2/x/out.txt"):find("out", 1, true) ~= nil]],
      note = "write writes, parents included",
    },

    -- saveas: the buffer follows
    { lua = [[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "saved" })]] },
    { keys = ":File saveas deep3/x/saved.txt<CR>" },
    { expect = [[_G.here() == "deep3/x/saved.txt"]], note = "saveas changes the buffer name" },
    {
      expect = [[_G.get("deep3/x/saved.txt"):find("saved", 1, true) ~= nil]],
      note = "saveas writes, parents included",
    },

    -- writeto: the buffer stays
    { keys = ":File writeto deep4/x/copy.txt<CR>" },
    { expect = [[_G.here() == "deep3/x/saved.txt"]], note = "writeto keeps the buffer name" },
    {
      expect = [[_G.get("deep4/x/copy.txt"):find("saved", 1, true) ~= nil]],
      note = "writeto writes, parents included",
    },

    -- the create family resolves against the cwd, also from a file elsewhere
    { lua = [[_G.put("src/deep/nested/file.lua", "x"); _G.open("src/deep/nested/file.lua")]] },
    { keys = ":File touch sibling.lua<CR>", note = "cwd at the root, buffer deep down" },
    {
      expect = [[_G.exists("sibling.lua") and not _G.exists("src/deep/nested/sibling.lua")]],
      note = "touch: the cwd is the base",
    },

    -- mkdir: the parents of a buffer that has a name already
    { keys = ":enew<CR>" },
    { lua = [[vim.api.nvim_buf_set_name(0, _G.p("later/on/name.txt"))]] },
    { expect = [[vim.fn.isdirectory(_G.p("later/on")) == 0]] },
    { keys = ":File mkdir<CR>" },
    {
      expect = [[vim.fn.isdirectory(_G.p("later/on")) == 1]],
      note = "mkdir creates the buffer's parent dirs",
    },
  },
}
