-- Live check: a destination that exists asks through the kit's real dialog, `!` does not (task
-- fileops.nvim/testblatt-bindings-checkliste; section 2 and the prose of section 6 of
-- ALL/manual-test-checklists/fileops.md).
local KEPT = [[_G.get("src.txt") == "source" and _G.get("dest.txt") == "old"]]

local function answers(sub, gone)
  return {
    { lua = [[_G.reset()]] },
    { keys = ":File " .. sub .. " dest.txt<CR>" },
    { wait = "_G.dialog()", note = sub .. ": the dialog asks" },
    {
      expect = [[_G.float_text():find("Yes, overwrite", 1, true)
        and _G.float_text():find("Cancel", 1, true)]],
      note = sub .. ": both buttons",
    },
    { keys = "<Esc>", note = sub .. ": <Esc>" },
    { expect = "not _G.dialog()" },
    { expect = KEPT, note = sub .. ": <Esc> changes nothing" },

    { keys = ":File " .. sub .. " dest.txt<CR>" },
    { wait = "_G.dialog()" },
    { keys = "<CR>", note = sub .. ": the Cancel button has the focus" },
    { expect = "not _G.dialog()" },
    { expect = KEPT, note = sub .. ": Cancel changes nothing" },
    { expect = [[#_G.notes == 0]], note = sub .. ": a decline is silent" },

    { keys = ":File " .. sub .. " dest.txt<CR>" },
    { wait = "_G.dialog()" },
    { keys = "h<CR>", note = sub .. ": the Yes button" },
    { expect = "not _G.dialog()" },
    { expect = [[_G.get("dest.txt") == "source"]], note = sub .. ": the source's content" },
    {
      expect = gone and [[not _G.exists("src.txt")]] or [[_G.exists("src.txt")]],
      note = sub .. ": the source",
    },

    { lua = [[_G.reset()]] },
    { keys = ":File! " .. sub .. " dest.txt<CR>" },
    { expect = "not _G.dialog()", note = sub .. "!: no question" },
    { expect = [[_G.get("dest.txt") == "source"]], note = sub .. "!: overwritten" },
  }
end

local steps = {
  {
    lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
    require("fileops").setup({})
    _G.sandbox()
    function _G.reset()
      vim.cmd("silent! %bwipeout!")
      _G.put("src.txt", "source")
      _G.put("dest.txt", "old")
      _G.open("src.txt")
      _G.notes = {}
    end]],
    note = "a source and a destination that exists",
  },
}
local cases = { { "rename", true }, { "move", true }, { "duplicate", false }, { "copy", false } }
local list_c = cases
for i_c = 1, #list_c do
  local c = list_c[i_c]
  local list_step = answers(c[1], c[2])
  for i_step = 1, #list_step do
    local step = list_step[i_step]
    steps[#steps + 1] = step
  end
end

-- What differs between the two copies: duplicate opens, copy stays.
steps[#steps + 1] = { lua = [[_G.reset(); os.remove(_G.p("dest.txt"))]] }
steps[#steps + 1] = { keys = ":File copy c1.txt<CR>" }
steps[#steps + 1] = { expect = [[_G.here() == "src.txt" and _G.get("c1.txt") == "source"]] }
steps[#steps + 1] = { keys = ":File duplicate c2.txt<CR>" }
steps[#steps + 1] = { expect = [[_G.here() == "c2.txt" and _G.get("c2.txt") == "source"]] }

return {
  id = "fileops.overwrite",
  feature = "fileops.overwrite",
  title = "fileops.nvim: rename, move, duplicate and copy onto an existing destination",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = steps,
}
