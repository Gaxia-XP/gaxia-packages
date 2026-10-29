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
| boot + click every button the player sees | `node tools/run-game.mjs --game <dir> --scenario tools/harness/scenarios/click-all.lua` |
| run every playbook's scripts (and click their buttons) | `node tools/check-playbooks.mjs --no-types --run` |
| prove the harness itself works | `node tools/run-game.mjs --self-test` |

Useful options: `--players 2`, `--seconds 30`, `--quiet` (hide prints), `--json report.json`,
`--datastore fail` or `--datastore studio-off` (every DataStore call errors), `--memorystore fail` (every MemoryStore call errors), `--http` (HttpEnabled on),
`--no-studio` (`RunService:IsStudio()` is false), `--scenario file.lua` (below). `--help` lists them all.

**Reading the report:** each error starts with `script:line — message`. When the error is raised inside
Gaxia, a `your code: <script>:<line>` line names the line of the game that called it: fix that line.
When the game prints anything, Gaxia's own boot prints are hidden (they are in `--json`).

**Exit code:** `0` no errors and no hangs (the only pass; the report says `→ exit 0`) · `1` the game has
errors or hangs, or `GAME LAYOUT`: part or all of your `--game` code did not run (a wrong folder or file
name) · `2` `HARNESS ERROR` (the harness failed — not your game; the RESULT line then says `HARNESS ERROR`),
`SCENARIO ERROR` (your scenario file failed) or a wrong command-line option.

Each error and hang also prints `file:` — the file to edit (for `--game` code and the framework source).

### The game folder (`--game`)

One folder per service, like the Explorer. File names follow Rojo:

```
game/ServerScriptService/CoinShop.server.lua            → Script
game/StarterPlayer/StarterPlayerScripts/Hud.client.lua  → LocalScript
game/ServerStorage/GameModules/Catalog.lua              → ModuleScript (a folder → Folder)
game/ReplicatedStorage/..., game/Workspace/..., game/StarterGui/...
```

Also like Rojo: `X.model.json` → that instance (`className`, `properties`, `children`), `X.json` → a ModuleScript returning the data, `X.txt` → StringValue.

Other files at the top of the folder (`PACKAGES.txt`, `README.md`, `*.json`, …) are ignored; a `.lua` / `.luau`
file there is a `GAME LAYOUT` failure (it is code that would never run).

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
-- steps.lua — the lines marked "your name" need a button / remote your game has
harness.advance(2)                        -- let 2 simulated seconds pass
local p = harness.join("Player1")         -- a player joins (returns a handle); harness.join("Player1", 1) = with UserId 1 (a rejoin); harness.join("Bob", 123456789) sets the UserId
harness.advance(5)
print(harness.buttons(p))                 -- paths of every PlayerGui button that has a click handler
local clicked, skipped = harness.clickAll(p, 0.5) -- click each button a player can see, 0.5 s apart
harness.autoBuy(true)                     -- from now on, purchase prompts are "bought" 0.5 s later
harness.purchase(p, 123456)               -- a developer product purchase: calls ProcessReceipt
print(harness.runServer([[return game.Players.Player1:GetAttribute("Coins")]]))  -- Luau in the server world
print(harness.runClient(p, [[return #game.Players.LocalPlayer.PlayerGui:GetChildren()]]))
-- harness.chat(p, "/coins")                                    -- your command: type in chat
-- harness.clickButton(p, "Buy 100 Gems")                       -- your button: by text or path ("ShopGui.Frame.Buy")
-- harness.fireServer(p, "ReplicatedStorage.Events.MyRemote", "arg")  -- your remote
-- print(harness.invokeServer(p, "ReplicatedStorage.MyFunction", 1))  -- your RemoteFunction
-- harness.touchWith(p, "Workspace.Lava")                       -- your part: the player's character touches it
-- harness.touch("Workspace.Button", "Workspace.Crate", 0.5)    -- two parts touch, the touch ends 0.5 s later
-- harness.activateTool(p, "Sword")                             -- your tool: equip it (from the Backpack) and click
harness.leave(p)
```

`print` in a scenario goes to the `SCENARIO LOG` section (tables are printed as `{a, b, c}`).
`clickAll` clicks only buttons a player could click (the button and its parents `Visible`, the ScreenGui
`Enabled`, the button `Interactable`), rebuilds the list after each click (so a confirm dialog opened by one
click is clicked next), and fires `Activated` with a mouse `InputObject` and click count 1, like Roblox.
`--players` / `--seconds` do not apply to a scenario: it decides who joins and for how long.

**Touches** (the harness has no physics, so parts touch only when a scenario says so). A part is a path
(`"Workspace.Lava"`) or an Instance returned by `runServer`.

| Helper | What fires |
|---|---|
| `harness.touch(part, hitPart, endAfter?)` | on the server: `part.Touched(hitPart)` and `hitPart.Touched(part)`; with `endAfter` (seconds) that time passes, then `TouchEnded` fires the same way |
| `harness.touchEnded(part, hitPart)` | `TouchEnded` both ways on the server (for a touch that should end later) |
| `harness.touchWith(player, part, endAfter?, limb?)` | the player's character touches `part` with its `HumanoidRootPart` (or `limb`, e.g. `"LeftFoot"`), on the server and on that player's client (Roblox's client sees its own character's touches) |

Both return `true`, or `false` (with a note in the SCENARIO LOG) when Roblox would not fire `Touched`: a part
outside the Workspace or with `CanTouch = false`.

**Tools.** `harness.activateTool(player, toolName)` clicks with a Tool: if it is in the Backpack it is equipped
first (another equipped tool goes back to the Backpack; `Unequipped` / `Equipped` fire), then `Activated` and
`Deactivated` fire on the player's client and on the server, like a mouse click. It returns `false` (with a note)
for a tool with `Enabled = false` or `ManualActivationOnly = true`, which a click does not activate. In game code,
`Tool:Activate()` / `Tool:Deactivate()` fire `Activated` / `Deactivated` only in the world that called them, and
only while the tool is equipped (parented to a character), like Roblox.

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
- A script that never yields stops the run with `Script timeout` when no progress is seen for 60 s of real
  time (`--timeout`); the report names the script that was running.
- Robux, badge and group calls check their arguments like Roblox (`UserOwnsGamePassAsync(player, id)` is
  `Unable to cast Instance to int64`). DataStore values follow Roblox's JSON rules (no Instances, no mixed
  or sparse tables, no number-keyed dictionaries, at most 4,194,304 characters). An unknown `Enum` item,
  `Instance.new` class or service name errors like Roblox.

What it does **not** simulate — a quiet stub, and an `UNMODELED` line in the report when it matters:
physics and collisions (parts never move or touch by themselves, `Raycast` returns nil, `Touched` fires only
from `harness.touch` / `harness.touchWith`),
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
| `runtime/datatypes.luau` | TweenInfo, Random, DateTime, Raycast/OverlapParams, Enum (errors on an unknown item of a known Enum) (the rest comes from `@lune/roblox`) |
| `scenarios/click-all.lua` | default run plus one click on every button (used by `check-playbooks --run`) |
| `tests/<case>/` | self-test fixtures: `game/` + `expect.json` (+ optional `scenario.lua`); (l)–(o) are real agent mistakes: data read before it loaded, a package that was not picked, a wrong argument to a Gaxia function, an erroring remote handler; (x)–(z) cover the touch and tool helpers and notes at the top of `--game` |
