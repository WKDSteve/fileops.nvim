-- TESTS/notify_spec.lua — util/notify.lua: the "[fileops] " wrapper and the
-- `report(ok, msg)` relay every binding funnels an op's result through.
--
-- Captured at `vim.notify`, not at the module: every consumer here binds
-- `notify.info`/`notify.report` at load time, so a module-level stub would
-- arrive too late. lib.nvim's notifier (which this module upgrades to when
-- lib.nvim is present, as it is in this suite) ends at `vim.notify` as well.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local notify = require("fileops.util.notify")

  -- lib.nvim is a hard runtime dependency of this plugin and the runner
  -- refuses to start without it, so the upgraded notifier is the path under
  -- test here; the plain-vim.notify fallback only exists for a lib.nvim-less
  -- install this suite cannot construct (the module resolves it once, at load).
  ok(notify.using_lib(), "using_lib: lib.nvim's notifier is in use")

  local levels = vim.log.levels

  local seen = H.notifications(function()
    notify.info("an info line")
    notify.warn("a warn line")
    notify.error("an error line")
    notify.debug("a debug line")
  end)

  eq(#seen, 4, "one notification per call")
  eq(seen[1].level, levels.INFO, "info is INFO level")
  eq(seen[2].level, levels.WARN, "warn is WARN level")
  eq(seen[3].level, levels.ERROR, "error is ERROR level")
  eq(seen[4].level, levels.DEBUG, "debug is DEBUG level")
  for i, line in ipairs({ "an info line", "a warn line", "an error line", "a debug line" }) do
    eq(seen[i].msg, "[fileops] " .. line, "message carries the [fileops] prefix: " .. line)
  end

  -- report: the one place that decides whether an op's (ok, msg) is surfaced
  -- and at which level. A successful op reports at INFO, a failed one at
  -- ERROR, and both pass their `ok` straight back so callers can chain on it.
  local relayed = H.notifications(function()
    eq(notify.report(true, "renamed a.txt"), true, "report passes a truthy ok through")
    eq(notify.report(false, "rename failed"), false, "report passes a falsy ok through")
  end)
  eq(#relayed, 2, "report emits exactly one notification per result")
  eq(relayed[1].level, levels.INFO, "report(true, msg) notifies at INFO")
  eq(relayed[2].level, levels.ERROR, "report(false, msg) notifies at ERROR")
  eq(relayed[1].msg, "[fileops] renamed a.txt", "report relays the op's own message verbatim")

  -- A nil message is the ops layer's way of saying "nothing to relay" (e.g.
  -- cycle.open_path's successful returns) — it must stay silent rather than
  -- notify "nil".
  local silent = H.notifications(function()
    eq(notify.report(true, nil), true, "report(true, nil) still returns ok")
    eq(notify.report(false, nil), false, "report(false, nil) still returns ok")
  end)
  eq(#silent, 0, "report stays silent when the op returned no message")
end

return function(H)
  H.run_preserved(spec)
end
