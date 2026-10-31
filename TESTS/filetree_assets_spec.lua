-- TESTS/filetree_assets_spec.lua — integrations/filetree_assets.lua: the
-- soft cascade-delete-assets seam `:File delete` uses. filetree.nvim is not
-- on this suite's runtimepath, so every scenario below stubs
-- `package.loaded["filetree.refs"]` directly rather than requiring the real
-- plugin — the point of this spec is "does :File delete drive the seam
-- correctly", not "does filetree.refs' own classifier work" (that lives in
-- filetree.nvim's own TESTS/refs/run.lua).

local function spec(H)
  local eq, ok = H.eq, H.ok

  -- `delete.mode = "permanent"` on purpose: the default is "trash" (a real
  -- OS trash/recycle bin call), and this spec's `:File delete` calls exist
  -- to exercise the cascade-delete-assets SEAM, not to shell out to
  -- PowerShell/osascript/gio on every run (slow, environment-dependent, and
  -- would leave test fixtures in the machine's real trash).
  require("fileops.config").setup({ delete = { mode = "permanent" } })

  -- Deliberately a plain `require` (no `package.loaded[...] = nil` first,
  -- unlike usrcmds_spec.lua): that spec runs before this one and changes
  -- cwd via `:cd` without restoring it, which — combined with this suite's
  -- `set rtp+=.` (a RELATIVE runtimepath entry) — breaks a fresh require
  -- from finding the module again. The `:File` command is already
  -- registered by usrcmds_spec.lua by the time this spec runs; `register()`
  -- on the already-loaded module just redefines it again (composer.verb is
  -- safe to call more than once), so nothing here needs a reload.
  require("fileops.bindings.usrcmds").register()

  local function cleanup_stubs()
    package.loaded["filetree.refs"] = nil
    package.loaded["ui.kit"] = nil
  end

  -- ── absent: filetree.nvim not installed -> :File delete unaffected ───────
  do
    local dir = H.tmpdir()
    local victim = dir .. "victim.md"
    H.write_file(victim, "# Victim")
    H.edit(victim)

    vim.cmd("File delete")

    eq(vim.fn.filereadable(victim), 0, "absent: victim deleted normally")
  end

  -- ── present, feature off: outgoing_assets must never even be called ──────
  do
    local dir = H.tmpdir()
    local victim = dir .. "victim.md"
    H.write_file(victim, "# Victim")
    H.edit(victim)

    package.loaded["filetree.refs"] = {
      outgoing_assets_mode = function()
        return "off"
      end,
      outgoing_assets = function()
        error("outgoing_assets must not be called when the mode is off")
      end,
    }

    vim.cmd("File delete")

    eq(vim.fn.filereadable(victim), 0, "off: victim still deleted normally")
    cleanup_stubs()
  end

  -- ── present, auto mode: orphaned asset cascade-deleted, no dialog ────────
  do
    local dir = H.tmpdir()
    local victim = dir .. "victim.md"
    local asset = dir .. "assets/shot.png"
    H.write_file(victim, "# Victim\n![shot](assets/shot.png)")
    H.write_file(asset, "x")
    H.edit(victim)

    local confirm_called = false
    package.loaded["ui.kit"] = {
      confirm = function()
        confirm_called = true
      end,
    }
    package.loaded["filetree.refs"] = {
      outgoing_assets_mode = function()
        return "auto"
      end,
      outgoing_assets = function(_path, _opts, cb)
        cb({ { resolved = asset, is_asset = true, still_referenced = false } })
      end,
    }

    vim.cmd("File delete")

    eq(vim.fn.filereadable(victim), 0, "auto: victim deleted")
    eq(vim.fn.filereadable(asset), 0, "auto: orphaned asset cascade-deleted")
    ok(not confirm_called, "auto: no confirm dialog shown")
    cleanup_stubs()
  end

  -- ── present, ask mode, user confirms: both deleted, dialog shown ─────────
  do
    local dir = H.tmpdir()
    local victim = dir .. "victim.md"
    local asset = dir .. "assets/shot.png"
    H.write_file(victim, "# Victim\n![shot](assets/shot.png)")
    H.write_file(asset, "x")
    H.edit(victim)

    local captured_question
    package.loaded["ui.kit"] = {
      confirm = function(opts)
        captured_question = opts.question
        opts.on_answer(opts.choices[1]) -- "Delete assets"
      end,
    }
    package.loaded["filetree.refs"] = {
      outgoing_assets_mode = function()
        return "ask"
      end,
      outgoing_assets = function(_path, _opts, cb)
        cb({ { resolved = asset, is_asset = true, still_referenced = false } })
      end,
    }

    vim.cmd("File delete")

    ok(
      captured_question ~= nil and captured_question:find("asset", 1, true) ~= nil,
      "ask+confirm: the dialog asked about the asset: " .. tostring(captured_question)
    )
    eq(vim.fn.filereadable(victim), 0, "ask+confirm: victim deleted")
    eq(vim.fn.filereadable(asset), 0, "ask+confirm: asset deleted after confirming")
    cleanup_stubs()
  end

  -- ── present, ask mode, user declines: victim gone, asset survives ────────
  do
    local dir = H.tmpdir()
    local victim = dir .. "victim.md"
    local asset = dir .. "assets/shot.png"
    H.write_file(victim, "# Victim\n![shot](assets/shot.png)")
    H.write_file(asset, "x")
    H.edit(victim)

    package.loaded["ui.kit"] = {
      confirm = function(opts)
        opts.on_answer(opts.choices[2]) -- "Keep assets"
      end,
    }
    package.loaded["filetree.refs"] = {
      outgoing_assets_mode = function()
        return "ask"
      end,
      outgoing_assets = function(_path, _opts, cb)
        cb({ { resolved = asset, is_asset = true, still_referenced = false } })
      end,
    }

    vim.cmd("File delete")

    eq(vim.fn.filereadable(victim), 0, "ask+decline: victim still deleted")
    eq(vim.fn.filereadable(asset), 1, "ask+decline: asset left alone")
    cleanup_stubs()
  end

  -- ── still_referenced asset: never offered, no dialog, survives ───────────
  do
    local dir = H.tmpdir()
    local victim = dir .. "victim.md"
    local asset = dir .. "assets/shared.png"
    H.write_file(victim, "# Victim\n![shared](assets/shared.png)")
    H.write_file(asset, "x")
    H.edit(victim)

    local confirm_called = false
    package.loaded["ui.kit"] = {
      confirm = function()
        confirm_called = true
      end,
    }
    package.loaded["filetree.refs"] = {
      outgoing_assets_mode = function()
        return "ask"
      end,
      outgoing_assets = function(_path, _opts, cb)
        cb({ { resolved = asset, is_asset = true, still_referenced = true } })
      end,
    }

    vim.cmd("File delete")

    ok(not confirm_called, "still_referenced: no dialog shown -- nothing qualified")
    eq(vim.fn.filereadable(victim), 0, "still_referenced: victim still deleted")
    eq(vim.fn.filereadable(asset), 1, "still_referenced: asset never touched")
    cleanup_stubs()
  end
end

return function(H)
  H.run_preserved(spec)
end
