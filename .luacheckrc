-- luacheck configuration for fileops.nvim
std = "lua51"
cache = true

-- Neovim injects `vim` as a read-only global.
read_globals = { "vim" }

-- Line length is handled by stylua, not luacheck.
max_line_length = false

ignore = {
  "212/_.*", -- unused argument whose name starts with underscore
  "212/self", -- unused self
  "122", -- setting a read-only field of a global (e.g. vim.*): common in Neovim
}

-- Test specs intentionally use partial config tables.
files["TESTS/**"] = {
  ignore = { "631", "211" },
}

-- The test sheets' spec is busted style on purpose (TESTS/sheets_spec.lua).
files["TESTS/sheets_spec.lua"] = {
  std = "+busted",
}
