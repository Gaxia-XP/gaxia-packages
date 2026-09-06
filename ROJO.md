# Rojo setup — GaxiaPackages

Files (`src/`) are the **single source of truth**; Rojo syncs them into Studio
one-way, so hand-edits in the Studio editor are no longer the source (this kills
the file-push vs Studio-edit conflict).

## What the project maps (and what it leaves alone)
`default.project.json` maps **only the Gaxia framework** instances:
- `ReplicatedStorage.Gaxia_Packages` (ModuleScript root + `Shared` + `Client`)
- `ServerStorage.Gaxia_Packages_Server` (ModuleScript root + `Config` + `Lib` + `AntiCheat`)
- `ServerScriptService.Gaxia_ServerBootstrap`
- `StarterPlayer.StarterPlayerScripts.Gaxia_ClientBootstrap`

Every mapped service has `$ignoreUnknownInstances: true`, so **the Sprout game
content (HarvestService, the map, etc.) is NOT touched or deleted** by Rojo.

The package roots intentionally use Rojo's `init.lua` convention. A directory with
`init.lua` becomes a ModuleScript named after the directory, with its sibling files
and folders as children. This documentation targets the built ModuleScript topology;
do not assume support for manually assembled Folder/init layouts.

## One-time setup
```sh
# 1. install the toolchain (rokit reads rokit.toml)
rokit install

# 2. install the exact dependency graph pinned in wally.lock
wally install

# 3. VERIFY the tree WITHOUT touching your real place — build a throwaway file:
rojo build default.project.json --output GaxiaTest.rbxl
#    open GaxiaTest.rbxl in Studio and confirm:
#      ReplicatedStorage.Gaxia_Packages  is a ModuleScript with children: Shared, Client
#      ServerStorage.Gaxia_Packages_Server.AntiCheat  is a ModuleScript with detector children
#    (if the structure is right, the live sync below is safe)
```

## Daily workflow
```sh
rojo serve               # starts the sync server in this folder
```
Then in your real place: **Plugins → Rojo → Connect**. Files now sync into Studio
live; edit in your editor (VS Code / Cursor with the Rojo + luau-lsp extensions).

- `stylua src/` — format    ·    `selene src/` — lint
- `wally install` — restore the dependency graph pinned in `wally.lock`
- `rojo build default.project.json -o GaxiaPackages.rbxm` — build a distributable model

## Note on the MCP plugin
Rojo replaces only **file→Studio sync**. The Claude MCP plugin is still used for
`run_script_in_play_mode`, screenshots, and tests — they coexist (Rojo owns the
source tree, MCP drives Play/QA).
