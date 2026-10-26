# Write your first server script

> The game has a `GameServer` Script that runs code for every player when they join, once their saved data is loaded, and when they leave.

**Use this when** the user asks for: "a server script", "run code when a player joins", "where do I put server code", "use GaxiaServer", "wait for player data" (ไทย: "สคริปต์ฝั่ง server", "ทำอะไรตอนผู้เล่นเข้าเกม", "เขียนโค้ดฝั่งเซิร์ฟเวอร์", "รอข้อมูลผู้เล่นโหลด").
**Packages:** `Data` (the script below stops with a clear message if it is missing).
**You will create:** a ModuleScript `ServerStorage/GameModules/GameSettings` and a Script `ServerScriptService/GameServer`.

## Where server code goes

| Code | Put it in | Type | File name with Rojo |
|---|---|---|---|
| Code that runs by itself (one per feature) | `ServerScriptService` | **Script** | `ServerScriptService/GameServer.server.lua` |
| Settings and helpers that several Scripts share | `ServerStorage/GameModules` (a Folder) | **ModuleScript** | `ServerStorage/GameModules/GameSettings.lua` |

Without Rojo, create the same names in Studio. With Rojo, `.server.lua` makes a Script and plain `.lua` makes a ModuleScript; map the folders in the game's own `default.project.json`.

Never put game code inside `Gaxia_Packages_Server` or `Gaxia_Packages`: Install / Update replaces them.

## Step 1 — Create the GameModules folder and a settings module

1. In **ServerStorage**, insert a **Folder**. Name it **GameModules**.
2. In **ServerStorage → GameModules**, insert a **ModuleScript**. Name it **GameSettings**.
3. Paste this whole block into it:

```lua
-- ModuleScript: ServerStorage/GameModules/GameSettings
-- Game settings shared by the server Scripts. Change the values here, not in the Scripts.
local GameSettings = {
	-- How long (seconds) to wait for a player's saved data before kicking them.
	-- A quick rejoin from another server can take about a minute to load.
	DataWaitSeconds = 90,
	-- Printed when a player's data is ready.
	WelcomeText = "Welcome back",
}

return GameSettings
```

What it does: keeps values in one place. Any server Script can `require` it.

## Step 2 — Create the GameServer Script

Create a **Script** in **ServerScriptService** named **GameServer**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/GameServer
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local GameSettings = require(ServerStorage.GameModules.GameSettings)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Data"), "GameServer needs the Data package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data

-- Per-player state. Every entry is removed when the player leaves.
local joinedAt: { [Player]: number } = {}

-- Runs once for every player, on its own thread (it may wait).
local function onPlayerAdded(player: Player)
	if joinedAt[player] then
		return -- already handled
	end
	joinedAt[player] = os.clock()
	print(`[GameServer] {player.Name} joined`)

	-- Wait until the saved data is loaded. nil = the player left or loading took too long.
	local data = Data.WaitFor(player, GameSettings.DataWaitSeconds)
	if data == nil then
		if player.Parent ~= nil then
			-- Still in the game but the data never loaded: do not let them play without it.
			warn(`[GameServer] data for {player.Name} timed out - kicking`)
			player:Kick("Your data could not load. Please rejoin.")
		end
		return
	end

	local coins: number = Data.Get(player, "Coins")
	local level: number = Data.Get(player, "Level")
	print(`[GameServer] {GameSettings.WelcomeText}, {player.Name}: data ready (Coins = {coins}, Level = {level})`)
end

local function onPlayerRemoving(player: Player)
	local startedAt = joinedAt[player]
	joinedAt[player] = nil -- clean up, or this table grows forever
	if startedAt then
		print(`[GameServer] {player.Name} left after {math.floor(os.clock() - startedAt)} seconds`)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Players who joined before this Script ran (it happens in Studio and on busy servers).
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[GameServer] ready")
```

What it does: handles every player exactly once, waits for their data, and forgets them when they leave.
Why `Players.PlayerAdded` plus the loop: a signal only reaches handlers that were connected before it fired, so the loop catches players who were already in the game.
Why the kick: the data may still load later, but this setup code would never run again for that player.

Type `GaxiaServer.` or `Data.` in Studio: autocomplete lists the installed services and their functions (`local Data = GaxiaServer.Data` is typed).
A name that is not offered does not exist or is not installed. Look it up in [api/INDEX.md](../api/INDEX.md); never guess.

## How services start (read once)

- `Gaxia_ServerBootstrap` (installed in Step 2 of [Install packages](01-install-packages.md)) boots the framework when the server starts.
- **Boot services** are already running when your Script runs: every server package you picked, plus every installed package marked "Boot" (`Data`, `Player`, `Monetization`, …). In a full install (**All**) or with `ServerStorage/GaxiaFeatures`, that list decides instead.
- Every other installed service starts the first time your code uses it (`GaxiaServer.<Name>`). If your Script runs before the bootstrap, that first use boots the framework.
- So the order in which Roblox runs your Scripts does not matter. You never call a start or init function.
- `GaxiaServer.IsInstalled("X")` = the package is in this place. `GaxiaServer.IsEnabled("X")` = the service has started. Neither one loads anything.

```lua
-- fragment
print(GaxiaServer.IsInstalled("Economy"), GaxiaServer.IsEnabled("Economy"))
```

## How to organize a bigger game

- One **Script** per feature in `ServerScriptService` (`GameServer`, `CoinRewards`, `ShopServer`, …). Every playbook works this way.
- Code used by two or more Scripts goes in a **ModuleScript** in `ServerStorage/GameModules` that returns a table of functions. Each Script requires it with `require(ServerStorage.GameModules.<Name>)`, like `GameSettings` above.
- Each Script starts with the same require line and its own `assert(GaxiaServer.IsInstalled(...))` checks.

## Check that it works

If you cannot press Play: run the `luau-lsp analyze` command from AGENTS.md section 5 (no `TypeError`), then ask the user to press Play and paste the Output lines below.

1. Press **Play** in Studio.
2. Output shows `[GameServer] ready` and no red errors.
3. Output shows `[GameServer] <your name> joined`, then `[GameServer] Welcome back, <your name>: data ready (Coins = 0, Level = 1)`.
4. `[GameServer] <your name> left after N seconds` prints when a player leaves a running server. Pressing **Stop** in Studio may end the session before it prints: that is not an error.
5. If Output shows `[ProfileService]: Roblox API services unavailable - data will not be saved`, that is expected in an unpublished place. Play works, but nothing is saved. Ask the user to publish the place and turn on **Game Settings → Security → Enable Studio Access to API Services** ([Player data](../game/player-data.md)).

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `require(ServerStorage.Gaxia_Packages_Server) :: any` | `require(game:GetService("ServerStorage").Gaxia_Packages_Server)` | `:: any` turns off type checking and autocomplete. |
| `require(...Gaxia_Packages_Server.init)` | `require(game:GetService("ServerStorage").Gaxia_Packages_Server)` | There is no child named `init`. |
| Calling `Init()`, `Start()` or `GaxiaServer.Boot()` in game code | Just use the service | Services start by themselves. |
| Only `GaxiaServer.Player.OnPlayerJoined:Connect(...)` | `Players.PlayerAdded` + the `Players:GetPlayers()` loop | `OnPlayerJoined` does not fire again for players who joined before you connected. |
| `Data.OnLoaded:Connect(...)` to set up each player | `Data.WaitFor(player)` inside `onPlayerAdded` | `OnLoaded` misses players whose data loaded before you connected. |
| `Data.Get(player, "Coins")` right after the player joins | `Data.WaitFor(player)` first | Data loads a moment later; before that `Get` returns nil. |
| Not checking `if data == nil then` | Keep the check | `WaitFor` returns nil when the player left or the wait timed out. |
| Only `return` when `WaitFor` timed out | Kick the player when `player.Parent ~= nil` (Step 2) | Data can still load later; your setup code would never run for them. |
| `repeat task.wait() until Data.IsLoaded(player)` | `Data.WaitFor(player, GameSettings.DataWaitSeconds)` | The loop never ends if the player leaves. |
| `DataStoreService:GetDataStore(...)` | `GaxiaServer.Data` | Gaxia handles saving, session locks and retries. |
| Editing a module inside `Gaxia_Packages_Server` | A ModuleScript in `ServerStorage/GameModules` | Install / Update replaces the framework and your change is lost. |
| A Script inside `ServerStorage` | A Script in `ServerScriptService` | Scripts in ServerStorage never run. |
| Error `GameModules is not a valid member of ServerStorage` | A **Folder** named exactly `GameModules` in ServerStorage (Step 1) | The require path must match the Explorer exactly. |
| Script Analysis: `Key 'Economy' not found` | Install the `Economy` package | The types list only installed packages. |

## Change it

- To run code on every spawn (first spawn and respawns): above `onPlayerAdded`, add this function. Then inside `onPlayerAdded`, right after the `joined` print and **before** `Data.WaitFor`, add the two lines below it (after the wait, the first spawn is already missed). To also disconnect on leave with a Trove, see [Signals, cleanup and timing](../game/signals-cleanup-and-timing.md).

```lua
-- fragment
local function onCharacterAdded(character: Model)
	print(`[GameServer] {character.Name} spawned`)
end
```

```lua
-- fragment
player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then task.spawn(onCharacterAdded, player.Character) end
```

- To wait longer for data before the kick: change `DataWaitSeconds = 90` in `GameSettings`.
- To add another feature: create a new Script in `ServerScriptService` with the same require line. Do not grow `GameServer` forever.
- To share functions between Scripts: create a ModuleScript in `ServerStorage/GameModules` (here `Rewards`), then `local Rewards = require(ServerStorage.GameModules.Rewards)` in each Script:

```lua
-- fragment
local Rewards = {}
function Rewards.Give(player: Player, amount: number)
	print(`[Rewards] {player.Name} gets {amount}`)
end
return Rewards
```

## See also

- [Install packages](01-install-packages.md)
- [Write your first client script](03-client-script.md)
- [Client ↔ server communication](04-client-server-communication.md)
- [Player data](../game/player-data.md)
- [Signals, cleanup and timing](../game/signals-cleanup-and-timing.md)
- [API: Data](../api/Data.md) · [API: Player](../api/Player.md) · [API: Lifecycle](../api/Core.ServiceLifecycle.md)
