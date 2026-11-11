-- TESTS/sheets/features.lua -- the functionalities of fileops.nvim as its user meets them; `testing sheets report`
-- says which ones have a feature sheet (`feature = "<id>"`) and in which state, and K16 warns about a sheet that names
-- an id not listed here. Data: read with an empty environment like a sheet (testing.nvim docs/SHEETS.md).
-- The list follows docs/FEATURES/ (README.md and its seven pages) and ALL/manual-test-checklists/fileops.md.
return {
  {
    id = "fileops.command",
    title = "Every operation is one :File verb; a missing path is asked for, a cancel does nothing",
    surface = { "command:File" },
    docs = "docs/FEATURES/COMMAND.md",
  },
  {
    id = "fileops.create",
    title = ":File touch, new, write, saveas, writeto and mkdir create and write files relative to the cwd",
    surface = {
      "command:File touch",
      "command:File new",
      "command:File saveas",
      "command:File mkdir",
    },
    docs = "docs/FEATURES/OPERATIONS.md",
  },
  {
    id = "fileops.rename-move",
    title = ":File rename and :File move change the file on disk and the buffer pointing at it together",
    surface = { "command:File rename", "command:File move" },
    docs = "docs/FEATURES/OPERATIONS.md",
  },
  {
    id = "fileops.overwrite",
    title = "Rename, move, duplicate or copy onto an existing file asks first, with ! it does not",
    surface = { "command:File duplicate", "command:File copy" },
    docs = "docs/FEATURES/OPERATIONS.md",
  },
  {
    id = "fileops.delete",
    title = ":File delete moves the file to the trash, or removes it for good, asking first when the buffer is unsaved",
    surface = { "command:File delete", "binding:<leader>dcf", "config:delete.mode" },
    docs = "docs/FEATURES/OPERATIONS.md",
  },
  {
    id = "fileops.session",
    title = "After a rename or move the active session is saved again with the new path",
    surface = { "config:session_compat" },
    docs = "docs/FEATURES/OPERATIONS.md",
  },
  {
    id = "fileops.cycle",
    title = ":File next, prev, first and last and their keys step through the files of the directory",
    surface = {
      "command:File next",
      "command:File prev",
      "command:File first",
      "command:File last",
    },
    docs = "docs/FEATURES/NAVIGATION.md",
  },
  {
    id = "fileops.info",
    title = ":File path copies the path, :File info shows the metadata, :File cd changes to the file's directory",
    surface = { "command:File path", "command:File info", "command:File cd" },
    docs = "docs/FEATURES/NAVIGATION.md",
  },
  {
    id = "fileops.bulk",
    title = ":File bulk renames the files of a directory by a Lua pattern, after a preview",
    surface = { "command:File bulk" },
    docs = "docs/FEATURES/BULK.md",
  },
  {
    id = "fileops.git-aware",
    title = "With git_aware a tracked file is noted, or renamed, moved and deleted through git mv and git rm",
    surface = { "config:git_aware" },
    docs = "docs/FEATURES/SAFETY.md",
  },
  {
    id = "fileops.lock-retry",
    title = "A sharing violation on Windows is retried and, when it stays, explained",
    surface = { "config:retry" },
    docs = "docs/FEATURES/SAFETY.md",
  },
  {
    id = "fileops.lockinfo",
    title = ":File lockinfo says whether a file is locked and by which process",
    surface = { "command:File lockinfo" },
    docs = "docs/FEATURES/SAFETY.md",
  },
  {
    id = "fileops.ambient",
    title = "On its own: a missing directory is created on save, conflict markers light up, changes raise an event",
    surface = { "config:auto_mkdir", "config:on_hold" },
    docs = "docs/FEATURES/AUTOCMDS.md",
  },
  {
    id = "fileops.assets",
    title = "Deleting a note offers to delete the assets only it referenced, through filetree.nvim",
    docs = "docs/FEATURES/INTEGRATIONS.md",
  },
  {
    id = "fileops.gitsuite",
    title = "With gitsuite.nvim the conflict markers and the explorer refresh go through it",
    docs = "docs/FEATURES/INTEGRATIONS.md",
  },
  {
    id = "fileops.menu",
    title = "The right-click menu has a File fly-out with the operations",
    docs = "docs/FEATURES/INTEGRATIONS.md",
  },
  {
    id = "fileops.which-key",
    title = "The <leader>n and <leader>p groups carry their labels in which-key",
    docs = "docs/FEATURES/INTEGRATIONS.md",
  },
  {
    id = "fileops.config-check",
    title = "Bad options are reported and dropped, and the defaults apply",
    docs = "docs/configuration.md",
  },
}
