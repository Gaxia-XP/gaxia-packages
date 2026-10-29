# Boot harness — run a Gaxia game without Studio

`node tools/run-game.mjs` runs the game headlessly and prints what Studio **Play** would show in Output:
red errors (script, line, stack), yellow warnings, prints, threads that wait forever (hangs) and kicks.
It simulates one server and one client per player under [Lune](https://github.com/lune-org/lune) 0.10.
Time is simulated (60 frames per second), so a 10 second run takes about one second.

## Install once

- Node 18 or newer.
- `lune` 0.10.x on your PATH: `rokit install` (it is in `rokit.toml`), or download it from
  https://github.com/lune-org/lune/releases, or set `LUNE=/path/to/lune`.
- Nothing else: no Studio, no rojo, no luau-lsp.

## Commands (run from the repo root)

| You want to… | Run |
|---|---|
| boot the framework (full install) | `node tools/run-game.mjs` |
| boot the framework + your game scripts | `node tools/run-game.mjs --game path/to/game` |
| boot only some packages | `node tools/run-game.mjs --packages Data,Economy` |
| boot a built tree (`packages.mjs build --out <dir>`, or any folder with `default.project.json`) | `node tools/run-game.mjs --build <dir>` |
| run every playbook's scripts | `node tools/check-playbooks.mjs --no-types --run` |
| prove the harness itself works | `node tools/run-game.mjs --self-test` |

Useful options: `--players 2`, `--seconds 30`, `--quiet` (hide prints), `--json report.json`,
`--datastore fail` or `--datastore studio-off` (every DataStore call errors), `--http` (HttpEnabled on),
`--no-studio` (`RunService:IsStudio()` is false), `--scenario file.lua` (below). `--help` lists them all.

**Exit code:** `0` no errors and no hangs · `1` the game has errors or hangs · `2` `HARNESS ERROR`
(the harness failed — not your game) or `SCENARIO ERROR` (your scenario file failed).

### The game folder (`--game`)

One folder per service, like the Explorer. File names follow Rojo:

```
game/ServerScriptService/CoinShop.server.lua            → Script
game/StarterPlayer/StarterPlayerScripts/Hud.client.lua  → LocalScript
game/ServerStorage/GameModules/Catalog.lua              → ModuleScript (a folder → Folder)
game/ReplicatedStorage/..., game/Workspace/..., game/StarterGui/...
```

It is merged over the framework tree. A folder with `init.meta.json` (`{ "className": "ScreenGui" }`) becomes that class.

## What happens in a run

1. The server starts: every enabled Script in ServerScriptService and Workspace runs.
2. After 2 s, `Player1` joins (`--players N`: Player1…PlayerN): `PlayerAdded`, the client starts
   (StarterPlayerScripts are copied to PlayerScripts and run), the character spawns 0.1 s later
   (StarterGui → PlayerGui, StarterPack → Backpack, `CharacterAdded`).
3. `--seconds` (default 10) of simulated time pass.
4. Every player leaves (`PlayerRemoving`), then `game:BindToClose` callbacks run (up to 30 s).
5. Threads still waiting on `WaitForChild` (no timeout), `InvokeServer`, `require` … are reported as hangs.

## Custom scenario (`--scenario steps.lua`)

The server has already started when the file runs. Everything after it (leave, BindToClose) still runs.

```lua
-- steps.lua
harness.advance(2)                        -- let 2 simulated seconds pass
local p = harness.join("Player1")         -- a player joins (returns a handle)
harness.advance(5)
harness.chat(p, "/coins")                 -- type in chat (TextChatCommand or the server's ShouldDeliverCallback)
harness.clickButton(p, "Buy 100 Gems")    -- a button in PlayerGui, by text or by path ("ShopGui.Frame.Buy")
harness.autoBuy(true)                     -- from now on, purchase prompts are "bought" 0.5 s later
harness.purchase(p, 123456)               -- a developer product purchase: calls ProcessReceipt
harness.fireServer(p, "ReplicatedStorage.Events.MyRemote", "arg")
print(harness.invokeServer(p, "ReplicatedStorage.MyFunction", 1))
print(harness.runServer([[return game.Players.Player1:GetAttribute("Coins")]]))  -- Luau in the server world
print(harness.runClient(p, [[return #game.Players.LocalPlayer.PlayerGui:GetChildren()]]))
harness.leave(p)
```

`print` in a scenario goes to the `SCENARIO LOG` section.

## How faithful is it?

It tries hard to give **only errors the game would also get in Roblox**:

- Instances answer like Roblox: a missing child or member is `X is not a valid member of Class "Full.Name"`,
  a wrong property type is `Unable to assign property …`, `inst.Method()` is `Expected ':' not '.'`. The class
  list (properties, methods, events) is `classdb.json`, generated from the luau-lsp Roblox definitions:
  `node tools/harness/gen-classdb.mjs path/to/globalTypes.d.luau`.
- The client cannot see ServerStorage or ServerScriptService. Each world has its own `require` cache, `_G`
  and Instance identities. Remote arguments are copied like Roblox (tables copied, metatables and functions
  dropped, Instances the receiver cannot see become `nil`). Instances a client creates exist only on that
  client, and a property or attribute a client sets on a server instance changes only that client's copy
  (except the physics of its own character), so "trusting the client" bugs show up as in Roblox.
- Signals are **Deferred** (Roblox's default): handlers run at the end of the current step. `--signals immediate` switches.
- Yielding where Roblox cannot (`task.wait` in a metamethod, `UpdateAsync` callbacks) errors as in Roblox.
- A script that never yields stops the run with `Script timeout` after 60 s of real time (`--timeout`).

What it does **not** simulate — a quiet stub, and an `UNMODELED` line in the report when it matters:
physics and collisions (parts never move or touch, `Raycast` returns nil, `Touched` never fires),
rendering and real input, animations (tracks play but never end), sounds, pathfinding, HTTP (no network),
real Roblox web APIs (thumbnails, groups, badges, friends return defaults), MessagingService across servers
(messages come back to the same server), teleports (only recorded), and a client re-parenting or destroying a server instance (the harness
applies it everywhere; Roblox only on that client). Vector3 values are not equal as table keys
(Lune's Vector3 is not Luau's native vector). DataStores are in memory and start
empty every run (like a fresh place with Studio API access on).

If the report shows an error you think Roblox would not give, it is a harness gap: check it in Studio and
fix the harness (`tools/harness/runtime/*.luau`), not the game.

## Files

| File | What it is |
|---|---|
| `tools/run-game.mjs` | CLI: builds the Instance tree from the Rojo project (+ `--game`), runs Lune, prints the report |
| `main.luau` | entry: builds the DataModel, runs the scenario, reports hangs |
| `runtime/sched.luau` | simulated clock, threads, `task.*`, error capture with tracebacks |
| `runtime/instance.luau`, `runtime/classes.luau` | the Instance model and class behaviour |
| `runtime/signal.luau` | RBXScriptSignal / RBXScriptConnection |
| `runtime/world.luau` | worlds (server, one per client), globals, `require`, which scripts run where |
| `runtime/services.luau`, `runtime/data.luau`, `runtime/net.luau`, `runtime/players.luau` | services, remotes, players, chat |
| `runtime/datatypes.luau` | TweenInfo, Random, DateTime, Raycast/OverlapParams, permissive Enum (the rest comes from `@lune/roblox`) |
| `tests/<case>/` | self-test fixtures: `game/` + `expect.json` (+ optional `scenario.lua`) |
