-- TESTS/install_spec_spec.lua — fileops' own docs/install.json.
--
-- This file is data, and data is where a typo goes unnoticed: nothing in the
-- plugin requires it, no `luacheck` run reads it, and a broken entry surfaces
-- only as a tool quietly missing from `:Lib deps show fileops.nvim`. A tool
-- that is simply absent from a report looks exactly like a tool nobody
-- declared.
--
-- So: parse the real file with the real parser, insist it validates
-- completely, and pin what it declares against what the plugin actually uses.

local function spec(H)
  local eq, ok = H.eq, H.ok

  local deps_spec = require("lib.nvim.deps.spec")

  local root = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") .. "..")
  local result, err = deps_spec.load(root .. "/docs/install.json")
  ok(result ~= nil, "docs/install.json is readable: " .. tostring(err))
  ---@cast result -nil

  -- Zero, not "few": a rejected entry is silently dropped from `tools`, so a
  -- partial parse is indistinguishable from a shorter file.
  eq(#result.errors, 0, "docs/install.json validates with no errors")

  eq(#result.tools, 1, "declares exactly one tool")
  local git = result.tools[1]
  eq(git.bin, "git", "the one tool is git")
  -- Every filesystem operation goes through libuv; git backs two opt-in
  -- features only, so it must never read as required.
  eq(git.required, false, "git is optional")
  ok(git.pkg.apt and git.pkg.brew and git.pkg.winget, "git maps to apt, brew and winget")

  -- The declaration is about the default `git_cmd`. If that default ever
  -- moves off `git`, the declaration has to move with it.
  local defaults = require("fileops.config.DEFAULTS")
  eq(defaults.on_hold.git_cmd, "git", "the declared git is the default on_hold.git_cmd")
  eq(defaults.git_aware.git_cmd, "git", "the declared git is the default git_aware.git_cmd")
end

return function(H)
  H.run_preserved(spec)
end
