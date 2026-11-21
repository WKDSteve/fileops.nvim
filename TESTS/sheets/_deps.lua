-- TESTS/sheets/_deps.lua -- where a test sheet finds a checkout only it loads (filetree.nvim, gitsuite.nvim). Not a
-- sheet (`testing.sheet` only reads *.sheet.lua) and free of side effects, so a sheet's `requires` may run it too:
--
--   dofile(vim.fn.getcwd() .. "/TESTS/sheets/_deps.lua")("filetree.nvim")   -- the path, or nil
--
-- The order of TESTS/minimal_init.lua: $<NAME>_DIR (decides alone when set), <root>/.deps/<name> (what the generated
-- CI workflow checks out), <root>/../<name> (a sibling checkout). <root> is $FILEOPS_ROOT (set by _helpers.lua, so a
-- step that left for the sandbox still finds it), else the cwd, which is the project root when the child starts.

---@param name string e.g. "filetree.nvim"
---@return string|nil
return function(name)
  local override = vim.env[(name:upper():gsub("[^%w]", "_")) .. "_DIR"]
  if override ~= nil and override ~= "" then
    return vim.fn.isdirectory(override) == 1 and vim.fs.normalize(override) or nil
  end
  local root = vim.env.FILEOPS_ROOT
  if root == nil or root == "" then
    root = vim.fn.getcwd()
  end
  root = vim.fs.normalize(root)
  for _, dir in ipairs({ root .. "/.deps/" .. name, vim.fs.dirname(root) .. "/" .. name }) do
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return nil
end
