-- TESTS/run.lua — legacy runner of fileops.nvim, superseded by testing.nvim
-- (`bash scripts/test.sh`, see TESTS/README.md).
--
-- KEPT as the spec LIST for testing.nvim, which reads the `specs`
-- list below (it never executes this file). The order is NOT load-bearing any
-- more: no spec depends on another one having run first (health_menu_spec.lua
-- sets up what it asserts on itself). Keep the list in sync with the files on
-- disk (a listed-but-missing spec is a failing case).
--
-- Historical usage, from the repo root:
--   nvim -n -i NONE --headless -u NONE -c "set rtp+=." -c "luafile TESTS/run.lua" -c "qa!"
-- or:
--   nvim -n -i NONE --headless -u NONE -c "set rtp+=." -l TESTS/run.lua
--
-- Loads every *_spec.lua listed below, runs it against the shared harness,
-- prints a per-spec result, and exits non-zero on the first failing spec.

-- Resolved to an absolute path immediately: `debug.getinfo` reports the
-- source as it was passed to `luafile`/`-l` (relative when the runner is
-- invoked with a relative path, as the header above does), and a relative
-- `dir` breaks the moment any earlier spec changes Neovim's cwd (e.g.
-- usrcmds_spec.lua's own `:cd` coverage) before a later spec's `dofile`.
local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
dir = vim.fn.fnamemodify(dir, ":p")
local H = dofile(dir .. "harness.lua")

-- fileops.nvim depends on lib.nvim at runtime (ops/file.lua, ops/cycle.lua),
-- so the suite needs it on the runtimepath.
--
-- A sibling checkout wins over the plugin-manager copy on purpose: the
-- bootstrap clone under stdpath("data")/lazy is frequently older than the
-- working checkout, and testing against a stale lib.nvim gives misleading
-- failures. `$LIB_NVIM_PATH` overrides both (useful in CI).
local function add_lib_nvim()
  -- Built by appending, not as a literal: an unset $LIB_NVIM_PATH would put a
  -- nil at index 1 and `ipairs` would stop before checking anything.
  local candidates = {}
  if vim.env.LIB_NVIM_PATH then
    candidates[#candidates + 1] = vim.env.LIB_NVIM_PATH
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/../lib.nvim"
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/lib.nvim"

  for _, path in ipairs(candidates) do
    -- Normalize first: the sibling candidate contains a ".." segment and the
    -- stdpath one mixes separators on Windows; the runtimepath module searcher
    -- does not resolve either, so an unnormalized entry silently finds nothing.
    local norm = vim.fs.normalize(path)
    if vim.fn.isdirectory(norm .. "/lua/lib") == 1 then
      vim.opt.rtp:append(norm)
      -- rtp alone is not enough here: the runtimepath searcher does not pick
      -- up entries appended after startup. lib.nvim's own README prescribes
      -- registering it on package.path as well (the C require searcher is the
      -- fallback that always applies).
      package.path = table.concat({
        norm .. "/lua/?.lua",
        norm .. "/lua/?/init.lua",
        package.path,
      }, ";")
      return norm
    end
  end
  return nil
end

-- fileops's own modules, additionally registered on `package.path` by
-- absolute path.
--
-- `set rtp+=.` (the documented invocation, and the one CI runs) is a RELATIVE
-- runtimepath entry, resolved against the cwd at lookup time — so the first
-- spec that changes cwd breaks every `require("fileops.…")` that has not been
-- resolved yet, purely as a function of spec order. The absolute entry below
-- makes module lookup independent of that.
local function add_self()
  local root = vim.fs.normalize(vim.fn.fnamemodify(dir .. "..", ":p"))
  package.path = table.concat({
    root .. "/lua/?.lua",
    root .. "/lua/?/init.lua",
    package.path,
  }, ";")
end

add_self()

local lib_path = add_lib_nvim()
if not lib_path then
  print("FAIL  cannot locate lib.nvim (a runtime dependency of fileops.nvim).")
  print("      Set $LIB_NVIM_PATH, or check it out next to this repo.")
  os.exit(1)
end

local specs = {
  "config_spec.lua",
  "notify_spec.lua",
  "cycle_spec.lua",
  "cycle_edge_spec.lua",
  "file_spec.lua",
  "file_paths_spec.lua",
  "file_delete_spec.lua",
  "bulk_spec.lua",
  "bulk_edge_spec.lua",
  "git_spec.lua",
  "git_async_spec.lua",
  "usrcmds_spec.lua",
  "usrcmds_dispatch_spec.lua",
  "keymaps_spec.lua",
  "autocmds_spec.lua",
  "on_hold_preview_spec.lua",
  "init_api_spec.lua",
  "health_menu_spec.lua",
  "filetree_assets_spec.lua",
  "explorer_integration_spec.lua",
  "install_spec_spec.lua",
  "testing_config_spec.lua",
  "harness_spec.lua",
}

local failed = 0
local total = 0
for _, name in ipairs(specs) do
  local before = H.checks
  local run = dofile(dir .. name)
  local ok, err = pcall(run, H)
  local ran = H.checks - before
  total = total + ran
  if ok then
    print(("ok    %-32s %4d checks"):format(name, ran))
  else
    failed = failed + 1
    print(("FAIL  %-32s %4d checks\n      %s"):format(name, ran, tostring(err)))
  end
end

print(("\n%d spec(s), %d checks"):format(#specs, total))

if failed > 0 then
  print(("%d spec(s) failed"):format(failed))
  os.exit(1)
end

print("\nFILEOPS_TESTS_OK")
