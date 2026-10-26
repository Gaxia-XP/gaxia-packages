# Write your first server script

> The game has a `GameServer` Script that runs code for every player when they join, once their saved data is loaded, and when they leave.

**Use this when** the user asks for: "a server script", "run code when a player joins", "where do I put server code", "use GaxiaServer", "wait for player data" (ไทย: "สคริปต์ฝั่ง server", "ทำอะไรตอนผู้เล่นเข้าเกม", "เขียนโค้ดฝั่งเซิร์ฟเวอร์", "รอข้อมูลผู้เล่นโหลด").
**Packages:** `Data` (the script below stops with a clear message if it is missing).
**You will create:** a ModuleScript `ServerStorage/GameModules/GameSettings` and a Script `ServerScriptService/GameServer`.

## Where server code goes

| Code | Put it in | Type |
|---|---|---|
| Code that runs by itself (one per feature) | `ServerScriptService` | **Script** |
| Settings and helpers that several Scripts share | `ServerStorage/GameModules` (a Folder) | **ModuleScript** |

Never put game code inside `Gaxia_Packages_Server` or `Gaxia_Packages`: Install / Update replaces them.

## Step 1 — Create the GameModules folder and a settings module

1. In **ServerStorage**, insert a **Folder**. Name it **GameModules**.
2. In **ServerStorage → GameModules**, insert a **ModuleScript**. Name it **GameSettings**.
3. Paste this whole block into it:

```lua
-- ModuleScript: ServerStorage/GameModules/GameSettings
-- Game settings shared by the server Scripts. Change the values here, not in the Scripts.
local GameSettings = {
	-- How long (seconds) to wait for a player's saved data before giving up.
	DataWaitSeconds = 30,
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
		warn(`[GameServer] no data for {player.Name} (left or timed out)`)
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

## How services start (read once)

- `GaxiaServer.<Name>` gives you a service. The first time any Script touches a service, the framework boots.
- **Boot services** start at server boot: every package you picked, plus every installed package marked "Boot" (`Data`, `Player`, `Monetization`, …). Details: [Install packages](01-install-packages.md).
- Every other installed service starts the first time your code uses it.
- So the order in which Roblox runs your Scripts does not matter. You never call a start or init function.
- `GaxiaServer.IsInstalled("X")` = the package is in this place. `GaxiaServer.IsEnabled("X")` = the service has started. Neither one loads anything.

```lua
-- fragment
print(GaxiaServer.IsInstalled("Economy"), GaxiaServer.IsEnabled("Economy"))
```

## How to organize a bigger game

- One **Script** per feature in `ServerScriptService` (`GameServer`, `CoinRewards`, `ShopServer`, …). Every playbook works this way.
- Shared settings and helper functions go in **ModuleScripts** under `ServerStorage/GameModules`. Scripts `require` them, like `GameSettings` above.
- Each Script starts with the same require line and its own `assert(GaxiaServer.IsInstalled(...))` checks.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[GameServer] ready` and no red errors.
3. Output shows `[GameServer] <your name> joined`, then `[GameServer] Welcome back, <your name>: data ready (Coins = 0, Level = 1)`.
4. Press **Stop**. Output shows `[GameServer] <your name> left after N seconds`.
5. Output shows `[ProfileService]: Roblox API services unavailable - data will not be saved`? Play still works, but nothing is saved. To save in Studio, publish the place and turn on **Game Settings → Security → Enable Studio Access to API Services**.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `require(ServerStorage.Gaxia_Packages_Server) :: any` | `require(game:GetService("ServerStorage").Gaxia_Packages_Server)` | `:: any` turns off type checking and autocomplete. |
| `require(...Gaxia_Packages_Server.init)` | `require(game:GetService("ServerStorage").Gaxia_Packages_Server)` | There is no child named `init`. |
| Calling `Init()`, `Start()` or `GaxiaServer.Boot()` in game code | Just use the service | Services start by themselves. |
| Only `GaxiaServer.Player.OnPlayerJoined:Connect(...)` | `Players.PlayerAdded` + the `Players:GetPlayers()` loop | `OnPlayerJoined` does not fire again for players who joined before you connected. |
| `Data.OnLoaded:Connect(...)` to set up each player | `Data.WaitFor(player)` inside `onPlayerAdded` | `OnLoaded` misses players whose data loaded before you connected. |
| `Data.Get(player, "Coins")` right after the player joins | `Data.WaitFor(player)` first | Data loads a moment later; before that `Get` returns nil. |
| Not checking `if data == nil then return end` | Keep the check | `WaitFor` returns nil when the player left or the wait timed out. |
| `repeat task.wait() until Data.IsLoaded(player)` | `Data.WaitFor(player, 30)` | The loop never ends if the player leaves. |
| `DataStoreService:GetDataStore(...)` | `GaxiaServer.Data` | Gaxia handles saving, session locks and retries. |
| Editing a module inside `Gaxia_Packages_Server` | A ModuleScript in `ServerStorage/GameModules` | Install / Update replaces the framework and your change is lost. |
| A Script inside `ServerStorage` | A Script in `ServerScriptService` | Scripts in ServerStorage never run. |
| Error `GameModules is not a valid member of ServerStorage` | A **Folder** named exactly `GameModules` in ServerStorage (Step 1) | The require path must match the Explorer exactly. |
| Script Analysis: `Key 'Economy' not found` | Install the `Economy` package | The types list only installed packages. |

## Change it

- To run code on every respawn: inside `onPlayerAdded`, add `player.CharacterAdded:Connect(function(character) ... end)`.
- To wait longer for data: change `DataWaitSeconds = 30` in `GameSettings`.
- To add another feature: create a new Script in `ServerScriptService` with the same require line. Do not grow `GameServer` forever.

## See also

- [Install packages](01-install-packages.md)
- [Write your first client script](03-client-script.md)
- [Client ↔ server communication](04-client-server-communication.md)
- [Player data](../game/player-data.md)
- [Signals, cleanup and timing](../game/signals-cleanup-and-timing.md)
- [API: Data](../api/Data.md) · [API: Player](../api/Player.md) · [API: Lifecycle](../api/Core.ServiceLifecycle.md)
