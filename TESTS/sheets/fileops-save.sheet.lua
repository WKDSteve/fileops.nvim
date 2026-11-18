-- Live check: `:File save` on a [No Name] buffer asks for the name and then the folder through the
-- kit's real prompt, chooser and dialog, instead of `:write`'s E32 (task
-- fileops.nvim/no-name-buffer-schliessen-und-speichern). Rows of the chooser: 1 the cwd
-- (preselected), 2 "Enter path manually…", 3 "Cancel", then the subfolders sorted.
-- A key that leads into a typed prompt goes in as `input`: `keys` feeds with `x`, which ends Insert mode again.

local CHOOSER = [[require("lib.nvim.ui.kit.chooser").is_open()]]
local CLOSED = [[vim.api.nvim_win_get_config(0).relative == "" and not ]] .. CHOOSER

---A fresh [No Name] buffer holding `text`, notifications cleared, then `:File save` and `name`.
---@param text string
---@param name string
---@return table[]
local function save_new(text, name)
  return {
    { keys = ":enew!<CR>" },
    {
      lua = ([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { %q })
      _G.notes = {}]]):format(text),
    },
    { input = ":File save<CR>" },
    { wait = "_G.prompting()", note = name .. ": the name prompt stands open" },
    { input = name .. "<CR>" },
  }
end

local steps = {
  {
    lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
    require("fileops").setup({})
    _G.sandbox()
    _G.put("docs/notes/keep.txt", "")
    _G.put(".hidden/keep.txt", "")]],
    note = "a cwd with docs/, docs/notes/ and a dot folder",
  },
}

local function add(list)
  -- a sheet is read with an empty environment: no `ipairs`
  for i = 1, #list do
    steps[#steps + 1] = list[i]
  end
end

-- 1. the cwd row is preselected: <CR> right away saves in the cwd
add(save_new("one", "a.md"))
add({
  { wait = CHOOSER, note = "the folder chooser opens after the name" },
  {
    expect = [[_G.float_text():find("Enter path manually", 1, true)
      and _G.float_text():find("docs/notes/", 1, true)]],
    note = "it lists the manual path and the subfolders",
  },
  { expect = [[not _G.float_text():find(".hidden", 1, true)]], note = "no dot folders" },
  { keys = "<CR>", note = "<CR> on the preselected row" },
  { wait = [[vim.trim(_G.get("a.md") or "") == "one"]], note = "the cwd row saves in the cwd" },
  {
    expect = [[_G.here() == "a.md" and not vim.bo.modified]],
    note = "the buffer is named after the file and no longer modified",
  },
})

-- 2. a subfolder: row 5 is docs/notes/
add(save_new("two", "b.md"))
add({
  { wait = CHOOSER },
  { keys = "jjjj<CR>", note = "down to docs/notes/" },
  {
    wait = [[vim.trim(_G.get("docs/notes/b.md") or "") == "two"]],
    note = "saved in the picked folder",
  },
  { expect = [[_G.here() == "docs/notes/b.md"]] },
})

-- 3. "Enter path manually…": prefilled with <cwd>/<name>, the typed path wins
add(save_new("three", "c.md"))
add({
  { wait = CHOOSER },
  { input = "j<CR>", note = "the manual-path row" },
  {
    wait = "_G.prompting()",
    note = "a path prompt opens, in Insert mode",
  },
  { expect = [[_G.float_text():find("c.md", 1, true) ~= nil]], note = "prefilled with the name" },
  { input = "<C-u>deep/er/c.md<CR>" },
  {
    wait = [[vim.trim(_G.get("deep/er/c.md") or "") == "three"]],
    note = "written there, parents created",
  },
})

-- 4. a name with a folder in it skips the chooser
add(save_new("four", "docs/d.md"))
add({
  {
    wait = [[vim.trim(_G.get("docs/d.md") or "") == "four"]],
    note = "a name with a folder: saved directly",
  },
  { expect = "not " .. CHOOSER, note = "no folder chooser" },
})

-- 5. cancelling: the Cancel row, <Esc> in the chooser, <Esc> at the name -- silent, nothing written
add(save_new("five", "e.md"))
add({
  { wait = CHOOSER },
  { keys = "jj<CR>", note = "the Cancel row" },
  { wait = CLOSED },
})
add(save_new("five", "e.md"))
add({
  { wait = CHOOSER },
  { keys = "<Esc>", note = "<Esc> in the chooser" },
  { wait = CLOSED },
  { settle = 50 },
  {
    expect = [[not _G.exists("e.md") and #_G.notes == 0]],
    note = "both cancels: nothing written, nothing said",
  },
  {
    expect = [[vim.api.nvim_buf_get_name(0) == "" and vim.bo.modified]],
    note = "the buffer stays unnamed and keeps its text",
  },
  { input = ":File save<CR>" },
  { wait = "_G.prompting()" },
  { input = "<Esc>", note = "<Esc> at the name" },
  { wait = CLOSED },
  { settle = 50 },
  { expect = [[#_G.notes == 0 and vim.bo.modified]], note = "silent, the text is kept" },
})

-- 6. an existing file: the dialog asks, Cancel has the focus
add({ { lua = [[_G.put("f.md", "old")]] } })
add(save_new("new", "f.md"))
add({
  { wait = CHOOSER },
  { keys = "<CR>" },
  { wait = "_G.dialog()", note = "an existing file: the dialog asks" },
  {
    expect = [[_G.float_text():find("Overwrite", 1, true) and _G.float_text():find("Cancel", 1, true)]],
    note = "both buttons",
  },
  { keys = "<CR>", note = "Cancel has the focus" },
  { expect = "not _G.dialog()" },
  { expect = [[vim.trim(_G.get("f.md") or "") == "old"]], note = "Cancel keeps the file" },
  { input = ":File save<CR>" },
  { wait = "_G.prompting()" },
  { input = "f.md<CR>" },
  { wait = CHOOSER },
  { keys = "<CR>" },
  { wait = "_G.dialog()" },
  { keys = "l<CR>", note = "the Overwrite button" },
  { wait = [[vim.trim(_G.get("f.md") or "") == "new"]], note = "Overwrite replaces it" },
})

-- 7. a named buffer: `:File save` is a plain write, no prompt
add({
  {
    lua = [[_G.put("g.md", "x")
  _G.open("g.md")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "seven" })]],
  },
  { input = ":File save<CR>" },
  {
    wait = [[_G.get("g.md") == "seven\n" or _G.get("g.md") == "seven\r\n"]],
    note = "named: written",
  },
  { expect = [[not _G.prompting() and not ]] .. CHOOSER, note = "named: no prompt" },
})

return {
  id = "fileops.save",
  feature = "fileops.save",
  title = "fileops.nvim: :File save on a [No Name] buffer asks for the name and the folder below the cwd",
  task = "fileops.nvim/no-name-buffer-schliessen-und-speichern",
  engine = "rpc",
  sizes = { { rows = 30, cols = 90 } },
  steps = steps,
}
