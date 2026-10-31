-- TESTS/cycle_spec.lua — ops/cycle.lua directory listing + navigate.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local cycle = require("fileops.ops.cycle")

  local dir = H.tmpdir()
  H.write_file(dir .. "a.lua", "-- a")
  H.write_file(dir .. "b.lua", "-- b")
  H.write_file(dir .. "c.lua", "-- c")
  H.write_file(dir .. ".hidden.lua", "-- hidden")

  ---@type FileOps.CycleConfig
  local opts = {
    open_target = "current",
    keep_focus = true,
    include_hidden = false,
    wrap = true,
    follow_symlinks = true,
    root = "buffer_dir",
    confirm_on_modified = false,
    case_insensitive = true,
  }

  H.edit(dir .. "a.lua")

  -- get_root_dir resolves the buffer's directory
  local root, err = cycle.get_root_dir(opts)
  ok(root ~= nil, "get_root_dir resolves a directory: " .. tostring(err))
  ---@cast root string

  -- next: a -> b
  ok(cycle.navigate(root, "next", opts, 1), "navigate next from a.lua succeeds")
  eq(vim.fn.expand("%:t"), "b.lua", "next moves a.lua -> b.lua")

  -- next: b -> c
  ok(cycle.navigate(root, "next", opts, 1), "navigate next from b.lua succeeds")
  eq(vim.fn.expand("%:t"), "c.lua", "next moves b.lua -> c.lua")

  -- next wraps: c -> a (hidden file excluded from the 3-file cycle)
  ok(cycle.navigate(root, "next", opts, 1), "navigate next from c.lua succeeds")
  eq(vim.fn.expand("%:t"), "a.lua", "next wraps c.lua -> a.lua")

  -- prev: a -> c (wrap backward)
  ok(cycle.navigate(root, "prev", opts, 1), "navigate prev from a.lua succeeds")
  eq(vim.fn.expand("%:t"), "c.lua", "prev wraps a.lua -> c.lua")

  -- include_hidden = true picks up the dot-file
  local opts_hidden = vim.tbl_extend("force", opts, { include_hidden = true })
  H.edit(dir .. "c.lua")
  ok(cycle.navigate(root, "next", opts_hidden, 1), "navigate next with include_hidden succeeds")
  eq(vim.fn.expand("%:t"), ".hidden.lua", "hidden file included when include_hidden = true")

  -- jump_edge: first/last jump directly, regardless of current position
  H.edit(dir .. "b.lua")
  ok(cycle.jump_edge(root, "first", opts), "jump_edge first succeeds")
  eq(vim.fn.expand("%:t"), "a.lua", "jump_edge first lands on a.lua")

  ok(cycle.jump_edge(root, "last", opts), "jump_edge last succeeds")
  eq(vim.fn.expand("%:t"), "c.lua", "jump_edge last lands on c.lua")

  -- open_current: reopens the same file it started on (no navigation)
  H.edit(dir .. "b.lua")
  ok(cycle.open_current(opts), "open_current succeeds")
  eq(vim.fn.expand("%:t"), "b.lua", "open_current stays on b.lua")

  -- pattern: glob filter narrows the cycle set
  H.write_file(dir .. "notes.md", "-- notes")
  local opts_md = vim.tbl_extend("force", opts, { pattern = "*.md", wrap = false })
  H.edit(dir .. "notes.md")
  local root_md = cycle.get_root_dir(opts_md)
  ---@cast root_md string
  local nav_ok, nav_msg = cycle.navigate(root_md, "next", opts_md, 1)
  ok(not nav_ok, "pattern *.md: only match in the dir, no wrap, no next: " .. tostring(nav_msg))

  H.edit(dir .. "a.lua")
  local opts_lua = vim.tbl_extend("force", opts, { pattern = "*.lua" })
  ok(cycle.navigate(root, "next", opts_lua, 1), "pattern *.lua: navigate next succeeds")
  eq(vim.fn.expand("%:t"), "b.lua", "pattern *.lua: notes.md excluded from the cycle")

  -- root = buffer_dir_recursive: picks up files in subdirectories too.
  -- Listing sorts by full path, so "sub/nested.lua" sorts after the
  -- top-level a/b/c.lua files — jump_edge("last") landing there proves
  -- the recursive walk found it.
  H.write_file(dir .. "sub/nested.lua", "-- nested")
  H.write_file(dir .. "sub/deeper/deepest.lua", "-- deepest")
  local opts_rec = vim.tbl_extend("force", opts, {
    root = "buffer_dir_recursive",
    pattern = "*.lua",
    wrap = true,
  })
  H.edit(dir .. "a.lua")
  local root_rec, root_rec_err = cycle.get_root_dir(opts_rec)
  ok(root_rec ~= nil, "get_root_dir (recursive) resolves a directory: " .. tostring(root_rec_err))
  ---@cast root_rec string
  ok(cycle.jump_edge(root_rec, "last", opts_rec), "recursive jump_edge last succeeds")
  eq(vim.fn.expand("%:t"), "nested.lua", "recursive listing descends into sub/ and sub/deeper/")

  -- non-recursive root = buffer_dir does NOT see into subdirectories
  local opts_nonrec = vim.tbl_extend("force", opts, { pattern = "*.lua", wrap = false })
  H.edit(dir .. "a.lua")
  local nr_ok, nr_msg = cycle.jump_edge(root, "last", opts_nonrec)
  ok(nr_ok, "non-recursive jump_edge last succeeds: " .. tostring(nr_msg))
  eq(vim.fn.expand("%:t"), "c.lua", "non-recursive listing stays on c.lua, ignoring sub/")

  -- regression: case_insensitive's comparator used to be
  -- `ci and (a:lower() < b:lower()) or (a < b)` -- the middle term is itself
  -- a boolean, so whenever it was false the `or` fell through to a
  -- case-SENSITIVE comparison instead of the intended `false`. Uppercase
  -- sorts before all lowercase in ASCII, so e.g. "Banana.txt" < "apple.txt"
  -- was true case-sensitively even though "banana" > "apple"
  -- case-insensitively -- both comp(apple,Banana) and comp(Banana,apple)
  -- came back true, an invalid comparator (ERR-60) that table.sort has no
  -- correct answer for.
  --
  -- A single next-hop assertion isn't enough to catch this: with only two
  -- files, wrapping from the last one always lands on the other one
  -- regardless of which specific order the (possibly wrong) sort produced.
  -- Three files, walked all the way around, distinguish the fully-correct
  -- case-insensitive cycle from any wrong permutation.
  local dir_ci = H.tmpdir()
  H.write_file(dir_ci .. "Banana.txt", "-- Banana")
  H.write_file(dir_ci .. "cherry.txt", "-- cherry")
  H.write_file(dir_ci .. "apple.txt", "-- apple")
  local opts_ci = vim.tbl_extend("force", opts, { pattern = "*.txt", root = "buffer_dir" })
  H.edit(dir_ci .. "apple.txt")
  local root_ci = cycle.get_root_dir(opts_ci)
  ---@cast root_ci string

  local visited = {}
  for _ = 1, 3 do
    ok(cycle.navigate(root_ci, "next", opts_ci, 1), "case_insensitive: navigate next succeeds")
    visited[#visited + 1] = vim.fn.expand("%:t")
  end
  eq(
    table.concat(visited, ","),
    "Banana.txt,cherry.txt,apple.txt",
    "case_insensitive: full cycle from apple.txt follows case-insensitive order"
  )
end

return function(H)
  H.run_preserved(spec)
end
