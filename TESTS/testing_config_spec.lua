-- TESTS/testing_config_spec.lua — the project's own `.testing.lua`.
--
-- The fs guard treats every `guard_allow.fs` entry as a ROOT: everything below it is let
-- through. An entry computed from `vim.fn.stdpath("data")` is harmless only while
-- scripts/test.sh points NVIM_APPNAME at a throwaway app dir; started any other way
-- (`nvim -l .../testing.lua run .`, `:Testing`, an agent) it silently allowed every write below
-- the developer's real nvim-data, `lazy/` included. This file pins the narrow form: the one
-- file neo-tree appends to, as a pattern, and nothing in the config that needs `vim`.

local function spec(H)
  local eq, ok = H.eq, H.ok

  -- This repo's root from THIS FILE's location (not the cwd: other specs `:cd`).
  local this_dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
  local repo_root = vim.fn.fnamemodify(this_dir, ":p:h:h")
  local path = repo_root .. "/.testing.lua"

  ok(vim.fn.filereadable(path) == 1, ".testing.lua exists at the repo root")

  -- Evaluated with an EMPTY environment, the way `:checkhealth testing` reads it: a `vim.` call in
  -- here raises ("attempt to index a nil value") and the health check can only say "not evaluated".
  local chunk, load_err = loadfile(path)
  ok(chunk ~= nil, ".testing.lua compiles: " .. tostring(load_err))
  local cfg
  if chunk then
    if setfenv then
      setfenv(chunk, {})
    end
    local ran, value = pcall(chunk)
    ok(ran, ".testing.lua evaluates without the editor API: " .. tostring(value))
    cfg = ran and value or nil
  end
  ok(type(cfg) == "table", ".testing.lua returns a table")
  cfg = cfg or {}

  local allow = type(cfg.guard_allow) == "table" and cfg.guard_allow or {}
  eq(#(allow.fs or {}), 0, "no directory is allowed as a write root (guard_allow.fs is empty)")

  local fs = type(cfg.guards) == "table" and cfg.guards.fs or nil
  ok(type(fs) == "table", "guards.fs is a table (mode plus the allowed log file)")
  fs = type(fs) == "table" and fs or {}
  eq(fs.mode, "error", "the fs guard still fails the run")
  eq(#(fs.allow or {}), 0, "guards.fs.allow lists no directory either")

  local data = vim.fs.normalize(vim.fn.stdpath("data"))
  ---@param p string
  ---@return boolean
  local function allowed(p)
    -- The guard compares the resolved, forward-slash key, folded to lower case on Windows/macOS.
    p = p:lower()
    for _, pat in ipairs(fs.allow_patterns or {}) do
      if p:find(pat) then
        return true
      end
    end
    return false
  end

  ok(#(fs.allow_patterns or {}) > 0, "the allowlist is a list of patterns")
  ok(allowed(data .. "/neo-tree.nvim.log"), "neo-tree's log file under the data dir is allowed")
  ok(not allowed(data .. "/lazy/some-plugin/lua/x.lua"), "…a plugin file below lazy/ is not")
  ok(not allowed(data .. "/neo-tree.nvim.log.bak"), "…nor a neighbour of the log file")
  ok(not allowed(data .. "/other.log"), "…nor any other file in the data dir")
  ok(not allowed(data), "…nor the data dir itself")
end

return function(H)
  H.run_preserved(spec)
end
