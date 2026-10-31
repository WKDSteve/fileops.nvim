-- TESTS/bulk_spec.lua — ops/bulk.lua: batch rename plan + execute.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local bulk = require("fileops.ops.bulk")

  local dir = H.tmpdir()
  H.write_file(dir .. "note_1.txt", "-- 1")
  H.write_file(dir .. "note_2.txt", "-- 2")
  H.write_file(dir .. "keep.md", "-- keep")
  H.write_file(dir .. ".note_3.txt", "-- hidden")

  -- plan: matches note_N.txt -> memo_N.txt, skips non-matching and hidden files
  local plan, perr = bulk.plan(dir, "^note_", "memo_")
  ok(plan ~= nil and perr == nil, "plan succeeds: " .. tostring(perr))
  eq(#plan, 2, "plan: matches exactly the two visible note_*.txt files")

  local names = {}
  for _, item in ipairs(plan) do
    names[vim.fn.fnamemodify(item.old, ":t")] = vim.fn.fnamemodify(item.new, ":t")
  end
  eq(names["note_1.txt"], "memo_1.txt", "plan: note_1.txt -> memo_1.txt")
  eq(names["note_2.txt"], "memo_2.txt", "plan: note_2.txt -> memo_2.txt")

  -- plan: include_hidden picks up the dot-file too
  local plan_hidden = bulk.plan(dir, "^%.?note_", "memo_", { include_hidden = true })
  eq(#plan_hidden, 3, "plan with include_hidden: also matches the hidden file")

  -- plan: no match anywhere -> empty plan, no error
  local empty_plan, empty_err = bulk.plan(dir, "^zzz_", "yyy_")
  eq(#empty_plan, 0, "plan: no matches -> empty plan")
  eq(empty_err, nil, "plan: no matches -> no error")

  -- execute: renames on disk and updates any open buffer at the old path
  local buf = H.edit(dir .. "note_1.txt")
  local renamed, exec_err = bulk.execute(plan, {})
  ok(exec_err == nil, "execute succeeds: " .. tostring(exec_err))
  eq(renamed, 2, "execute: renamed both planned files")
  eq(vim.fn.filereadable(dir .. "memo_1.txt"), 1, "execute: memo_1.txt now exists")
  eq(vim.fn.filereadable(dir .. "memo_2.txt"), 1, "execute: memo_2.txt now exists")
  eq(vim.fn.filereadable(dir .. "note_1.txt"), 0, "execute: note_1.txt no longer exists")
  eq(vim.fn.filereadable(dir .. "note_2.txt"), 0, "execute: note_2.txt no longer exists")
  eq(
    vim.api.nvim_buf_get_name(buf),
    vim.fn.fnamemodify(dir .. "memo_1.txt", ":p"),
    "execute: open buffer follows the rename"
  )

  -- execute: refuses to overwrite an existing destination without bang
  H.write_file(dir .. "a.log", "-- a")
  H.write_file(dir .. "b.log", "-- b (pre-existing target)")
  local conflict_plan = bulk.plan(dir, "^a%.log$", "b.log")
  eq(#conflict_plan, 1, "conflict plan has exactly one item")
  local conflict_renamed, conflict_err = bulk.execute(conflict_plan, {})
  eq(conflict_renamed, 0, "execute without bang: conflicting rename not applied")
  ok(conflict_err ~= nil, "execute without bang: reports the conflict")
  eq(vim.fn.filereadable(dir .. "a.log"), 1, "execute without bang: source file untouched")

  -- execute! overwrites
  local conflict_renamed2, conflict_err2 = bulk.execute(conflict_plan, { bang = true })
  ok(conflict_err2 == nil, "execute! succeeds: " .. tostring(conflict_err2))
  eq(conflict_renamed2, 1, "execute! overwrites the existing destination")
  eq(vim.fn.filereadable(dir .. "a.log"), 0, "execute!: source file gone")
end

return function(H)
  H.run_preserved(spec)
end
