-- Feature sheet: with `git_aware` on (and `warn_only = false`), `:File rename` of a tracked file goes through
-- `git mv`, `:File delete` (permanent) through `git rm`, `:File duplicate` notes that the source is tracked, and an
-- untracked file is left to the plain file operations. git runs for real in a throwaway repository.
local STATUS = [[vim.trim(_G.git("status", "--porcelain").stdout)]]

return {
  id = "fileops.git-aware",
  feature = "fileops.git-aware",
  title = "fileops.nvim: git_aware renames through git mv and deletes through git rm",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      require("fileops").setup({
        git_aware = { enable = true, warn_only = false },
        delete = { mode = "permanent" },
      })
      _G.sandbox()
      _G.repo({ ["a.txt"] = "a\n", ["c.txt"] = "c\n" })]],
      note = "git_aware with git mv/git rm; a repository with two committed files",
    },

    -- rename a tracked file: git mv, the index knows the rename
    { keys = ":edit a.txt<CR>" },
    { keys = ":File rename b.txt<CR>" },
    { expect = [[_G.here() == "b.txt"]], note = "the buffer follows" },
    {
      expect = [[_G.noted("renamed a.txt → b.txt (git mv)")]],
      note = "the message names git mv",
    },
    { expect = STATUS .. [[ == "R  a.txt -> b.txt"]], note = "staged as a rename" },

    -- duplicate a tracked file: a plain copy, the message says the source is tracked
    { keys = ":File duplicate b2.txt<CR>" },
    { expect = [[_G.exists("b2.txt")]] },
    { expect = [[_G.noted("(source is git-tracked)")]], note = "the note about the source" },

    -- delete a tracked file for good: git rm, gone from the index too
    { keys = ":edit c.txt<CR>" },
    { keys = ":File delete<CR>", note = "a clean buffer: no question" },
    { expect = [[not _G.exists("c.txt")]], note = "the file is gone" },
    { expect = [[_G.noted("deleted c.txt (git rm)")]], note = "the message names git rm" },
    { expect = [[_G.git("status", "--porcelain", "--", "c.txt").stdout:find("^D  c.txt") ~= nil]] },

    -- an untracked file: no git in the message
    { lua = [[_G.put("u.txt", "u"); _G.notes = {}]] },
    { keys = ":edit u.txt<CR>" },
    { keys = ":File rename v.txt<CR>" },
    { expect = [[_G.exists("v.txt") and not _G.exists("u.txt")]] },
    {
      expect = [[_G.noted("renamed u.txt → v.txt") and not _G.noted("git")]],
      note = "plain rename",
    },
  },
}
