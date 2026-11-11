-- Live check: the eight cycle keys, each with its own target, and the keys that stay unbound (task
-- fileops.nvim/testblatt-bindings-checkliste, the eight <leader> bindings of the fileops section;
-- section 5 of ALL/manual-test-checklists/fileops.md). The real `cycle.open_target = "current"` must
-- not change what the keys do.
local function key(lhs, check, note)
  return {
    { lua = [[_G.start()]] },
    { keys = lhs, note = note },
    { wait = check, note = note },
  }
end

local steps = {
  {
    lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
    vim.g.mapleader = " "
    vim.o.timeoutlen = 50
    require("fileops").setup({ cycle = { open_target = "current" } })
    _G.sandbox()
    local list_f = { "a.lua", "b.lua", "c.lua" }
    for i_f = 1, #list_f do
      local f = list_f[i_f]
      _G.put(f, f)
    end
    function _G.start()
      vim.cmd("silent! only")
      vim.cmd("silent! %bwipeout!")
      _G.open("b.lua")
    end]],
    note = "three files; every key starts from the middle one",
  },
}

local bg_c = [[_G.here() == "b.lua" and _G.listed("c.lua") and _G.wins() == 1]]
local bg_a = [[_G.here() == "b.lua" and _G.listed("a.lua") and _G.wins() == 1]]
local vs_c = [[_G.wins() == 2 and _G.listed("c.lua") and _G.here() == "b.lua"]]
local vs_a = [[_G.wins() == 2 and _G.listed("a.lua") and _G.here() == "b.lua"]]
local cases = {
  { " nf", [[_G.here() == "c.lua" and not _G.listed("b.lua")]], "<leader>nf: replace" },
  { " pf", [[_G.here() == "a.lua" and not _G.listed("b.lua")]], "<leader>pf: replace" },
  { " nfn", [[_G.here() == "c.lua" and _G.listed("b.lua")]], "<leader>nfn: stays listed" },
  { " pfn", [[_G.here() == "a.lua" and _G.listed("b.lua")]], "<leader>pfn: stays listed" },
  { " nF", bg_c, "<leader>nF: background" },
  { " pF", bg_a, "<leader>pF: background" },
  { " NF", vs_c, "<leader>NF: vsplit" },
  { " PF", vs_a, "<leader>PF: vsplit" },
}
local list_c = cases
for i_c = 1, #list_c do
  local c = list_c[i_c]
  local list_step = key(c[1], c[2], c[3])
  for i_step = 1, #list_step do
    local step = list_step[i_step]
    steps[#steps + 1] = step
  end
end

-- A count works as on the command.
steps[#steps + 1] = { lua = [[_G.start(); _G.open("a.lua")]] }
steps[#steps + 1] = { keys = "2 nfn", note = "2<leader>nfn" }
steps[#steps + 1] = { wait = [[_G.here() == "c.lua"]], note = "the count skips" }

-- Nothing else is bound: the plugin ships these possible, not claimed.
steps[#steps + 1] = {
  expect = [[#vim.iter(vim.api.nvim_get_keymap("n")):filter(function(m)
    return (m.desc or ""):find("fileops", 1, true) ~= nil
  end):totable() == 9]],
  note = "exactly nine fileops keys: the eight cycle keys and <leader>dcf",
}
local unbound = {
  "<leader>nfg",
  "<leader>pfg",
  "<leader>dcF",
  "<leader>fp",
  "<leader>fd",
  "<leader>fi",
  "<leader>fl",
  "<leader>fR",
}
local list_lhs = unbound
for i_lhs = 1, #list_lhs do
  local lhs = list_lhs[i_lhs]
  steps[#steps + 1] = { expect = ([[vim.fn.maparg(%q, "n") == ""]]):format(lhs), note = lhs }
end

return {
  id = "fileops.cycle-keys",
  feature = "fileops.cycle",
  title = "fileops.nvim: the eight cycle keys, each with its own target",
  task = "fileops.nvim/manual-checklist-run",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = steps,
  manual = {
    "The which-key popup on <leader>n and <leader>p shows two groups, next file and prev file",
  },
}
