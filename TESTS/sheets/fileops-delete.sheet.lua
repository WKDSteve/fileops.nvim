-- Live check: `:File delete` and the `<leader>dcf` key on a modified buffer, a clean buffer and with
-- the hook (task fileops.nvim/testblatt-bindings-checkliste, binding <leader>dcf; section 3 of
-- ALL/manual-test-checklists/fileops.md). The OS trash is stubbed (TESTS/sheets/_helpers.lua).
local Q = [[_G.float_text():find("Buffer has unsaved changes", 1, true) ~= nil]]
local KEPT = [[_G.get("gone.txt") == "disk" and _G.here() == "gone.txt" and _G.text() == "unsaved"]]
local NO_SCRATCH = [[vim.iter(vim.api.nvim_list_bufs()):all(function(b)
  return not vim.bo[b].buflisted or vim.api.nvim_buf_get_name(b) ~= ""
end)]]

local function both(lhs, what)
  return {
    { lua = [[_G.reset()]] },
    { keys = lhs },
    { wait = "_G.dialog()", note = what .. ": asks on a modified buffer" },
    { expect = Q, note = what .. ": the question" },
    { keys = "<Esc>" },
    { expect = "not _G.dialog()" },
    { expect = KEPT, note = what .. ": <Esc> leaves disk and buffer" },
    { keys = lhs },
    { wait = "_G.dialog()" },
    { keys = "<CR>", note = what .. ": Cancel has the focus" },
    { expect = "not _G.dialog()" },
    { expect = KEPT, note = what .. ": Cancel leaves disk and buffer" },
    { expect = "#_G.trashed == 0" },
    { keys = lhs },
    { wait = "_G.dialog()" },
    { keys = "h<CR>", note = what .. ": Yes, delete" },
    { expect = [[not _G.exists("gone.txt")]], note = what .. ": the file is gone" },
    { expect = [[_G.here() == "other.txt"]], note = what .. ": the window went to the other file" },
    { expect = [[_G.trashed[1] == "gone.txt"]], note = what .. ": through the trash, the default" },

    -- the hook vetoes, also after "Yes, delete"
    { lua = [[_G.reset(); _G.veto = true]] },
    { keys = lhs },
    { wait = "_G.dialog()" },
    { keys = "h<CR>" },
    { expect = KEPT, note = what .. ": the hook vetoes after Yes" },
    { expect = [[_G.noted("cancelled by on_before_delete")]] },
    { expect = "#_G.trashed == 0", note = what .. ": nothing reached the trash" },
    { lua = [[vim.cmd("silent! write"); _G.notes = {}]] },
    { keys = lhs, note = what .. ": a clean buffer never asks" },
    { expect = "not _G.dialog()" },
    { expect = [[_G.exists("gone.txt")]], note = what .. ": the hook vetoes a clean one too" },
    { lua = [[_G.veto = false]] },

    -- a clean buffer: no question, no empty buffer left behind
    { keys = lhs },
    { expect = "not _G.dialog()", note = what .. ": clean, no question" },
    {
      expect = [[not _G.exists("gone.txt") and _G.here() == "other.txt"]],
      note = what .. ": clean",
    },
    { expect = NO_SCRATCH, note = what .. ": no empty scratch buffer" },
  }
end

local steps = {
  {
    lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
    vim.g.mapleader = " "
    vim.o.timeoutlen = 50
    _G.veto = false
    require("fileops").setup({
      keymaps = { lhs = { delete_force = "<leader>dcF" } },
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
      _G.put("other.txt", "o")
      _G.put("gone.txt", "disk")
      _G.open("other.txt")
      _G.open("gone.txt")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
      _G.notes, _G.trashed = {}, {}
    end]],
    note = "two files, the one to delete has unsaved changes; delete_force bound for this sheet",
  },
}
local list_c = { { ":File delete<CR>", ":File delete" }, { " dcf", "<leader>dcf" } }
for i_c = 1, #list_c do
  local c = list_c[i_c]
  local list_step = both(c[1], c[2])
  for i_step = 1, #list_step do
    local step = list_step[i_step]
    steps[#steps + 1] = step
  end
end

-- The forced forms: no question on a modified buffer.
local list_lhs = { ":File! delete<CR>", " dcF" }
for i_lhs = 1, #list_lhs do
  local lhs = list_lhs[i_lhs]
  steps[#steps + 1] = { lua = [[_G.reset()]] }
  steps[#steps + 1] = { keys = lhs, note = lhs .. ": forced" }
  steps[#steps + 1] = { expect = "not _G.dialog()", note = lhs .. ": no question" }
  steps[#steps + 1] = { expect = [[not _G.exists("gone.txt") and _G.here() == "other.txt"]] }
end

-- The forced forms still ask the hook.
steps[#steps + 1] = { lua = [[_G.reset(); _G.veto = true]] }
steps[#steps + 1] = { keys = " dcF" }
steps[#steps + 1] = { expect = KEPT, note = "the hook vetoes the forced key" }
steps[#steps + 1] = { lua = [[_G.veto = false]] }

return {
  id = "fileops.delete",
  title = "fileops.nvim: :File delete and <leader>dcf, confirm, cancel, hook, forced",
  task = "fileops.nvim/testblatt-bindings-checkliste",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = steps,
  manual = {
    'delete.mode = "trash": the file really lands in the OS trash (the sheet stubs it): look there',
  },
}
