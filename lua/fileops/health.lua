---@module 'fileops.health'
---Reports fileops's runtime environment and optional-dependency status to `:checkhealth`.
local M = {}

---@internal
---@param msg string
local function ok(msg)
  vim.health.ok(msg)
end

---@internal
---@param msg string
---@param advice? string[]
local function warn(msg, advice)
  vim.health.warn(msg, advice)
end

---@internal
---@param msg string
local function start(msg)
  vim.health.start(msg)
end

---@internal
---@param msg string
---@param advice? string[]
local function err(msg, advice)
  vim.health.error(msg, advice)
end

---Run all fileops health checks.
function M.check()
  start("fileops")

  -- Neovim version
  if vim.fn.has("nvim-0.9") == 1 then
    ok("Neovim >= 0.9")
  else
    warn("Neovim 0.9+ recommended (vim.uv may not be available)", { "Upgrade Neovim to 0.9+" })
  end

  -- libuv (vim.uv or vim.loop)
  local uv = vim.uv or vim.loop
  if uv then
    ok("libuv available (" .. (vim.uv and "vim.uv" or "vim.loop") .. ")")
  else
    err("libuv not found; file I/O will fail")
  end

  -- ui.nvim (ui.kit): required by every interactive prompt fileops has no
  -- other UI for -- the missing-destination prompt, the modified-buffer
  -- confirm, and bulk rename (see docs/installation.md).
  if pcall(require, "ui.kit") then
    ok("ui.nvim detected (ui.kit prompts available)")
  else
    warn(
      "ui.nvim not found — the missing-destination prompt, the modified-buffer "
        .. "confirm and bulk rename will raise an error when triggered",
      { 'Install "WKDSteve/ui.nvim"' }
    )
  end

  -- config validation from the last setup() call (unknown keys, rejected values)
  local cfg_issues = require("fileops.config").issues()
  if #cfg_issues == 0 then
    ok("config: no unknown/invalid options from the last setup() call")
  else
    for _, issue in ipairs(cfg_issues) do
      warn("config: " .. issue)
    end
  end

  -- vim.fs.dir (used for directory listing)
  if vim.fs and type(vim.fs.dir) == "function" then
    ok("vim.fs.dir is available")
  else
    warn("vim.fs.dir is unavailable; :File next / :File prev will not work")
  end

  -- guard flag
  if vim.g.loaded_fileops then
    ok("plugin loaded (vim.g.loaded_fileops = " .. tostring(vim.g.loaded_fileops) .. ")")
  else
    warn("plugin guard not set — call require('fileops').setup() in your config")
  end

  -- treesitter (optional, not required)
  local has_ts = pcall(require, "nvim-treesitter")
  if has_ts then
    ok("nvim-treesitter present (optional)")
  else
    ok("nvim-treesitter not installed (not required)")
  end

  -- lib.nvim: required (:File command layer via lib.nvim.bindings.usercmd.composer,
  -- plus ops/file.lua's lib.nvim.cross.fs.mutate and ops/cycle.lua's
  -- lib.nvim.buffer.open_background — both already hard requires with no
  -- pcall, so this plugin has never actually run standalone). Only
  -- notify's own styling is a genuinely soft, cosmetic fallback.
  local has_composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  if has_composer then
    ok("lib.nvim detected (:File command layer available)")
  else
    err("lib.nvim not found — :File will fail to register", { 'Install "WKDSteve/lib.nvim"' })
  end
  if require("fileops.util.notify").using_lib() then
    ok("lib.nvim.notify in use (styled notifications)")
  else
    ok("lib.nvim.notify not in use — falling back to native vim.notify")
  end

  -- which-key (optional, groups the <leader>n / <leader>p prefixes)
  if pcall(require, "which-key") then
    ok("which-key detected (<leader>n / <leader>p grouped)")
  else
    ok("which-key not found — mappings still carry their own descriptions")
  end

  -- git executable (used by on_hold, and by git_aware when opted in)
  if vim.fn.executable("git") == 1 then
    ok("git executable found (required for on_hold; used by git_aware when enabled)")
  else
    warn(
      "git executable not found — on_hold will be a silent no-op, git_aware will fail if enabled",
      { "install git" }
    )
  end

  -- gitsigns.nvim (optional, on_hold prefers its inline hunk preview)
  if pcall(require, "gitsigns") then
    ok("gitsigns.nvim found (on_hold prefers its inline hunk preview)")
  else
    ok("gitsigns.nvim not found — on_hold falls back to previous-content preview")
  end

  -- The declared external tools (docs/install.json): a pointer to
  -- `:Lib deps show`, not a second report -- the checks above already say
  -- more per tool. Silent when lib.nvim.deps is absent (an older lib.nvim).
  local ok_deps, deps_health = pcall(require, "lib.nvim.deps.health")
  if ok_deps and type(deps_health.pointer_for) == "function" then
    start("fileops: declared tools (lib.nvim.deps)")
    deps_health.pointer_for("fileops.nvim")
  end

  -- Guarded by the same detection as above: the "lib.nvim not found" branch
  -- already issued its warning, so this must not go on to require() the
  -- exact module just reported missing — that would crash the check with an
  -- uncaught error instead of degrading to the report already given.
  if has_composer then
    require("lib.nvim.bindings.usercmd.composer").checkhealth("File")
  end
end

return M
