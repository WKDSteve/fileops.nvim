-- TESTS/file_paths_spec.lua — ops/file.lua's path resolution and the
-- create/name/write half of the module: `ensure_parent`, `edit_new`,
-- `save_as`, `write_to`, `mk_parent`, plus the path shapes a file-operations
-- plugin has to survive on Windows (drive letters, mixed separators, spaces,
-- `%`/`#`/glob characters in a file name).
--
-- Every fixture lives under `vim.fn.tempname()`; nothing here writes outside
-- it, and no test ever operates on the repo itself.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local file = require("fileops.ops.file")
  local fn = vim.fn

  local dir = H.tmpdir()

  -- ── ensure_parent ────────────────────────────────────────────────────────
  do
    local nested = dir .. "deep/deeper/leaf.txt"
    eq(fn.isdirectory(dir .. "deep/deeper"), 0, "setup: nested parent does not exist yet")
    local pok, perr = file.ensure_parent(nested)
    ok(pok, "ensure_parent creates the whole missing chain: " .. tostring(perr))
    eq(fn.isdirectory(dir .. "deep/deeper"), 1, "ensure_parent: nested directory now exists")
    eq(perr, nil, "ensure_parent: no error on success")

    -- Already there: a second call is a cheap no-op, not an error.
    local aok, aerr = file.ensure_parent(nested)
    ok(aok, "ensure_parent on an existing directory succeeds")
    eq(aerr, nil, "ensure_parent on an existing directory reports no error")

    -- The failure that actually happens in the field: something is already
    -- sitting at the parent path as a FILE. `vim.fn.mkdir` raises `E739` for
    -- this, and the whole point of routing through lib.nvim's `mkdir_p` is
    -- that the caller gets fileops's own sentence instead of that raw error.
    local blocker = dir .. "blocker"
    H.write_file(blocker, "i am a file, not a directory")
    local bok, berr = file.ensure_parent(blocker .. "/child.txt")
    ok(not bok, "ensure_parent fails when the parent path is an existing file")
    ok(berr ~= nil, "ensure_parent reports an error message")
    ok(
      tostring(berr):find("cannot create directory", 1, true) ~= nil,
      "ensure_parent reports its OWN message, not a raw E739: " .. tostring(berr)
    )
    ok(
      tostring(berr):find("E739", 1, true) == nil,
      "ensure_parent does not leak Vim's E739 to the caller: " .. tostring(berr)
    )

    -- …and every op that creates something first has to relay that same
    -- message rather than crashing on the mkdir.
    local tok, tmsg = file.touch(blocker .. "/child.txt")
    ok(not tok, "touch through an unmakeable parent fails cleanly")
    ok(
      tostring(tmsg):find("cannot create directory", 1, true) ~= nil,
      "touch relays the parent-directory error: " .. tostring(tmsg)
    )
  end

  -- ── invalid input ────────────────────────────────────────────────────────
  do
    local eok, emsg = file.touch("")
    ok(not eok, "touch rejects an empty path")
    ok(tostring(emsg):find("invalid path", 1, true) ~= nil, "empty path is named as invalid")

    -- Deliberately off-type: refusing a non-string is the point.
    ---@diagnostic disable-next-line: param-type-mismatch
    local nok, nmsg = file.touch(nil)
    ok(not nok, "touch rejects a nil path")
    ok(tostring(nmsg):find("invalid path", 1, true) ~= nil, "nil path is named as invalid")

    local n2ok = file.edit_new("")
    ok(not n2ok, "edit_new rejects an empty path")
    local s2ok = file.save_as("")
    ok(not s2ok, "save_as rejects an empty path")
    local w2ok = file.write_to("")
    ok(not w2ok, "write_to rejects an empty path")
  end

  -- ── path shapes ──────────────────────────────────────────────────────────
  -- A file-operations plugin is exactly where "a path is just a string"
  -- stops being true: names carry spaces, `%` and `#` mean something to
  -- `expand()`, and on Windows a bare drive letter is not a relative path.
  do
    local spaced = dir .. "a file with spaces.txt"
    local sok, smsg = file.touch(spaced)
    ok(sok, "touch: a name containing spaces: " .. tostring(smsg))
    eq(fn.filereadable(spaced), 1, "touch: the spaced file exists under exactly that name")

    -- `%` and `#` are the current/alternate file to `expand()`. They must
    -- survive as literal characters in a file name.
    local percent = dir .. "re%port.txt"
    ok(file.touch(percent), "touch: a name containing '%'")
    eq(fn.filereadable(percent), 1, "touch: '%' stayed literal in the file name")

    local hashed = dir .. "issue#12.txt"
    ok(file.touch(hashed), "touch: a name containing '#'")
    eq(fn.filereadable(hashed), 1, "touch: '#' stayed literal in the file name")

    local bracketed = dir .. "notes[draft].txt"
    ok(file.touch(bracketed), "touch: a name containing glob brackets")
    eq(fn.filereadable(bracketed), 1, "touch: the bracketed name exists verbatim")
  end

  -- ── glob metacharacters with something for them to match ─────────────────
  -- The case above passes for the wrong reason as long as nothing matches:
  -- `expand()` hands an unmatched pattern back unchanged, so a destination
  -- that does not exist yet looks literal even when it is being globbed. Put a
  -- file in reach of the pattern and the difference shows.
  --
  -- `resolve_path` used `fn.expand`, so `[`, `?` and `*` in a destination were
  -- wildcards: `:File rename note[1].md` next to an existing `note1.md`
  -- resolved to *that* file and refused with "destination already exists",
  -- naming a path the user never typed — or, with the bang, overwrote it.
  -- A glob is the wrong tool for a destination by definition: the file is not
  -- supposed to exist yet, so there is nothing legitimate for it to match.
  -- `expand_path` expands `~` and `$VAR` only, and leaves the rest alone.
  --
  -- The decoys have to sit in the CWD, and that is the second half of the bug:
  -- a relative destination is anchored on the buffer's directory, but
  -- `fn.expand` globbed it against the cwd — so the file it matched could come
  -- from a directory that has nothing to do with the operation.
  do
    local gdir = H.tmpdir()
    local prev_cwd = fn.getcwd()
    H.write_file(gdir .. "note1.md", "decoy")
    H.write_file(gdir .. "note2.md", "decoy")
    H.write_file(gdir .. "src.md", "source")
    H.edit(gdir .. "src.md")
    vim.cmd("cd " .. fn.fnameescape(gdir))

    local rok, rmsg = file.rename("note[1].md")
    ok(rok, "rename to a bracketed destination succeeds: " .. tostring(rmsg))
    eq(fn.filereadable(gdir .. "note[1].md"), 1, "…creating the bracketed name itself")
    eq(fn.readfile(gdir .. "note1.md")[1], "decoy", "…and leaving the file it could match alone")
    eq(
      fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
      "note[1].md",
      "…and naming the buffer after the destination, not after the match"
    )

    -- `edit_new` reaches `resolve_path` by a different route than `rename`
    -- does, and names the buffer without touching the disk at all. Brackets
    -- rather than `?` or `*`, which Windows refuses in a file name outright.
    ok(file.edit_new("note[2].md"), "edit_new: a name containing glob brackets")
    eq(
      fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
      "note[2].md",
      "edit_new names the buffer after the path it was given, not after note2.md"
    )

    -- The Windows everyday case, and the one that turned the CI matrix red: a
    -- user name longer than eight characters gets an 8.3 alias, so paths come
    -- back spelled `C:\Users\RUNNER~1\...`. Neovim treats a `~` ANYWHERE in an
    -- Ex command's file argument as a wildcard, not just a leading one, and
    -- `fnameescape` never escapes it — so every such path was re-globbed on
    -- its way through `:file`/`:edit`. A `~` inside a name reproduces that on
    -- any platform.
    local tilde_dir = gdir .. "held~1"
    vim.fn.mkdir(tilde_dir, "p")
    local tilde = tilde_dir .. "/inside.md"
    ok(file.edit_new(tilde), "edit_new: a path with a '~' in a directory component")
    eq(
      fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h:t"),
      "held~1",
      "…keeps the '~' component in the buffer name: " .. vim.api.nvim_buf_get_name(0)
    )

    -- A LEADING `~` is still a home-directory reference, which is what
    -- `expand_path` is there to keep doing — `:File new ~/…` is documented.
    local home = (vim.uv or vim.loop).os_homedir()
    if type(home) == "string" and home ~= "" then
      vim.cmd("enew")
      ok(file.edit_new("~/.fileops_spec_tilde.txt"), "edit_new: a leading '~' still expands")
      ok(
        vim.api.nvim_buf_get_name(0):find("~", 1, true) == nil,
        "…to the home directory: " .. vim.api.nvim_buf_get_name(0)
      )
      vim.cmd("enew!")
    end

    vim.cmd("cd " .. fn.fnameescape(prev_cwd))
  end

  -- Relative input is anchored on the BUFFER's directory for the ops that act
  -- on the current buffer's file (covered in file_spec.lua) and on the cwd for
  -- the ops that do not take a base. Both are checked from a cwd deliberately
  -- different from the fixture directory, which is the only way the two can be
  -- told apart.
  do
    local cwd_dir = H.tmpdir()
    local prev_cwd = fn.getcwd()
    vim.cmd("cd " .. fn.fnameescape(cwd_dir))

    ok(file.touch("relative.txt"), "touch: a bare relative name")
    eq(fn.filereadable(cwd_dir .. "relative.txt"), 1, "touch: relative input resolves against cwd")
    eq(fn.filereadable(dir .. "relative.txt"), 0, "touch: no stray file next to the fixtures")

    vim.cmd("cd " .. fn.fnameescape(prev_cwd))
  end

  -- An absolute destination must win over any base. On Windows that includes
  -- the drive-letter form, which has no leading separator at all — the shape
  -- a `^/` check silently mistakes for a relative path.
  do
    local other = H.tmpdir()
    local src = dir .. "anchor.txt"
    H.write_file(src, "-- anchor")
    H.edit(src)

    local target = other .. "absolute_dest.txt"
    ok(file.copy(target), "copy to an absolute destination in another directory")
    eq(fn.filereadable(target), 1, "copy: the absolute destination was used as given")
    eq(fn.filereadable(dir .. "absolute_dest.txt"), 0, "copy: the base directory was not used")

    if H.is_windows() then
      ok(target:match("^%a:[\\/]") ~= nil, "setup: the destination really is a drive-letter path")
    end
  end

  -- ── edit_new ─────────────────────────────────────────────────────────────
  do
    vim.cmd("enew")
    local created = dir .. "named/only.txt"
    local nok, nmsg = file.edit_new(created)
    ok(nok, "edit_new succeeds: " .. tostring(nmsg))
    eq(fn.fnamemodify(fn.expand("%:p"), ":t"), "only.txt", "edit_new renames the current buffer")
    eq(fn.isdirectory(dir .. "named"), 1, "edit_new created the parent directory")
    eq(fn.filereadable(created), 0, "edit_new does NOT write the buffer to disk")

    vim.cmd("enew")
    local written = dir .. "named/written.txt"
    local wok, wmsg = file.edit_new(written, { write = true })
    ok(wok, "edit_new with write=true succeeds: " .. tostring(wmsg))
    eq(fn.filereadable(written), 1, "edit_new with write=true created the file on disk")

    -- Writing over an existing file needs the bang, exactly like `:write`.
    -- The fixture is written directly, with no buffer of its own: naming a
    -- second buffer after an already-open file is a different failure (E95).
    local existing = dir .. "named/existing.txt"
    H.write_file(existing, "on disk")
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "replacement" })
    local cok, cmsg = file.edit_new(existing, { write = true })
    ok(not cok, "edit_new refuses to write over an existing file without a bang")
    ok(
      tostring(cmsg):find("write failed", 1, true) ~= nil,
      "…reported as a write failure, not as a crash: " .. tostring(cmsg)
    )
    eq(fn.readfile(existing)[1], "on disk", "…and the file on disk is untouched")

    local bok = file.edit_new(existing, { write = true, bang = true })
    ok(bok, "edit_new with bang=true overwrites")
    eq(fn.readfile(existing)[1], "replacement", "edit_new!: the new content landed on disk")

    vim.cmd("enew!")
    local fok, fmsg = file.edit_new(dir .. "blocker/impossible.txt")
    ok(not fok, "edit_new relays an unmakeable parent instead of renaming the buffer")
    ok(
      tostring(fmsg):find("cannot create directory", 1, true) ~= nil,
      "edit_new's failure names the directory problem: " .. tostring(fmsg)
    )
  end

  -- ── save_as / write_to ───────────────────────────────────────────────────
  do
    local origin = dir .. "origin.txt"
    H.write_file(origin, "original content")
    H.edit(origin)

    local saved = dir .. "saveas/copy.txt"
    local sok, smsg = file.save_as(saved)
    ok(sok, "save_as succeeds: " .. tostring(smsg))
    eq(fn.filereadable(saved), 1, "save_as wrote the destination")
    eq(fn.filereadable(origin), 1, "save_as left the original file in place")
    eq(
      vim.fs.normalize(fn.expand("%:p")),
      vim.fs.normalize(saved),
      "save_as re-points the buffer (like :saveas)"
    )

    -- One spelling per path, whichever op produced it. `resolve_path` joins a
    -- relative destination onto its base with "/", so on Windows every op that
    -- takes one used to leave a mixed-separator buffer name behind —
    -- `C:\dir\sub/NEW.md`, the same file as `C:\dir\sub\NEW.md` and unequal to
    -- it as a string. That is the second spelling the `follow_symlinks = false`
    -- pin in cycle_edge_spec.lua and the bulk-rename pin in bulk_edge_spec.lua
    -- both have to normalize away at their comparison sites; `resolve_path`
    -- unifies separators now, so it is no longer minted in the first place.
    --
    -- Pinned for both ops together, because they used to disagree: `:saveas`
    -- normalized the name and the `:file` behind `rename` did not.
    if H.is_windows() then
      eq(
        fn.expand("%:p"):find("/", 1, true),
        nil,
        "save_as leaves an all-backslash buffer name on Windows"
      )
      local mixed_src = dir .. "mixed.txt"
      H.write_file(mixed_src, "x")
      H.edit(mixed_src)
      ok(file.rename("mixed_renamed.txt"), "rename with a relative destination succeeds")
      eq(
        vim.api.nvim_buf_get_name(0):find("/", 1, true),
        nil,
        "…and leaves an all-backslash buffer name too: " .. vim.api.nvim_buf_get_name(0)
      )
      eq(
        fn.filereadable(dir .. "mixed_renamed.txt"),
        1,
        "…while the file itself lands exactly where it should"
      )
      H.edit(saved)
    end

    -- write_to is the silent counterpart: the copy lands, the buffer keeps its
    -- own name.
    local elsewhere = dir .. "writeto/copy.txt"
    local wok, wmsg = file.write_to(elsewhere)
    ok(wok, "write_to succeeds: " .. tostring(wmsg))
    eq(fn.filereadable(elsewhere), 1, "write_to wrote the destination")
    eq(
      vim.fs.normalize(fn.expand("%:p")),
      vim.fs.normalize(saved),
      "write_to leaves the buffer name alone"
    )

    local sfail = file.save_as(dir .. "blocker/nope.txt")
    ok(not sfail, "save_as relays an unmakeable parent directory")
    local wfail = file.write_to(dir .. "blocker/nope.txt")
    ok(not wfail, "write_to relays an unmakeable parent directory")
  end

  -- ── mk_parent ────────────────────────────────────────────────────────────
  do
    vim.cmd("enew")
    local mok, mmsg = file.mk_parent()
    ok(not mok, "mk_parent on a nameless buffer fails")
    eq(mmsg, "current buffer has no file name", "mk_parent names the missing file name")

    -- The real case: a buffer named into a directory that does not exist yet
    -- (`:File new sub/dir/file.txt`, then `:File mkdir` before writing).
    vim.cmd("enew")
    local pending = dir .. "pending/sub/file.txt"
    ok(file.edit_new(pending), "setup: buffer named into a non-existent directory")
    vim.fn.delete(dir .. "pending", "rf")
    eq(fn.isdirectory(dir .. "pending/sub"), 0, "setup: the parent directory is gone again")

    local events = {}
    local group = vim.api.nvim_create_augroup("fileops_mkparent_spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "FileopsChanged",
      callback = function(ev)
        events[#events + 1] = ev.data
      end,
    })

    local rok, rmsg = file.mk_parent()
    ok(rok, "mk_parent re-creates the buffer's parent directory: " .. tostring(rmsg))
    eq(fn.isdirectory(dir .. "pending/sub"), 1, "mk_parent: the directory exists again")
    eq(#events, 1, "mk_parent fires one FileopsChanged event")
    eq(events[1].action, "mkdir", "mk_parent's event action is 'mkdir'")

    vim.api.nvim_del_augroup_by_id(group)
  end

  -- ── notify_change ────────────────────────────────────────────────────────
  -- Exported so ops.bulk can reuse it; its contract is "always emit the
  -- autocmd, optionally refresh the explorers". The event must carry the
  -- action and the path, since that is all a listening plugin gets.
  do
    local events = {}
    local group = vim.api.nvim_create_augroup("fileops_notify_change_spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "FileopsChanged",
      callback = function(ev)
        events[#events + 1] = ev.data
      end,
    })

    file.notify_change("custom", dir .. "whatever.txt", { refresh_explorers = false })
    eq(#events, 1, "notify_change emits the autocmd even with refresh_explorers = false")
    eq(events[1].action, "custom", "notify_change relays the action verbatim")
    eq(events[1].path, dir .. "whatever.txt", "notify_change relays the path verbatim")

    file.notify_change("custom2", dir .. "whatever.txt")
    eq(#events, 2, "notify_change emits the autocmd with default opts too")

    vim.api.nvim_del_augroup_by_id(group)
  end

  -- ── copy_path (rel) / current_path ───────────────────────────────────────
  do
    local rel_dir = H.tmpdir()
    local rel_file = rel_dir .. "sub/relative.txt"
    H.write_file(rel_file, "x")
    local prev_cwd = fn.getcwd()
    vim.cmd("cd " .. fn.fnameescape(rel_dir))
    H.edit(rel_file)

    eq(
      file.current_path(),
      fn.fnamemodify(rel_file, ":p"),
      "current_path answers the buffer's own file"
    )

    ok(file.copy_path("rel"), "copy_path rel succeeds")
    eq(
      fn.getreg('"'):gsub("\\", "/"),
      "sub/relative.txt",
      "copy_path rel: the path is relative to the cwd"
    )

    vim.cmd("cd " .. fn.fnameescape(prev_cwd))

    vim.cmd("enew")
    eq(file.current_path(), nil, "current_path answers nil for a nameless buffer")
    local pok, pmsg = file.copy_path("abs")
    ok(not pok, "copy_path on a nameless buffer fails")
    eq(pmsg, "current buffer has no file name", "copy_path names the missing file name")
  end

  -- ── info: the human_size ladder ──────────────────────────────────────────
  do
    local small = dir .. "small.bin"
    H.write_file(small, string.rep("x", 12))
    H.edit(small)
    local iok, imsg = file.info()
    ok(iok, "info on a 12-byte file succeeds")
    ok(imsg:find("12 B ", 1, true) ~= nil, "info: bytes are reported without a decimal: " .. imsg)

    local kib = dir .. "kib.bin"
    H.write_file(kib, string.rep("x", 2048))
    H.edit(kib)
    local kok, kmsg = file.info()
    ok(kok, "info on a 2 KiB file succeeds")
    ok(kmsg:find("2.0 KiB", 1, true) ~= nil, "info: KiB are reported with one decimal: " .. kmsg)
    ok(kmsg:find("2048 bytes", 1, true) ~= nil, "info: the exact byte count is reported too")

    vim.cmd("enew")
    local nok, nmsg = file.info()
    ok(not nok, "info on a nameless buffer fails")
    eq(nmsg, "current buffer has no file name", "info names the missing file name")

    -- A buffer whose file is gone can still be named; `fs_stat` is what fails.
    local vanished = dir .. "vanished.txt"
    H.write_file(vanished, "x")
    H.edit(vanished)
    vim.fn.delete(vanished)
    local vok, vmsg = file.info()
    ok(not vok, "info on a vanished file fails")
    ok(tostring(vmsg):find("cannot stat file", 1, true) ~= nil, "info: names the stat failure")
  end
end

return function(H)
  H.run_preserved(spec)
end
