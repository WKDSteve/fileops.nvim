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
  ci = {
    -- The GitHub workflow, generated: `testing init --workflow=public --force` writes .github/workflows/ci.yml from
    -- this (testing.nvim docs/WORKFLOW-CI.md); the step workflow-in-sync keeps the two together.
    workflow = {
      name = "fileops.nvim",
      layout = "hosted",
      -- the steps that depend on the platform: the windows and macOS legs run only these (file operations end to end:
      -- rename, trash, permissions differ per system)
      platform = { "suite", "conformance" },
      -- `testing ci land`: a check branch ci/** runs the hosted legs, main moves to a commit only once it is green there
      land = true,
      -- more checkouts below .deps/, not on the runtimepath of the specs
      checkouts = {
        {
          repo = "WKDSteve/filetree.nvim",
          ref = "ci-verified",
          why = "only the test sheet fileops.assets loads it (cascade-delete through its refs engine)",
        },
        {
          repo = "WKDSteve/gitsuite.nvim",
          -- gitsuite.nvim publishes no ci-verified: pinned to the commit of the old workflow; bump deliberately
          ref = "96e08aa0417fa12e891402871de76cba80923399",
          why = "only the test sheets fileops.gitsuite and fileops.on-hold-gitsuite load it (conflicts, blame)",
        },
        {
          repo = "nvim-neo-tree/neo-tree.nvim",
          ref = "162f9b953a692b559afe43e38d60afee81e8e79b",
          why = "only TESTS/explorer_integration_spec.lua loads it (explorer refresh against a real neo-tree)",
        },
        {
          repo = "nvim-tree/nvim-tree.lua",
          ref = "8d814495983e8db87d02d2f1da293f25b2fd1bdc",
          why = "only TESTS/explorer_integration_spec.lua loads it (explorer refresh against a real nvim-tree)",
        },
        {
          repo = "MunifTanjim/nui.nvim",
          ref = "10fc361835c856ba4233ef5ea135b919bf3dce97",
          why = "a hard dependency of neo-tree.nvim in TESTS/explorer_integration_spec.lua",
        },
        {
          repo = "nvim-lua/plenary.nvim",
          ref = "74b06c6c75e4eeb3108ec01852001636d85a932b",
          why = "a hard dependency of neo-tree.nvim in TESTS/explorer_integration_spec.lua",
        },
      },
      publish = {
        why = "hover.nvim checks out fileops.nvim at ci-verified (its test sheet hover.fileops-on-hold)",
      },
    },
    steps = {
      ["workflow-in-sync"] = { preset = "workflow-in-sync" },
    },
  },
}
