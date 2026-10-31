-- TESTS/usrcmds_spec.lua — bindings/usrcmds.lua: the :File dispatcher's
-- prompt_dest() helper (missing-path prompt, shared by 9 subcommands).

local function spec(H)
  local eq, ok = H.eq, H.ok

  require("fileops.config").setup({})

  -- prompt_dest() must route through kit.input (not a raw vim.ui.input),
  -- so it renders consistently with the author's other plugins. Require
  -- BEFORE cd'ing into the tmp dir below: `set rtp+=.` resolves "." against
  -- the cwd at lookup time, so changing cwd first would break this require.
  local captured_title
  package.loaded["ui.kit"] = {
    input = function(opts)
      captured_title = opts.title
      opts.on_submit("newfile.txt")
    end,
  }
  package.loaded["fileops.bindings.usrcmds"] = nil
  local usrcmds = require("fileops.bindings.usrcmds")
  usrcmds.register()

  local tmp = H.tmpdir()
  vim.cmd("cd " .. vim.fn.fnameescape(tmp))

  vim.cmd("File touch")

  eq(
    captured_title,
    "File touch: ",
    "prompt_dest: routes through kit.input with the expected prompt"
  )
  ok(
    vim.fn.filereadable(tmp .. "newfile.txt") == 1,
    "prompt_dest: the submitted name is used to create the file"
  )

  -- Every `:File` route carries a description (composer option float, docs).
  local bare = {}
  for _, route in
    ipairs(require("lib.nvim.bindings.usercmd.composer").registry().File:spec().routes)
  do
    if not route.desc or route.desc == "" then
      bare[#bare + 1] = table.concat(route.path, " ")
    end
  end
  eq(table.concat(bare, ", "), "", "every :File route has a description")

  -- Every positional argument says what it is in the option float: its own `desc`, else the
  -- one of its type (`register_type`). A lib.nvim older than `help.undocumented` cannot answer
  -- the question: the check fails by name instead of being skipped (NEW-43).
  local composer = require("lib.nvim.bindings.usercmd.composer")
  if type(composer.help.undocumented) == "function" then
    local missing = {}
    for _, m in ipairs(composer.help.undocumented("File", { args = true })) do
      missing[#missing + 1] = ("%s <%s>"):format(m.route, m.name)
    end
    eq(table.concat(missing, ", "), "", "every :File argument has a help text")
  else
    ok(
      false,
      "every :File argument has a help text: lib.nvim lacks composer.help.undocumented, update lib.nvim"
    )
  end

  -- The float shows one line per argument: no line break, no closing full stop, nothing absurdly
  -- long; an `enum_desc` only for values the argument really has.
  local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
  ---@param label string
  ---@param text any
  local function check_text(label, text)
    ok(type(text) == "string" and text ~= "", label .. ": has a text")
    if type(text) == "string" then
      ok(not text:find("[\r\n]"), label .. ": the text is one line")
      ok(not text:find("%.$"), label .. ": the text has no closing full stop")
      ok(#text >= 12 and #text <= 80, label .. ": the text is 12 to 80 characters long")
    end
  end
  local seen = 0
  for _, r in ipairs(composer.registry().File:spec().routes) do
    for _, arg in ipairs(r.args or {}) do
      local label = ("%s <%s>"):format(table.concat(r.path, " "), arg.name)
      check_text(label, arg.desc or argtypes.get(arg.type).desc)
      seen = seen + 1
      for value, text in pairs(arg.enum_desc or {}) do
        ok(
          vim.tbl_contains(arg.enum or arg.values or {}, value),
          label .. ": enum_desc names '" .. value .. "', which is not one of its values"
        )
        ok(
          not text:find("%.$") and not text:find("[\r\n]") and #text <= 80,
          label .. ": enum_desc '" .. value .. "' is one line of at most 80 characters"
        )
      end
    end
  end
  ok(seen >= 20, "the route tree carries the arguments of all subcommands, saw " .. seen)
  for _, name in ipairs({ "FILEOPS_PATH", "FILEOPS_DEST_FIRST", "FILEOPS_CYCLE_ARG" }) do
    check_text("type " .. name, argtypes.get(name).desc)
  end

  package.loaded["ui.kit"] = nil
end

return function(H)
  H.run_preserved(spec)
end
