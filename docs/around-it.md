# Around it

How fileops.nvim's scope relates to its closest siblings in the collection.

## sessions.nvim

[sessions.nvim](https://github.com/WKDSteve/sessions.nvim) — fileops
handles the lifecycle of a single file (create, rename, duplicate, delete,
cycle); sessions handles the lifecycle of the whole workspace. Same "no
mandatory dependency, straight to libuv" style, one scale up.

## filetree.nvim

[filetree.nvim](https://github.com/WKDSteve/filetree.nvim) — the tree
view over the same directory. It listens for `User FileopsChanged` like any
other explorer, so a rename here refreshes it without either plugin depending
on the other.

## pickers.nvim

[pickers.nvim](https://github.com/WKDSteve/pickers.nvim) — its directory
browser (`:Pickers browse`, `pickers.browse`) lists one directory at a time
on the active picker engine and offers new file / new directory / rename /
delete as rows; those rows call this plugin's operations when it is
installed (`edit_new`, `delete_path`, `notify_change`) and fall back to
`vim.uv` otherwise. The composition runs one way: pickers reaches into
fileops, fileops knows nothing about pickers.

## buffer-ctx.nvim

[buffer-ctx.nvim](https://github.com/WKDSteve/buffer-ctx.nvim) — reads
the current file's identity (path, module, line) rather than changing it.

## Dependency shape

All of the above are soft: without them everything else works unchanged.
[lib.nvim](https://github.com/WKDSteve/lib.nvim) is the one real
dependency — see [Requirements](installation.md#requirements).
