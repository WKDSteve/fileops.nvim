-- TESTS/explorer_integration_spec.lua — ops/file.lua's explorer-refresh
-- code path (`reload_explorers`/`refresh_explorers` in ops/file.lua) against
-- REAL neo-tree.nvim and nvim-tree.lua instances, not just the
-- `package.loaded[...]`-guarded no-op every other spec exercises.
--
-- Optional and skip-by-default: neither plugin is a runtime dependency of
-- fileops.nvim, and neither is expected on a contributor's machine. Resolved
-- the same way `run.lua` resolves lib.nvim — `$<NAME>_DIR`, then a sibling
-- checkout — so CI can opt in by checking them out next to this repo (see
-- .github/workflows/ci.yml's `explorer-integration` job) while a local run
-- with nothing checked out just prints `skip` and passes.

local function spec(H)
  local ok = H.ok

  -- This repo's own root, resolved from THIS FILE's location rather than
  -- `vim.fn.getcwd()` — usrcmds_spec.lua (runs earlier in run.lua's list)
  -- exercises `:File cd`, which changes Neovim's cwd for the rest of the
  -- session, same reason run.lua itself resolves its `dir` this way.
  local this_dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
  -- `this_dir` is `<repo>/TESTS/`: `:p` keeps the trailing slash, the first `:h` only drops it
  -- (leaving `<repo>/TESTS`), the second reaches `<repo>`.
  local repo_root = vim.fn.fnamemodify(this_dir, ":p:h:h")

  ---@internal
  ---@param dirname string  e.g. "neo-tree.nvim".
  ---@return string|nil
  local function resolve(dirname)
    local env = vim.env[dirname:upper():gsub("[.-]", "_") .. "_DIR"]
    if env and env ~= "" and vim.fn.isdirectory(env) == 1 then
      return vim.fs.normalize(env)
    end
    local sibling = vim.fs.normalize(repo_root .. "/../" .. dirname)
    if vim.fn.isdirectory(sibling) == 1 then
      return sibling
    end
    return nil
  end

  -- Checked and appended one at a time, not collected into a table literal
  -- first: `{resolve("neo-tree.nvim"), resolve("nvim-tree.lua"), ...}` puts a
  -- `nil` at index 1 whenever the first one is missing (the common case —
  -- nothing checked out), and `ipairs` over a table with a `nil` at index 1
  -- stops immediately without inspecting the rest, silently skipping the
  -- checks for every dependency after it.
  for _, dirname in ipairs({ "neo-tree.nvim", "nvim-tree.lua", "nui.nvim", "plenary.nvim" }) do
    local d = resolve(dirname)
    if not d then
      print(
        "skip  explorer_integration_spec.lua: neo-tree.nvim/nvim-tree.lua (+deps) not found beside this repo"
      )
      return
    end
    vim.opt.rtp:append(d)
  end

  local ok_neo, neo_err = pcall(function()
    require("neo-tree").setup({})
  end)
  ok(ok_neo, "neo-tree.setup succeeds: " .. tostring(neo_err))

  local ok_nt, nt_err = pcall(function()
    require("nvim-tree").setup({})
  end)
  ok(ok_nt, "nvim-tree.setup succeeds: " .. tostring(nt_err))

  local file = require("fileops.ops.file")
  local dir = H.tmpdir()
  local src = dir .. "probe.txt"

  -- touch/rename/delete all call `M.notify_change`, which — with
  -- `package.loaded["neo-tree"]`/`["nvim-tree"]` now genuinely set by the
  -- `setup()` calls above — takes the real `nt.tree.reload()` /
  -- `neo-tree.sources.manager.refresh("filesystem")` branch instead of the
  -- no-op every other spec exercises via the guard.
  local tok, tmsg = file.touch(src)
  ok(tok, "touch against real explorers: " .. tostring(tmsg))

  H.edit(src)
  local rok, rmsg = file.rename("probe_renamed.txt")
  ok(rok, "rename against real explorers: " .. tostring(rmsg))

  local dok, dmsg = file.delete_current({ force = true })
  ok(dok, "delete against real explorers: " .. tostring(dmsg))
end

return function(H)
  H.run_preserved(spec)
end
