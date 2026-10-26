# Add a new service to the Gaxia framework

> The framework has a new server service: **GaxiaServer.Playtime** exists, starts at the right time, has its own package and API page, and every framework check passes.

**Use this when** the user asks for: "add a service to the framework", "a new Gaxia package", "scaffold a service", "new:service", "add GaxiaServer.X" (ไทย: "เพิ่ม service ใน framework", "สร้าง package ใหม่ให้ Gaxia", "เพิ่มระบบใหม่เข้า Gaxia").
**Job:** B (you change the Gaxia repo). A game feature never needs this: it goes in the game's own Scripts ([AGENTS.md](../../AGENTS.md)).
**Tools:** Node 18 or newer, `luau-ast`, `rojo`, `luau-lsp` and the Roblox definitions file ([change the framework](change-the-framework.md), Step 1).
**You will create:** `src/ServerStorage/Gaxia_Packages_Server/Lib/PlaytimeService.lua` and `src/ServerStorage/Gaxia_Packages_Server/Config/Playtime.lua`. The scaffold also edits `Types.lua`, `init.lua`, `Packages.lua` and `playbooks/api/`.

The example service counts how long each player has been in the server. It has one function (`Get`), one signal (`OnMilestone`), player hooks, a loop, a Config section and an optional link to Economy.

**Code blocks in this playbook are repo files.** The first line `-- fragment: <file>` names the file. Do not paste that first line. Run every command from the repo root.

## Step 1 — Pick the names

| Name | Example | Rule |
|---|---|---|
| `<Name>` | `Playtime` | PascalCase. The file becomes `Lib/<Name>Service.lua`. |
| `[Key]` | (same as Name) | Leave it out unless the key must differ. It is `GaxiaServer.<Key>`, the package name and the Define `Name`. |
| `--boot` | yes | Add it when the service has work to do before its first call: player hooks, remotes, loops. Leave it out for a plain API. |

Check the key is free. This command must print nothing:

```sh
grep -n '"Playtime"' src/ServerStorage/Gaxia_Packages_Server/Types.lua
```

## Step 2 — Run the scaffold

Run the dry run first, then the real command:

```sh
node scaffold.mjs new:service Playtime --boot --category "Data & players" --description "Seconds each player has played in this server, with milestone rewards." --dry-run
node scaffold.mjs new:service Playtime --boot --category "Data & players" --description "Seconds each player has played in this server, with milestone rewards."
```

The dry run prints four `would …` lines and writes nothing. The real run ends with a line that starts with "✓ wired GaxiaServer.Playtime". It did this:

| Where | What |
|---|---|
| `Lib/PlaytimeService.lua` | a new service from the template (an `Example` function, an `OnChanged` signal, `Lifecycle.Define`) |
| `Types.lua` | `"Playtime"` added to `Types.ServiceName` |
| `init.lua` (server loader) | `Playtime = "PlaytimeService"` in `LIB_KEY_MAP`, and a `Playtime : typeof(require(script.Lib.PlaytimeService)),` line in `GaxiaServerPackage` |
| `Packages.lua` | a package `Playtime` (`Boot = true` because of `--boot`), with its `Requires` generated |
| `playbooks/api/` | `Playtime.md`, `INDEX.md` and `README.md` regenerated |

## Step 3 — Write the service

Replace the whole content of `src/ServerStorage/Gaxia_Packages_Server/Lib/PlaytimeService.lua` with this block (without its first line):

```lua
-- fragment: src/ServerStorage/Gaxia_Packages_Server/Lib/PlaytimeService.lua
--!strict
-- ─────────────────────────────────────────────────────────────
-- PlaytimeService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/PlaytimeService
-- Purpose : Seconds each player has played in this server, with milestone rewards.
--
-- Access  : GaxiaServer.Playtime  (server)
--   GaxiaServer.Playtime.Get(player)  --> seconds in this server
--   GaxiaServer.Playtime.OnMilestone:Connect(function(player, seconds) end)
--
-- Lifecycle: the module body only defines things. Init connects the player hooks,
-- Start runs the milestone loop. Boot = true in Packages.lua.
-- ─────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies (static requires only, all at the top) ──
local Shared    = ReplicatedStorage.Gaxia_Packages.Shared
local Signal    = require(Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)
local Config    = require(script.Parent.Parent.Config)

-- Economy is optional (its package may not be installed): Start finds it with
-- Lifecycle.Find. Only the members this service uses are typed.
type EconomyApi = { Add: (player: Player, currency: string, amount: number) -> boolean }

local PlaytimeService = {}

-- (player, seconds) each time a player has played another Config.Playtime.MilestoneSeconds
PlaytimeService.OnMilestone = Signal.new() :: Signal.Signal<Player, number>

-- ── State ──
local joinedAt: { [Player]: number } = {} -- os.clock() when the player joined
local reached: { [Player]: number } = {} -- milestones the player has reached

-- ── Public API ──

-- Seconds the player has been in this server (0 when the player is unknown).
function PlaytimeService.Get(player: Player): number
	local t = joinedAt[player]
	if t == nil then
		return 0
	end
	return os.clock() - t
end

-- ── Lifecycle ──

local function onPlayerAdded(player: Player): ()
	if joinedAt[player] == nil then
		joinedAt[player] = os.clock()
		reached[player] = 0
	end
end

local function onPlayerRemoving(player: Player): ()
	joinedAt[player] = nil
	reached[player] = nil
end

-- Runs on Start's own thread, forever (Start may yield).
local function milestoneLoop(): ()
	local Economy: EconomyApi? = Lifecycle.Find("Economy")
	local every = Config.Playtime.MilestoneSeconds
	local coins = Config.Playtime.RewardCoins
	while true do
		task.wait(1)
		for player, count in reached do
			local due = math.floor(PlaytimeService.Get(player) / every)
			if due > count then
				reached[player] = due
				PlaytimeService.OnMilestone:Fire(player, due * every)
				if Economy and coins > 0 then
					pcall(Economy.Add, player, "Coins", coins)
				end
			end
		end
	end
end

Lifecycle.Define(PlaytimeService, {
	Name = "Playtime",
	Needs = {},
	-- Sync, must not yield. Connect events here, never in the module body.
	Init = function()
		Players.PlayerAdded:Connect(onPlayerAdded)
		Players.PlayerRemoving:Connect(onPlayerRemoving)
		-- The service may start after players joined (first use): add them too.
		for _, player in Players:GetPlayers() do
			onPlayerAdded(player)
		end
	end,
	-- Own thread, after every Init of the batch. Loops and waits go here.
	Start = milestoneLoop,
})

return PlaytimeService
```

The comment line right above each function and signal becomes its description on the API page. Write it for game developers.

## Step 4 — Add the Config section

1. Create `src/ServerStorage/Gaxia_Packages_Server/Config/Playtime.lua`:

```lua
-- fragment: src/ServerStorage/Gaxia_Packages_Server/Config/Playtime.lua
--!strict
-- Config/Playtime.lua — PlaytimeService tunables
export type PlaytimeConfig = {
	MilestoneSeconds: number, -- OnMilestone fires each time a player has played this long again
	RewardCoins: number, -- Coins per milestone when the Economy package is installed (0 = none)
}

local Playtime: PlaytimeConfig = {
	MilestoneSeconds = 300,
	RewardCoins = 10,
}

return Playtime
```

2. In `src/ServerStorage/Gaxia_Packages_Server/Config/init.lua`, add this line just above the `Features = require(script.Features),` line:

```lua
-- fragment: add to src/ServerStorage/Gaxia_Packages_Server/Config/init.lua
	Playtime    = require(script.Playtime),
```

The `export type` gives GaxiaServer.Config.Playtime its type, so a typo is a type error. Config is Core: the new file needs no package entry.

## Step 5 — The rules every service follows

`node tools/check-architecture.mjs` enforces most of them (rule numbers in brackets).

| Rule | Why |
|---|---|
| The module body only defines things: requires, constants, tables, `Signal.new()`, functions. No `:Connect`, `Instance.new`, `task.spawn` or loops at the top level. [R4] | Requiring a service must never start it. |
| Every `require` is at the top, with a static path: `require(script.Parent.X)`, `require(Shared.Signal)`. Never inside a function, never through `WaitForChild` or a variable. [R3, R6] | `packages.mjs` reads requires to build each package's `Requires`. |
| Never require a loader (`Gaxia_Packages`, `Gaxia_Packages_Server`) and never `require(...) :: any`. [R1, R2] | Require the module you use, typed. |
| `Lifecycle.Define(...)` is the last statement before `return`, and every Lib service has one. [R5, R11] | Define wraps every function defined above it. |
| `Name` is in `Types.ServiceName`, `LIB_KEY_MAP` and `GaxiaServerPackage`. [R9] | The scaffold did this. |
| `Needs` lists only modules whose Init must run before yours. Each one is a top-level required local. [R10] | A service you only call later starts by itself on its first call. |
| `Init` is synchronous and never yields. It also adds the players already in the game. | A yield fails the service: `Init yielded — Init must not yield`. A failed Init is warned once and never retried. |
| `Start` runs on its own thread after every Init of the batch. Loops, waits and `Lifecycle.Find` go here. | Start may yield. |
| Index Config sections directly: `Config.Playtime.MilestoneSeconds`, never `(Config.Playtime or {})`. [R8] | The sections are typed. |

When it starts: at server boot when the game picked packages and the package has `Boot = true`, or when the game lists it in `ServerStorage.GaxiaFeatures`. A full install (this repo served with Rojo, no packages picked) boots the list in `Config/Features.lua` instead of `Boot = true`. Otherwise it starts when game code first touches **GaxiaServer.Playtime** or any of its functions is called. `AutoStart = false` in the spec turns those two off: then only boot or `GaxiaServer.Lifecycle.Ensure(module)` starts it (AntiCheat works this way).

Soft dependency: a static `require(script.Parent.EconomyService)` makes Economy a hard dependency (installing Playtime installs Economy). `GaxiaServer.Lifecycle.Find("Economy")` returns nil when Economy is not installed, so Playtime works alone. Call it in Start or a function, never in the body or Init, and give the result a small API type (`EconomyApi` above).

## Step 6 — Run the checks

```sh
node tools/packages.mjs fix
node tools/packages.mjs check
node tools/gen-api.mjs
node tools/gen-api.mjs --check
node tools/check-architecture.mjs --complete
```

Expected: `✓ Requires regenerated`, `✓ … catalogue matches the source`, `✓ wrote … pages`, `✓ playbooks/api is up to date`, `check-architecture: … 0 violation(s)`. `check-architecture` needs `luau-ast` on PATH (or `LUAU_AST=/path/to/luau-ast node tools/check-architecture.mjs --complete`).

Then type-check your files with both type solvers. Both commands must print nothing:

```sh
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src 2>&1 | grep -E "Lib/PlaytimeService|Config/(Playtime|init)"
luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src 2>&1 | grep -E "Lib/PlaytimeService|Config/(Playtime|init)"
```

Other files under `src/` already report some type errors. Do not fix them in this change.

## Check that it works

1. All the commands in Step 6 pass, and the two `grep` commands print nothing.
2. `playbooks/api/Playtime.md` lists `Playtime.Get(player: Player): number` and the signal `Playtime.OnMilestone`.
3. `git status` shows only: `Lib/PlaytimeService.lua`, `Config/Playtime.lua`, `Config/init.lua`, `Types.lua`, `init.lua`, `Packages.lua` and files in `playbooks/api/`.
4. In Studio: run `rojo serve`, connect, and add a test Script in **ServerScriptService** named **PlaytimeCheck**:

```lua
-- fragment: test Script ServerScriptService/PlaytimeCheck (delete it after the test)
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Playtime = GaxiaServer.Playtime
Playtime.OnMilestone:Connect(function(player: Player, seconds: number)
	print(`[PlaytimeCheck] {player.Name} played {seconds} s (Get = {math.floor(Playtime.Get(player))})`)
end)
print("[PlaytimeCheck] ready", GaxiaServer.IsEnabled("Playtime"))
```

5. Set `MilestoneSeconds = 5` for the test, press **Play**. Output shows `[PlaytimeCheck] ready true`, then `[PlaytimeCheck] <YourName> played 5 s (Get = 5)` every 5 seconds, and no red errors. Put `MilestoneSeconds` back to `300` and delete the test Script.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Creating the file by hand | `node scaffold.mjs new:service <Name>` | The scaffold also wires Types, the loader, Packages.lua and the API page. |
| `Players.PlayerAdded:Connect(...)` at the top of the module | Inside `Init` | R4: requiring the module must not start it. |
| `task.wait`, `WaitForChild` or `Lifecycle.Find` in `Init` | In `Start` | Init must not yield. |
| Only `Players.PlayerAdded` in Init | Also loop `Players:GetPlayers()` | A service that starts on first use missed the players already in the game. |
| `Needs = { EconomyService }` because a function calls Economy | `Needs = {}` | Economy starts itself on its first call. Needs is only for Init order. |
| `local Economy = require(script.Parent.EconomyService)` for an optional link | `Lifecycle.Find("Economy")` in Start | A static require installs Economy with every game that installs your package. |
| `require(game:GetService("ServerStorage").Gaxia_Packages_Server)` inside Lib | `require(script.Parent.X)` | R1: framework modules never require a loader. |
| Code after `Lifecycle.Define(...)` | Define last, then `return` | R5. Functions defined after Define are not wrapped. |
| Editing `playbooks/api/*.md` by hand | `node tools/gen-api.mjs` | The pages are generated. `--check` fails on hand edits. |
| Editing `Requires = { ... }` in Packages.lua by hand | `node tools/packages.mjs fix` | Requires is generated from the requires in the source. |

## Change it

- A plain API with no hooks or loop: leave out `--boot`. Remove `Init`/`Start` from the spec, or keep them small.
- To let operators change a value at runtime: read it with `EConfig.Get("Playtime.MilestoneSeconds", Config.Playtime.MilestoneSeconds)` (`local EConfig = require(script.Parent.EffectiveConfig)`).
- A remote for clients: create it in `Init` with `Net.OnServer` (`local Net = require(Shared.NetService)`), and add the client module ([change the framework](change-the-framework.md), Step 6).
- To boot it in a full install (no packages picked): add `"Playtime"` to `Config/Features.lua`. Picked installs boot it through `Boot = true`.
- Add a line to `CHANGELOG.md` under `## Unreleased` and, when games should use it, a playbook ([playbooks/WRITING.md](../WRITING.md)).

## See also

- [Change the framework safely](change-the-framework.md) · [Add an anti-cheat detector](add-an-anticheat-detector.md)
- [API: Lifecycle](../api/Core.ServiceLifecycle.md) · [API: Config](../api/Core.Config.md) · [API: Signal](../api/Core.Signal.md)
