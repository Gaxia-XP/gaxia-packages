# Change the Gaxia framework safely

> Your change to the framework works in Studio, keeps existing games working, and passes every check before you commit.

**Use this when** the user asks for: "change the framework", "fix a bug in Gaxia", "edit a Gaxia service", "add a module to Gaxia", "run the framework checks" (ไทย: "แก้ framework", "แก้บั๊กใน Gaxia", "แก้โค้ดใน src", "เพิ่ม module ให้ Gaxia", "รันเช็คของ framework").
**Job:** B (you change the Gaxia repo itself). Building a game with Gaxia is job A: read [AGENTS.md](../../AGENTS.md) instead.
**Tools:** Node 18 or newer, `rojo`, `lune`, `luau-lsp`, `luau-ast`, the Roblox definitions file, and Roblox Studio.
**You will change:** files under `src/`, then the generated `playbooks/api/`, the playbooks that show what you changed, and `CHANGELOG.md`.

Run every command from the repo root.

## Step 1 — Install the tools and save a baseline (once per change)

1. Run `rokit install`. This installs `rojo`, `lune`, `stylua` and `selene`.
2. Download `luau-lsp` from https://github.com/JohnnyMorganz/luau-lsp/releases (the repo was last checked with 1.70.0) and `luau-ast` from https://github.com/luau-lang/luau/releases (latest). Put both on your PATH. Check: `luau-lsp --version` prints a version and `luau-ast` prints `Usage:`.
3. Download the Roblox definitions file into the repo root, and hide it and the `lsp-*.txt` files from git (this changes no tracked file):

```sh
curl -LO https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
echo globalTypes.d.luau >> .git/info/exclude
echo 'lsp-*.txt' >> .git/info/exclude
```

4. Before you edit anything, save the current type errors. You compare against them in Step 7:

```sh
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src > lsp-before.txt 2>&1
luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src > lsp-v2-before.txt 2>&1
```

`src/` already has some type errors. Your change must not add any.

## Step 2 — Find the file to change

| Path | What is there |
|---|---|
| `src/ServerStorage/Gaxia_Packages_Server/init.lua` | Server loader: `LIB_KEY_MAP` (key → Lib module), the `GaxiaServerPackage` type, Boot. |
| `…/Gaxia_Packages_Server/Types.lua` | Shared types: `ServiceName`, the anti-cheat detector contract. |
| `…/Gaxia_Packages_Server/Packages.lua` | The package catalogue (Step 4). |
| `…/Gaxia_Packages_Server/Config/` | One ModuleScript per config section, joined in `Config/init.lua`. `Features.lua` = boot list of a full install. |
| `…/Gaxia_Packages_Server/Lib/` | Server services (one per package), plus `ServiceLifecycle` and `EffectiveConfig`. |
| `…/Gaxia_Packages_Server/AntiCheat/` | The anti-cheat orchestrator (`init.lua`) and one module per detector. |
| `src/ReplicatedStorage/Gaxia_Packages/init.lua` | Shared/client loader: the `GaxiaPackage` type, `SHARED_KEY_MAP`, `CLIENT_KEY_MAP`. |
| `…/Gaxia_Packages/Shared/` | Modules for server and client (Signal, Trove, NetService, Util/…). |
| `…/Gaxia_Packages/Client/` and `Client/UI/` | Client-only modules. |
| `…/Gaxia_Packages/Features.lua` | Client modules the client bootstrap loads at spawn. |
| `src/ServerScriptService/`, `src/StarterPlayer/` | The two bootstraps. |
| `plugin/` | The Gaxia Companion Studio plugin (installer, package picker). `plugin.project.json` bundles `src/` as its payload. |
| `tools/`, `scaffold.mjs` | `packages.mjs`, `gen-api.mjs`, `check-architecture.mjs`, `check-playbooks.mjs`; the service scaffold. |
| `playbooks/` | Agent recipes. `playbooks/api/` is generated: never edit it. |

To add a server service, follow [add a service](add-a-service.md). To add a detector, follow [add an anti-cheat detector](add-an-anticheat-detector.md).

## Step 3 — Follow the architecture rules

`node tools/check-architecture.mjs` checks them. R4–R7 and R10 apply to `Lib/` and `AntiCheat/` modules. R1–R3 and R8 apply to every module in `Lib/`, `AntiCheat/`, `Shared/` and `Client/`. R11 is for `Lib/`. R9, R12 and R13 check that files agree with each other.

| Rule | In plain words |
|---|---|
| R1 | A framework module never requires a loader (`Gaxia_Packages`, `Gaxia_Packages_Server`). Require the module itself: `require(script.Parent.EconomyService)`. |
| R2 | No local named `SharedPkg` (an old shared-loader handle) and no local function `server()` (an old loader helper): require the module itself. No `require(...) :: any`. |
| R3 | `require` takes a static path (`script.Parent.X`, `Shared.Signal`). No `WaitForChild`, `FindFirstChild` or variables. |
| R4 | A module body only defines things (requires, constants, tables, `Signal.new()`, functions). Connections, instances, threads and loops go in `Init` / `Start`. |
| R5 | `Lifecycle.Define(...)` is the last statement before `return`. Detectors never call Define. |
| R6 | No `require` inside a function (a few deliberate lazy loads are allow-listed in the tool). |
| R7 | Never require `ProfileService`, `PerformanceMonitor`, `Maid`, `Janitor`, `ComponentLegacy` or `ReplicatedState` at the top of a Lib/AntiCheat module. |
| R8 | Index typed Config sections directly: `Config.Vault.DefaultCapacity`, never `(Config.Vault or {})`. |
| R9 | `Types.ServiceName`, the `Name` in each `Lifecycle.Define(...)`, `LIB_KEY_MAP` and the `GaxiaServerPackage` fields list the same keys. |
| R10 | Each entry of `Needs` is a module required at the top of the file. List only modules whose Init must run first. |
| R11 | (`--complete`) every Lib service calls `Lifecycle.Define`. |
| R12 | `Packages.lua` matches the source (`node tools/packages.mjs check`). |
| R13 | `playbooks/api/` matches the source (`node tools/gen-api.mjs`). |

Lifecycle in one line each: `Init` is synchronous and must not yield; `Start` runs on its own thread after the Inits and may yield; `AutoStart = false` means only boot or `GaxiaServer.Lifecycle.Ensure` starts the service. Details: [add a service](add-a-service.md), Step 5.

## Step 4 — Keep the package catalogue right

`Packages.lua` has three parts:

- `Core`: always installed (loaders, Types, Config, ServiceLifecycle, Signal, Trove, NetService, …).
- `Presets`: named picks the Companion offers (`Default`).
- `Packages`: one entry per package: `Name`, `Category`, `Description`, `Boot`, `Server` / `Replicated` module paths, and `Requires`.

Every module belongs to Core or to exactly one package. `Requires` is generated from the requires in the source. After you add, move or remove a module or a `require`, run:

```sh
node tools/packages.mjs fix
node tools/packages.mjs check
```

A new module goes in the `Server` or `Replicated` list of its package. A static `require` of another package's module makes that package a dependency: every game that installs yours installs it too. For an optional link use `GaxiaServer.Lifecycle.Find` ([add a service](add-a-service.md), Step 5).

## Step 5 — Keep the public API stable

Games call the framework by name. Never break these:

- `GaxiaServer.<Key>` / `Gaxia.<Key>` keys, function names, parameter order and return values.
- Signal payloads (order and types), Config keys, remote names.
- Saved data keys in player profiles: never rename one. Write a migration instead ([API: Migration](../api/Migration.md)).

To add a parameter, add it at the end and make it optional. To rename, keep the old name as an alias that warns once, and list it under "Removed / deprecated" in `CHANGELOG.md`. A change of default behaviour goes in `CHANGELOG.md` and in every playbook that relies on it.

## Step 6 — Add a shared or client module

| Kind | File | Also add |
|---|---|---|
| Shared | `src/ReplicatedStorage/Gaxia_Packages/Shared/<Name>.lua` | `<Name> : typeof(require(script.Shared.<Name>)),` in `GaxiaPackage` (loader `init.lua`). The key is the file name; for a different key also add it to `SHARED_KEY_MAP`. |
| Client | `…/Gaxia_Packages/Client/<ModuleName>.lua` | `<Key> = "<ModuleName>",` in `CLIENT_KEY_MAP` and `<Key> : typeof(require(script.Client.<ModuleName>)),` in `GaxiaPackage`. |
| Client UI | `…/Gaxia_Packages/Client/UI/<Name>.lua` | `<Name> : typeof(require(script.Client.UI.<Name>)),` inside the `UI` block of `GaxiaPackage`. |

Then:

1. Add the path (`Shared/<Name>`, `Client/<ModuleName>`) to the `Replicated` list of a package in `Packages.lua`.
2. Keep each `typeof(require(...))` type line on one line. Installs delete the type lines of modules that are not installed.
3. To load a client module at spawn, edit `src/ReplicatedStorage/Gaxia_Packages/Features.lua`. Add `| "<Key>"` to the `export type ClientKey` union. Add an entry to the `Client` list: `{ Key = "<Key>", RequiresServer = "<ServerService>" },` (leave out `RequiresServer` when the module talks to no server service).
4. Run Step 7. `Gaxia.IsInstalled("<Key>")` works without more changes.

## Step 7 — Run every check

```sh
node tools/packages.mjs fix
node tools/packages.mjs check
node tools/gen-api.mjs
node tools/gen-api.mjs --check
node tools/check-architecture.mjs --complete
node tools/check-playbooks.mjs --v2
node tools/run-game.mjs --self-test
node tools/run-game.mjs --quiet
node tools/run-game.mjs --quiet --packages <YourPackage>
node tools/check-playbooks.mjs --no-types --run
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src > lsp-after.txt 2>&1
luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src > lsp-v2-after.txt 2>&1
grep -c TypeError lsp-before.txt lsp-after.txt lsp-v2-before.txt lsp-v2-after.txt
grep -c "<YourFile>.*TypeError" lsp-before.txt lsp-after.txt lsp-v2-before.txt lsp-v2-after.txt
```

The `run-game` and `--run` lines run the framework headlessly: a server and one player for 10 s of simulated time ([tools/harness/README.md](../../tools/harness/README.md)). `--self-test` must print `self-test: N/N passed` (every case passed). The two `run-game.mjs --quiet` lines must exit with code `0`: their `RESULT:` line starts `RESULT: 0 errors, 0 hangs` and ends `→ exit 0` (`RESULT: HARNESS ERROR` means nothing was checked). `--run` must print `0 problem(s)` and exit `0`. `<YourPackage>` = the package in `Packages.lua` that holds the module you changed. A line marked `HARNESS ERROR` is a bug in the harness, not in your change.

Run the last line once for each file you changed (`<YourFile>` = the end of its path, for example `Lib/EconomyService.lua`). Each `after` count must not be higher than its `before` count. A new file must have `0` in both `after` files. Some files already have type errors: those are not yours to fix.

Then play-test in Studio:

1. Run `rojo serve` and connect from Studio (**Plugins → Rojo → Connect**).
2. Press **Play**. Output shows `[Gaxia_ServerBootstrap] complete` and no red errors.
3. Use the feature you changed, the way a game does.
4. If you changed packages or requires, also test a picked install: `node tools/packages.mjs build --select <YourPackage> --out ../gaxia-test`, then `rojo serve ../gaxia-test/default.project.json`. `<YourPackage>` = the package in `Packages.lua` that holds the module you changed (for a detector: `AntiCheat`). This catches a missing `Requires`.
5. Anti-cheat changes: set `Enforce = true` in `Config/AntiCheat.lua` for the test (put it back to `false` after). Test with **Test → Clients and Servers** with 1 player: that test player is not the place creator. While `Enforce = false` nobody is kicked. With the Ban package installed, the place creator is never kicked or banned.

No Studio? Run every command check, report each Studio check as NOT RUN, and tell the user before you say done.

## Step 8 — Update the docs

1. Search the playbooks for every name you changed: `grep -rn "<OldName>" playbooks AGENTS.md`. Update each one, following [WRITING.md](../WRITING.md).
2. Never edit `playbooks/api/` by hand. `node tools/gen-api.mjs` rewrites it from the source comments: the comment line above a function becomes its description.
3. Add an entry to `CHANGELOG.md` under `## Unreleased`: a heading `### Added — …`, `### Changed — …`, `### Fixed — …` or `### Removed / deprecated`, then short bullets on what changes for games and what they must do.
4. If the change affects a section of `MANUAL.md` (Thai), update that section.
5. Changed `pruneTypeLines` in `tools/packages.mjs`? Make the same change in `plugin/src/PackageSelect.lua`: the two must match.
6. Run `node tools/check-playbooks.mjs --v2` again.

## Check that it works

1. `packages.mjs check` prints `✓ … catalogue matches the source`; `gen-api.mjs --check` prints `✓ playbooks/api is up to date`.
2. `check-architecture.mjs --complete` prints `… 0 violation(s)`; `check-playbooks.mjs --v2` prints `… 0 problem(s)`.
3. `run-game.mjs` (full install and your package) exits `0` and prints `RESULT: 0 errors, 0 hangs, … → exit 0`; `check-playbooks.mjs --no-types --run` prints `… 0 problem(s)` and exits `0`.
4. The `grep -c` counts in Step 7: no `after` count is higher than its `before` count, and new files have `0`.
5. The Studio play-test shows no red errors, and the changed feature works.
6. `CHANGELOG.md` has your entry, and `git status` shows only the files you meant to change.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `require(game:GetService("ServerStorage").Gaxia_Packages_Server)` inside a Lib module | `require(script.Parent.X)` | R1: a loader require creates a cycle and hides the dependency. |
| `Players.PlayerAdded:Connect(...)` at the top of a Lib module | Inside `Init` | R4: requiring a module must not start it. |
| Editing `Requires = { ... }` or `playbooks/api/` by hand | `packages.mjs fix`, `gen-api.mjs` | Both are generated; the checks fail on hand edits. |
| A type line split over two lines | One line per `typeof(require(...))` | Installs drop type lines by pattern; a split line breaks the loader type. |
| Renaming a public function | Add the new name, keep the old one as a warning alias | Games still call the old name. |
| Renaming a saved data key | A migration step | Old saves lose the value. |
| "All checks pass" without a Studio play-test | Play-test (Step 7) | The checks do not run the code. |
| Testing anti-cheat kicks as the place creator, or with `Enforce = false` | `Enforce = true` and a **Clients and Servers** test player | With Ban installed, the creator is exempt from kicks and bans. Nothing is kicked while `Enforce = false`. |
| Fixing old type errors in files you did not touch | Leave them; fix only your change | A small change is easier to review. |

## Change it

- To add a server service: [add a service](add-a-service.md).
- To add an anti-cheat detector: [add an anti-cheat detector](add-an-anticheat-detector.md).
- Without rokit: `aftman install` installs the same tools.
- Without luau-lsp / luau-ast on PATH: `check-playbooks` reads `LUAU_LSP` and `check-architecture` reads `LUAU_AST` (full paths). The raw `luau-lsp` commands then need the full path too.
- To rebuild the Companion plugin after changing `src/` or `plugin/`: `rojo build plugin.project.json -o GaxiaCompanion.rbxmx`.

## See also

- [AGENTS.md](../../AGENTS.md) · [playbooks/WRITING.md](../WRITING.md) · [API reference](../api/README.md)
- [API: Lifecycle](../api/Core.ServiceLifecycle.md) · [API: Config](../api/Core.Config.md)
