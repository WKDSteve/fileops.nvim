-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "fileops",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = { ["TESTS/sheets_spec.lua"] = "busted", ["*"] = "h" },
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  deps = { "lib.nvim", "ui.nvim" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file
  -- (nothing leaks from one file into the next).
  isolated = "none",
  -- Guards (docs/GUARDS.md of testing.nvim). All are clean on this suite and therefore "error": a new
  -- finding turns the run red.
  -- sheets_spec.lua runs every test sheet in a child editor of its own: far more than the default 10 s and 60 s
  -- on a machine under load.
  timeouts = { case_ms = 30000, file_ms = 300000 },
  guards = {
    fs = {
      mode = "error",
      -- neo-tree.nvim (explorer_integration_spec) appends its log to stdpath("data"). Exactly that one file
      -- is let through, as a pattern: no directory root (a root under stdpath("data") would also wave
      -- through writes into the developer's real nvim-data, `lazy/` included, whenever the suite is not
      -- started by scripts/test.sh with its throwaway NVIM_APPNAME), and no code evaluated in this file.
      allow_patterns = { "/neo%-tree%.nvim%.log$" },
    },
    prompt = "error",
    scheduled_error = "error",
    deprecation = "error",
    process_net = "error",
    -- "error": the suite shares one editor (isolated = "none") and leaves no state behind. Every spec runs
    -- through H.run_preserved (TESTS/harness.lua), which wipes the buffers, windows, tab pages, autocmds,
    -- user commands and keymaps it created, restores replaced keymaps, the working directory and
    -- vim.g.loaded_fileops. Loaded modules stay (info only). The specs are order independent (--shuffle).
    state = "error",
  },
  -- What the specs may start on purpose.
  guard_allow = {
    spawn = {
      -- The specs build tmp git repositories (init/commit/mv/rm/blame) to test the git-aware file ops.
      "git",
      -- The Windows recycle-bin delete runs a PowerShell one-liner (Microsoft.VisualBasic DeleteFile).
      "powershell",
      -- The Linux/macOS trash delete goes through `sh -lc "gio trash ..."` / `sh -lc "osascript ..."`
      -- (lib.nvim fs.trash); file_spec and explorer_integration_spec delete a tmp file that way.
      "sh",
      -- Deliberate negative probe: git_spec/autocmds_spec aim the git probe at a command that does not
      -- exist to prove the failure path stays silent.
      "fileops-no-such-git-executable",
      -- sheets_spec.lua: every test sheet (TESTS/sheets/) runs in a child editor.
      "nvim",
    },
  },
  -- The runner counts which commands, keymaps and autocommands the specs exercise (docs/SURFACE.md of testing.nvim);
  -- `scripts/test.sh surface` compares that with surface.baseline.json (a regression gate, not a percentage).
  surface = { track = true },
  -- gated: a failed conformance check makes `scripts/test.sh conformance` exit 1 (docs/CONFORMANCE.md of testing.nvim)
  conformance = { gate = true },
}
