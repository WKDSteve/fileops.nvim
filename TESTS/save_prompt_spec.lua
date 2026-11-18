-- TESTS/save_prompt_spec.lua — features/save_prompt.lua: `:File save` and
-- `fileops.save()` on a `[No Name]` buffer ask for a name and a folder instead
-- of failing with E32, and every step can be cancelled without an error.
--
-- The kit is replaced through the module's own `_kit` seam (scripted answers
-- per step), the folder walk through `_list_dirs` (a fixed list), so the case
-- does not depend on what the cwd happens to contain. The writes are real,
-- into `H.tmpdir()`.

local function spec(H)
  local eq, ok = H.eq, H.ok
  local api, fn = vim.api, vim.fn
  local sp = require("fileops.features.save_prompt")
  local fileops = require("fileops")

  local root = H.tmpdir()
  fn.mkdir(root .. "/docs/notes", "p")
  local prev_cwd = fn.getcwd()
  vim.cmd("cd " .. fn.fnameescape(root))

  -- Scripted kit: `script.input` is a list of answers (nil = cancelled),
  -- `script.select` a function picking from the items, `script.confirm` a label.
  local script, calls
  local function reset(s)
    script, calls = s, {}
  end
  sp._kit = {
    input = function(o)
      calls[#calls + 1] = { kind = "input", title = o.title, default = o.default }
      local answer = table.remove(script.input, 1)
      if answer == nil then
        o.on_cancel()
      else
        o.on_submit(answer)
      end
    end,
    select = function(o)
      local labels = {}
      for i, item in ipairs(o.items) do
        labels[i] = o.format_item(item)
      end
      calls[#calls + 1] =
        { kind = "select", title = o.title, labels = labels, initial = o.initial_index }
      local item = script.select and script.select(o.items, labels)
      if item then
        o.on_select(item)
      else
        o.on_cancel()
      end
    end,
    confirm = function(o)
      calls[#calls + 1] = { kind = "confirm", question = o.question, choices = o.choices }
      o.on_answer(script.confirm)
    end,
  }
  sp._list_dirs = function(r, cb)
    cb({ r .. "/docs", r .. "/docs/notes" })
  end

  local function by_label(wanted)
    return function(items, labels)
      for i, l in ipairs(labels) do
        if l == wanted then
          return items[i]
        end
      end
    end
  end

  local function scratch(text)
    vim.cmd("enew")
    local b = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(b, 0, -1, false, { text })
    return b
  end

  local function same(a, b)
    return fn.fnamemodify(a, ":p"):gsub("[\\/]+", "/"):lower()
      == fn.fnamemodify(b, ":p"):gsub("[\\/]+", "/"):lower()
  end

  -- 1. name -> folder: the cwd row is first and preselected, then manual,
  --    cancel and the subfolders; picking one writes there.
  do
    local b = scratch("one")
    reset({ input = { "a.md" }, select = by_label("docs/notes/") })
    local result
    fileops.save(b, function(saved)
      result = saved
    end)
    eq(result, true, "save on [No Name]: on_done(true) after the write")
    eq(calls[1].title, "Save [No Name] as (file name)", "step 1 asks for the file name")
    eq(calls[2].kind, "select", "step 2 is the folder selection")
    eq(calls[2].initial, 1, "…with the first row preselected")
    ok(calls[2].labels[1]:find("^%./") ~= nil, "…which is the cwd: " .. calls[2].labels[1])
    eq(calls[2].labels[2], "Enter path manually…", "…then the manual path")
    eq(calls[2].labels[3], "Cancel", "…then cancel")
    eq(calls[2].labels[4], "docs/", "…then the subfolders, sorted")
    eq(
      fn.readfile(root .. "/docs/notes/a.md")[1],
      "one",
      "the file is written in the picked folder"
    )
    ok(same(api.nvim_buf_get_name(b), root .. "/docs/notes/a.md"), "the buffer is named after it")
    eq(vim.bo[b].modified, false, "…and no longer modified")
  end

  -- 2. the cwd row saves in the cwd itself.
  do
    local b = scratch("two")
    reset({
      input = { "b.md" },
      select = function(items)
        return items[1]
      end,
    })
    local result
    sp.run(b, function(saved)
      result = saved
    end)
    eq(result, true, "cwd row: saved")
    eq(fn.readfile(root .. "/b.md")[1], "two", "cwd row: written in the cwd")
  end

  -- 3. manual path: prefilled with <cwd>/<name>, the typed path wins.
  do
    local b = scratch("three")
    local typed = root .. "/elsewhere/c.md"
    reset({ input = { "c.md", typed }, select = by_label("Enter path manually…") })
    sp.run(b)
    eq(calls[3].kind, "input", "manual: asks for a path")
    ok(same(calls[3].default, root .. "/c.md"), "manual: prefilled with <cwd>/<name>")
    eq(fn.readfile(typed)[1], "three", "manual: written where typed (parent dir created)")
  end

  -- 4. a name with a folder in it skips the selection.
  do
    local b = scratch("four")
    reset({ input = { "docs/d.md" } })
    sp.run(b)
    eq(#calls, 1, "name with a folder: no selection")
    eq(fn.readfile(root .. "/docs/d.md")[1], "four", "…written relative to the cwd")
  end

  -- 5. cancelling: at the name, at the folder, via the Cancel row -- no write,
  --    no notification, on_done(false), the buffer stays unnamed and modified.
  for _, case in ipairs({
    { "name prompt", { input = {} } },
    { "folder <Esc>", { input = { "e.md" } } },
    { "Cancel row", { input = { "e.md" }, select = by_label("Cancel") } },
    { "empty name", { input = { "   " } } },
  }) do
    local b = scratch("five")
    reset(case[2])
    local result
    local seen = H.notifications(function()
      sp.run(b, function(saved)
        result = saved
      end)
    end)
    eq(result, false, case[1] .. ": on_done(false)")
    eq(#seen, 0, case[1] .. ": silent")
    eq(api.nvim_buf_get_name(b), "", case[1] .. ": the buffer stays unnamed")
    eq(fn.filereadable(root .. "/e.md"), 0, case[1] .. ": nothing written")
  end

  -- 6. an existing file: confirm first; Cancel keeps it, Overwrite replaces it.
  do
    H.write_file(root .. "/f.md", "old")
    local b = scratch("new")
    reset({
      input = { "f.md" },
      select = function(items)
        return items[1]
      end,
      confirm = "Cancel",
    })
    local result
    sp.run(b, function(saved)
      result = saved
    end)
    eq(calls[3].kind, "confirm", "existing file: asks before overwriting")
    eq(calls[3].choices[1], "Cancel", "…with Cancel first")
    eq(result, false, "declined: on_done(false)")
    eq(fn.readfile(root .. "/f.md")[1], "old", "declined: the file is untouched")

    reset({
      input = { "f.md" },
      select = function(items)
        return items[1]
      end,
      confirm = "Overwrite",
    })
    sp.run(b, function(saved)
      result = saved
    end)
    eq(result, true, "Overwrite: saved")
    eq(fn.readfile(root .. "/f.md")[1], "new", "Overwrite: the file is replaced")
  end

  -- 7. a named buffer is just written, no prompt.
  do
    H.edit(root .. "/g.md")
    local b = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(b, 0, -1, false, { "seven" })
    reset({ input = {} })
    local result
    fileops.save(b, function(saved)
      result = saved
    end)
    eq(#calls, 0, "named buffer: no prompt")
    eq(result, true, "named buffer: saved")
    eq(fn.readfile(root .. "/g.md")[1], "seven", "named buffer: written")
  end

  -- 8. `:File save` routes to the same flow.
  do
    local b = scratch("eight")
    reset({
      input = { "h.md" },
      select = function(items)
        return items[1]
      end,
    })
    require("fileops.bindings.usrcmds").register()
    vim.cmd("File save")
    eq(fn.readfile(root .. "/h.md")[1], "eight", ":File save: written via the prompt")
    ok(api.nvim_buf_get_name(b) ~= "", ":File save: the buffer got its name")
  end

  sp._kit, sp._list_dirs = nil, nil
  vim.cmd("cd " .. fn.fnameescape(prev_cwd))
end

return function(H)
  H.run_preserved(spec)
end
