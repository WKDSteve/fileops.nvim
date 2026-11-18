-- Feature sheet: `:File delete` with the default `delete.mode = "trash"` hands the file to the OS trash through
-- lib.nvim's trash (PowerShell's recycle bin on Windows, `gio trash` on Linux). The trash programs are recording
-- stand-ins (`fakes`): the sheet proves what is called, never touches the real trash. On macOS the call goes through
-- a login shell whose PATH puts the real osascript first, so there the helpers' stub stays.
local CALLED = [[(function()
  local fakes = require("testing.fake_programs")
  if vim.fn.has("mac") == 1 then
    return _G.trashed[1] == "gone.txt"
  end
  if vim.fn.has("win32") == 1 then
    local calls = fakes.read(vim.env.TESTING_FAKES, "powershell")
    local argv = calls[1] and table.concat(calls[1].argv, " ") or ""
    return #calls == 1 and argv:find("SendToRecycleBin", 1, true) ~= nil and argv:find("gone.txt", 1, true) ~= nil
  end
  local calls = fakes.read(vim.env.TESTING_FAKES, "gio")
  return #calls == 1 and calls[1].argv[1] == "trash" and calls[1].argv[#calls[1].argv]:find("gone.txt$") ~= nil
end)()]]

return {
  id = "fileops.trash",
  feature = "fileops.delete",
  title = "fileops.nvim: :File delete hands the file to the OS trash program",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  fakes = { "powershell", "gio" },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      if vim.fn.has("mac") == 0 then
        package.loaded["lib.nvim.fs.trash"] = nil
      end
      require("fileops").setup({})
      _G.sandbox()
      _G.put("other.txt", "o")
      _G.put("gone.txt", "g")]],
      note = "the real lib.nvim trash (stand-ins for its programs); two files",
    },
    { keys = ":edit other.txt<CR>" },
    { keys = ":edit gone.txt<CR>" },
    { keys = ":File delete<CR>", note = "a clean buffer: no question" },
    { expect = [[_G.noted("trashed gone.txt")]], note = "the result message" },
    { expect = CALLED, note = "the trash program got the file" },
    { expect = [[_G.here() == "other.txt"]], note = "the window went to the other file" },
  },
  manual = { "the file really lands in the OS trash (the sheet records the call only): look there" },
}
