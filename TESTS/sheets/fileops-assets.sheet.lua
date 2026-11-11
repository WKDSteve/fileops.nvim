-- Live check: cascade-delete of orphaned assets with the real filetree.nvim refs engine and the real
-- dialog (task fileops.nvim/testblatt-bindings-checkliste; section 3a of
-- ALL/manual-test-checklists/fileops.md). filetree.nvim is a CI checkout beside this repo and on no
-- other sheet's runtimepath. The OS trash is stubbed (TESTS/sheets/_helpers.lua).
return {
  id = "fileops.assets",
  feature = "fileops.assets",
  title = "fileops.nvim: cascade-delete orphaned assets through filetree.nvim's refs engine",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  requires = {
    {
      lua = [[vim.fn.isdirectory(vim.env.FILETREE_NVIM_DIR
        or (vim.fs.dirname(vim.fn.getcwd()) .. "/filetree.nvim")) == 1]],
      reason = "filetree.nvim is not beside this repo",
    },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.veto = false
      require("fileops").setup({
        delete = {
          on_before_delete = function()
            if _G.veto then
              return false
            end
          end,
        },
      })
      _G.sandbox()
      function _G.reset()
        vim.cmd("silent! %bwipeout!")
        _G.put("post.md", "![p](assets/pic.png)\n![s](assets/shared.png)\n")
        _G.put("stays.md", "![s](assets/shared.png)\n")
        _G.put("assets/pic.png", "p")
        _G.put("assets/shared.png", "s")
        _G.open("stays.md")
        _G.open("post.md")
        _G.notes, _G.trashed = {}, {}
      end
      _G.reset()]],
      note = "a Markdown file, an asset only it links, an asset another file links too",
    },

    -- filetree.nvim not on the runtimepath: a plain delete
    { expect = [[not pcall(require, "filetree.refs")]], note = "not installed yet" },
    { keys = ":File delete<CR>" },
    { expect = [[not _G.exists("post.md") and not _G.dialog()]], note = "absent: no prompt" },
    { expect = [[_G.exists("assets/pic.png") and #_G.trashed == 1]], note = "absent: no cascade" },

    -- installed, feature off (the upstream default)
    {
      lua = [[vim.opt.rtp:append(vim.env.FILETREE_NVIM_DIR
        or (vim.fs.dirname(vim.env.FILEOPS_ROOT) .. "/filetree.nvim"))
      require("filetree.refs").setup({})
      _G.reset()]],
    },
    { keys = ":File delete<CR>" },
    { expect = [[not _G.exists("post.md") and not _G.dialog()]], note = "off: no prompt" },
    { expect = [[_G.exists("assets/pic.png") and #_G.trashed == 1]], note = "off: no cascade" },

    -- "ask"
    {
      lua = [[require("filetree.refs").setup({ outgoing_assets = { enabled = true, on_delete = "ask" } })
      _G.reset()]],
    },
    { keys = ":File delete<CR>" },
    { wait = "_G.dialog()", timeout = 4000, note = "ask: the second dialog" },
    {
      expect = [[_G.float_text():find("Also delete 1 orphaned asset(s)? pic.png", 1, true) ~= nil]],
      note = "ask: names the asset, and only the orphan",
    },
    {
      expect = [[_G.noted("still referenced elsewhere, left alone: shared.png")]],
      note = "reports",
    },
    { keys = "k", note = "Keep assets" },
    { expect = [[not _G.exists("post.md") and _G.exists("assets/pic.png")]], note = "Keep" },

    { lua = [[_G.reset()]] },
    { keys = ":File delete<CR>" },
    { wait = "_G.dialog()", timeout = 4000 },
    { keys = "d", note = "Delete assets" },
    { expect = [[not _G.exists("post.md") and not _G.exists("assets/pic.png")]], note = "Delete" },
    { expect = [[vim.tbl_contains(_G.trashed, "pic.png")]], note = "same delete.mode: the trash" },
    { expect = [[_G.exists("assets/shared.png")]], note = "the linked one stays" },

    -- after the primary confirm of a modified buffer; a cancelled one deletes no asset
    { lua = [[_G.reset(); vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved" })]] },
    { keys = ":File delete<CR>" },
    { wait = "_G.dialog()" },
    {
      expect = [[_G.float_text():find("unsaved changes", 1, true) ~= nil]],
      note = "primary first",
    },
    { keys = "<CR>", note = "Cancel has the focus" },
    { settle = 100 },
    {
      expect = [[_G.exists("post.md") and _G.exists("assets/pic.png")]],
      note = "cancelled: all stays",
    },
    { expect = "not _G.dialog()" },
    { keys = ":File delete<CR>" },
    { wait = "_G.dialog()" },
    { keys = "h<CR>", note = "Yes, delete" },
    {
      wait = [[_G.float_text():find("orphaned", 1, true) ~= nil]],
      timeout = 4000,
      note = "then this",
    },
    { keys = "d" },
    { expect = [[not _G.exists("post.md") and not _G.exists("assets/pic.png")]] },

    -- a veto: no asset goes either
    { lua = [[_G.reset(); _G.veto = true]] },
    { keys = ":File delete<CR>" },
    { wait = "_G.dialog()", timeout = 4000 },
    { keys = "d" },
    {
      expect = [[_G.exists("post.md") and _G.exists("assets/pic.png")]],
      note = "veto: nothing goes",
    },
    { lua = [[_G.veto = false]] },

    -- "auto": no prompt, an info line
    {
      lua = [[require("filetree.refs").setup({ outgoing_assets = { enabled = true, on_delete = "auto" } })
      _G.reset()]],
    },
    { keys = ":File delete<CR>" },
    { wait = [[not _G.exists("assets/pic.png")]], timeout = 4000, note = "auto deletes" },
    { expect = "not _G.dialog()", note = "auto: no prompt" },
    {
      expect = [[_G.noted("1 orphaned asset(s) will also be deleted: pic.png")]],
      note = "auto: says so",
    },
  },
}
