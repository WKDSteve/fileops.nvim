-- TESTS/explorer_registry_spec.lua — ops/file.lua reloads file explorers
-- through an adapter registry (`register_explorer`), not an if per plugin.
-- Uses fake explorers keyed on `package.loaded`, so no real plugin is needed.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local file = require("fileops.ops.file")

  ok(type(file.register_explorer) == "function", "register_explorer exists")
  local names = file.explorers()
  ok(
    vim.tbl_contains(names, "nvim-tree") and vim.tbl_contains(names, "neo-tree"),
    "built-in adapters registered"
  )

  local key = "fileops_fake_explorer_mod"
  local calls = 0
  file.register_explorer({
    name = "fake",
    module = key,
    reload = function()
      calls = calls + 1
    end,
  })
  ok(vim.tbl_contains(file.explorers(), "fake"), "new adapter listed")

  -- Not loaded: skipped.
  file.notify_change("touch", "/tmp/x")
  eq(calls, 0, "adapter whose module is not loaded is skipped")

  -- Loaded: reloaded on a change; `refresh_explorers = false` suppresses it.
  package.loaded[key] = true
  file.notify_change("touch", "/tmp/x")
  eq(calls, 1, "loaded adapter reloads once per change")
  file.notify_change("touch", "/tmp/x", { refresh_explorers = false })
  eq(calls, 1, "refresh_explorers = false skips adapters")

  -- Same name replaces rather than duplicates; a raising adapter does not break the op.
  local before = #file.explorers()
  file.register_explorer({
    name = "fake",
    module = key,
    reload = function()
      error("boom")
    end,
  })
  eq(#file.explorers(), before, "same name replaces the adapter")
  local good = pcall(file.notify_change, "touch", "/tmp/x")
  ok(good, "a failing adapter is swallowed")

  package.loaded[key] = nil
end

return function(H)
  H.run_preserved(spec)
end
