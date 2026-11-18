# Lua API

```lua
local fileops = require("fileops")

fileops.next(opts?, count?)          -- :File next equivalent
fileops.prev(opts?, count?)          -- :File prev equivalent
fileops.first(opts?)                 -- :File first equivalent
fileops.last(opts?)                  -- :File last equivalent
fileops.open(opts?)                  -- :File open equivalent
fileops.copy_path(mode?)             -- :File path equivalent
fileops.diagnose_lock(cb?, path?) -- :File lockinfo equivalent (async; cb(ok, report))
fileops.info()                       -- :File info equivalent
fileops.save(bufnr?, on_done?)       -- :File save ([No Name]: asks for name + folder)
fileops.save_as_prompt(bufnr?, on_done?) -- the name + folder prompt, for any buffer
fileops.new_file(path, opts?)        -- :File new
fileops.touch(path)                  -- :File touch
fileops.rename(path, opts?)          -- :File rename
fileops.move(path, opts?)            -- :File move
fileops.duplicate(path, opts?)       -- :File duplicate
fileops.copy(path, opts?)            -- :File copy
fileops.delete_current(opts?)        -- :File delete
fileops.cd_here(opts?)               -- :File cd
```

See [Command reference](commands.md) for the equivalent `:File` subcommand
behaviour of each function.
