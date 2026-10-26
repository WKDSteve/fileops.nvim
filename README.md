> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# fileops.nvim

```
 ███████╗██╗██╗     ███████╗ ██████╗ ██████╗ ███████╗
 ██╔════╝██║██║     ██╔════╝██╔═══██╗██╔══██╗██╔════╝
 █████╗  ██║██║     █████╗  ██║   ██║██████╔╝███████╗
 ██╔══╝  ██║██║     ██╔══╝  ██║   ██║██╔═══╝ ╚════██║
 ██║     ██║███████╗███████╗╚██████╔╝██║     ███████║
 ╚═╝     ╚═╝╚══════╝╚══════╝ ╚═════╝ ╚═╝     ╚══════╝
                                               .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-beta-orange)
[![wkd](https://img.shields.io/badge/wkd-family-c6ff3d)](https://wkdsteve.github.io/wkd/p/fileops/)

> Part of the [wkd](https://wkdsteve.github.io/wkd/) family — see this plugin's [page](https://wkdsteve.github.io/wkd/p/fileops/) on the site.

File operations for Neovim — one command, all operations. `:File` creates,
navigates, renames, duplicates and deletes files, keeping the buffer and the
disk in agreement, with all I/O going through libuv directly rather than a
shell.

---

## Documentation

Start at [docs/README.md](docs/README.md) — what's where, and which question
each page answers.

### The Basics

- [Requirements](docs/installation.md#requirements) — Neovim version, required and optional plugins.
- [Installation](docs/installation.md) — every plugin manager.
- [Quickstart](docs/quickstart.md) — the first thing to run after installing.

### What it does

- [Features](docs/FEATURES/README.md) — one page per area, with the reasoning behind each.
- [Around it](docs/around-it.md) — how this plugin's scope differs from its siblings in the collection.

### Configuration & Commands

- [All options](docs/configuration.md) — every `setup()` option and its default.
- [Commands](docs/commands.md) / [Bindings cheatsheet](docs/BINDINGS.md) — full usage and examples for every `:File` subcommand.
- [Keymaps](docs/keymaps.md) — the bindable action surface, for wiring your own keys.
- [Autocommands](docs/autocommands.md) — the `User FileopsChanged` event and what fires it.
- [Lua API](docs/api.md) — calling fileops.nvim functions directly from Lua.

### The Rest

- [Integrations](docs/FEATURES/INTEGRATIONS.md) — context menu, explorer refresh, which-key labels.
- [Health check](docs/FEATURES/INTEGRATIONS.md#checkhealth-fileops) — what `:checkhealth fileops` reports.
- [Architecture](docs/architecture.md) — module layout and responsibilities.
- [Contributing](docs/CONTRIBUTING.md) — ground rules, project layout, and how to add a subcommand.
- [Feedback](https://github.com/WKDSteve/fileops.nvim/issues) — bugs, features, usage questions (or a [discussion](https://github.com/WKDSteve/fileops.nvim/discussions) for anything more open-ended).

`:help fileops` is the same reference inside the editor.

---

## License

MIT — see [LICENSE](LICENSE).
