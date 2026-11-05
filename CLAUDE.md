# cc-warehouse

The storage service for the user's live warehouse (computer #10): an exact index of the vaults, touch-screen access points, the control panel, the Parcel Service, the crafter and stat screens, plus the client API apps use. Follow the Karpathy guidelines in `../CLAUDE.md`; the `cc-warehouse-*` skills (and `references/warehouse.md` of the `cc-tweaked` skill) cover each part.

## Build and check

- `node test/check.cjs` compiles every file and refuses Lua 5.3 syntax. `node test/run.cjs [sim|crafter|screen|sides]` runs the simulator suites; `--min` builds the minified files first and tests those. `node test/manifest.cjs` regenerates `src/files.txt` after adding a file.
- `node build.cjs` packs `src/` into `dist/warehouse.lua` (a self-writing installer) and `dist/manifest.json`; `--min` minifies the files (what gets published) and writes `dist/maps/` plus the minified tree in `dist/min/`. `node build.cjs where lib/index.lua:57` turns a line of a minified file in game into its source line.
- `npm install` brings fengari (the Lua VM the tests run on), luamin and luaparse (the minifier).

## Rules that are easy to break

- `src/` is `/warehouse` on the computer. Config, keys, pairing and data live under `/warehouse/config` and `/warehouse/data` and are never in the repo or the installer.
- The service's core (`warehouse.lua`, `console.lua`, `lib/service.lua`, `lib/index.lua`) changes only when asked; most features are apps on the API (`src/examples/`), Parcel tasks, or the crafter.
- Code is loaded once: a code change in game needs `warehouse stop` and a start in a background tab. Config changes apply by themselves.
- Publishing is `node publish.cjs` (the user runs it; the permission classifier refuses gist uploads from Claude): it builds minified and uploads `warehouse.lua` and `manifest.json` to the secret gist in `gists.json`; the Control Panel's Updates screen installs it (the warehouse computer runs the new `warehouse.lua` from memory and reboots), on a multiplayer server too.
