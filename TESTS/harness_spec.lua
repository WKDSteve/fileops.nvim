-- TESTS/harness_spec.lua — the harness's own restore (`H.stub`, `H.preserve`, `H.run_preserved`).
--
-- The suite shares one Neovim (`isolated = "none"`), so what a spec leaves behind lands on every
-- later spec. Each case runs a nested `H.run_preserved` and checks what is left after it.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local api = vim.api

  --- Run `body` through a nested `H.run_preserved`. A failure inside it (an assertion included)
  --- is raised again, unless `expect_error`: then the error is returned.
  ---@param body fun()
  ---@param expect_error boolean|nil
  ---@return string|nil
  local function nested(body, expect_error)
    local ran, err = pcall(H.run_preserved, function()
      body()
    end)
    if ran then
      return nil
    end
    if not expect_error then
      error(err, 0)
    end
    return tostring(err)
  end

  -- ── a stub survives no failure ────────────────────────────────────────────
  do
    local name = "fileops_harness_probe"
    package.loaded[name] = nil
    local err = nested(function()
      H.stub(name, { double = true })
      error("boom between stub and restore")
    end, true)
    ok(err and err:find("boom", 1, true), "the body's error is raised again")
    eq(package.loaded[name], nil, "a stub the body did not restore is undone after it raised")

    -- The inline restore still works and stays a no-op on the second call (from the unwind).
    local real = { real = true }
    package.loaded[name] = real
    nested(function()
      local restore = H.stub(name, { double = true })
      restore()
      local again = H.stub(name, { second = true })
      eq(package.loaded[name].second, true, "a second stub is in place")
      again()
      package.loaded[name] = real
    end)
    eq(package.loaded[name], real, "restored stubs are not restored a second time")
    package.loaded[name] = nil
  end

  -- ── lib.nvim's which-key watcher can register again after the restore ─────
  do
    local mod_name = "lib.nvim.bindings.keymap.which_key"
    local group = "lib.nvim.which_key.pending"
    local function watcher_count()
      local found, aus = pcall(api.nvim_get_autocmds, { group = group })
      return found and #aus or 0
    end
    local restore_wk = H.stub("which-key", nil)
    nested(function()
      local queued = require(mod_name).when_loaded(function() end)
      eq(queued, false, "without which-key the delivery is queued")
      ok(watcher_count() > 0, "the queued delivery installs the watcher")
    end)
    eq(watcher_count(), 0, "the restore removes the watcher")
    nested(function()
      require(mod_name).when_loaded(function() end)
      ok(watcher_count() > 0, "the next queued delivery installs the watcher again")
    end)
    restore_wk()
  end

  -- ── the spec's autocmds are gone before its windows and buffers ───────────
  do
    local fired = 0
    nested(function()
      vim.cmd("new")
      api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
        callback = function()
          fired = fired + 1
        end,
      })
    end)
    eq(fired, 0, "no autocmd of the spec fires while its window and buffer are wiped")
  end

  -- ── replaced keymaps come back exactly ────────────────────────────────────
  do
    local lhs = "<Plug>(fileops-harness-probe)"
    local function get(mode, l)
      for _, m in ipairs(api.nvim_get_keymap(mode)) do
        if m.lhs == l then
          return m
        end
      end
    end

    api.nvim_set_keymap("n", lhs, "x", { noremap = true })
    nested(function()
      api.nvim_set_keymap("n", lhs, "x", { noremap = false })
    end)
    eq((get("n", lhs) or {}).noremap, 1, "a map changed only in noremap is restored")

    api.nvim_set_keymap("n", lhs, "y", { script = true })
    nested(function()
      api.nvim_set_keymap("n", lhs, "z", {})
    end)
    eq((get("n", lhs) or {}).script, 1, "a <script> map comes back as a <script> map")
    pcall(api.nvim_del_keymap, "n", lhs)

    local multi = "<Plug>(fileops-harness-multi)"
    api.nvim_set_keymap("", multi, "x", { noremap = true })
    nested(function()
      api.nvim_set_keymap("n", multi, "y", { noremap = true })
    end)
    for _, mode in ipairs({ "n", "x", "o" }) do
      local m = get(mode, multi) or {}
      eq(m.mode, " ", "a :map over several modes comes back as one (" .. mode .. ")")
      eq(m.rhs, "x", "with its rhs (" .. mode .. ")")
    end
    pcall(api.nvim_del_keymap, "", multi)
  end
end

return function(H)
  H.run_preserved(spec)
end
