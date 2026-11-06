-- Live check: a missing path argument opens the kit's prompt, a cancel does nothing, and the rename
-- family completes from the buffer's own directory (task fileops.nvim/testblatt-bindings-checkliste;
-- section 1 of ALL/manual-test-checklists/fileops.md).
local function asked(sub, answer, check)
  return {
    { input = ":File " .. sub .. "<CR>", note = ":File " .. sub .. " without a path" },
    { wait = "_G.prompting()", note = sub .. ": the prompt stands open" },
    { input = answer .. "<CR>" },
    { wait = check, note = sub .. ": the typed path is used" },
  }
end

local steps = {
  {
    lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
    require("fileops").setup({})
    _G.sandbox()
    _G.put("src/deep/file.lua", "x\n")
    _G.put("src/deep/neighbor.txt", "")
    _G.put("rootfile.txt", "")
    _G.open("src/deep/file.lua")]],
    note = "a file two levels below the cwd",
  },

  -- completion: <Tab> on the real command line, then the whole list
  { input = ":File rename <Tab><Tab>" },
  {
    wait = [[vim.fn.getcmdline():gsub("\\", "/"):find("src/deep/file.lua", 1, true) ~= nil]],
    note = "<Tab> offers the buffer's directory",
  },
  { input = "<C-c>" },
  { wait = [[vim.fn.mode() == "n"]] },
  {
    expect = [[vim.iter(vim.fn.getcompletion("File rename ", "cmdline")):any(function(c)
      return c:find("neighbor.txt", 1, true) ~= nil
    end)]],
    note = "a neighbour of the buffer is a candidate",
  },
  {
    expect = [[not vim.iter(vim.fn.getcompletion("File rename ", "cmdline")):any(function(c)
      return c:find("rootfile.txt", 1, true) ~= nil
    end)]],
    note = "a file of the cwd is not",
  },

  -- cancelling: <Esc> leaves everything as it was
  { input = ":File rename<CR>" },
  { wait = "_G.prompting()" },
  { expect = [[_G.float_text():find("file.lua", 1, true) ~= nil]], note = "prefilled name" },
  { input = "<Esc>" },
  { wait = [[vim.api.nvim_win_get_config(0).relative == ""]], note = "the prompt is gone" },
  { settle = 50 },
  { expect = [[_G.here() == "src/deep/file.lua" and _G.exists("src/deep/file.lua")]] },
  { expect = [[#_G.notes == 0]], note = "a cancel is silent" },

  { input = ":File touch<CR>" },
  { wait = "_G.prompting()" },
  { input = "<Esc>" },
  { wait = [[vim.api.nvim_win_get_config(0).relative == ""]] },
  { settle = 50 },
  { expect = [[#_G.notes == 0]], note = "a cancelled touch is silent too" },
}

local cases = {
  { "touch", "t.txt", [[_G.exists("t.txt")]] },
  { "copy", "c.lua", [[_G.exists("src/deep/c.lua")]] },
  { "duplicate", "d.lua", [[_G.here() == "src/deep/d.lua"]] },
  { "move", "m.lua", [[_G.here() == "src/deep/m.lua"]] },
  { "writeto", "wt.txt", [[_G.exists("wt.txt")]] },
  { "saveas", "sa.txt", [[_G.here() == "sa.txt"]] },
  { "write", "w.txt", [[_G.here() == "w.txt"]] },
  { "new", "n.txt", [[_G.here() == "n.txt"]] },
}
local list_c = cases
for i_c = 1, #list_c do
  local c = list_c[i_c]
  local list_step = asked(c[1], c[2], c[3])
  for i_step = 1, #list_step do
    local step = list_step[i_step]
    steps[#steps + 1] = step
  end
end

-- `rename` prefills the current name: a typed path replaces it (<C-u> empties the line).
steps[#steps + 1] = { lua = [[_G.open("rootfile.txt")]] }
steps[#steps + 1] = { input = ":File rename<CR>" }
steps[#steps + 1] = { wait = "_G.prompting()" }
steps[#steps + 1] = { input = "<C-u>r.txt<CR>" }
steps[#steps + 1] = { wait = [[_G.here() == "r.txt"]], note = "rename: the typed name is used" }

return {
  id = "fileops.prompts",
  title = "fileops.nvim: a missing path prompts, a cancel is silent, rename completes from the buffer",
  task = "fileops.nvim/testblatt-bindings-checkliste",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = steps,
}
