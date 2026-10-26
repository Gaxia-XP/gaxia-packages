# Events between scripts, cleanup, timers and promises

> Server Scripts tell each other when something happens, everything made for a player is cleaned up when they leave, and timers, cooldowns and delayed steps run without leaks.

**Use this when** the user asks for: "an event between scripts", "Signal", "BindableEvent", "clean up when the player leaves", "Trove", "memory leak", "a timer", "run every N seconds", "debounce", "cooldown", "promise", "object pool" (ไทย: "ส่ง event ระหว่างสคริปต์", "ล้างของตอนผู้เล่นออก", "หน่วงเวลา", "ทำซ้ำทุก ๆ กี่วินาที", "คูลดาวน์", "กันกดรัว", "สัญญาณ", "หน่วยความจำรั่ว").
**Packages:** `Cooldown`, `Scheduler`, `Promise`, `Pool` (every script below stops with a clear message if one is missing). `Signal` and `Trove` are Core: always installed.
**You will create:** a ModuleScript `ServerStorage/GameModules/GameEvents`, Scripts `ServerScriptService/ChestServer`, `ServerScriptService/ChestRewards` and `ServerScriptService/PlayerTimers`.

## Which tool for which job

| You need | Use |
|---|---|
| One server Script tells other server Scripts "X happened" | a `Signal` in a ModuleScript (Step 1) |
| Server and client talk to each other | `Gaxia.Net`, never a Signal ([client-server communication](../start/04-client-server-communication.md)) |
| Remove everything made for a player when they leave | one `Trove` per player (Step 4) |
| Run code later, every N seconds, or not too often | `Scheduler.After` / `Every` / `Throttle` / `Debounce` |
| "A player may do X once every N seconds", decided by the server | `GaxiaServer.Cooldown` (Step 2) |
| A step that finishes later and must stop if the player leaves first | `Promise` (Step 4) |
| Many identical parts that appear and disappear | `Pool` (Step 3) |

## Step 1 — Create the GameEvents module (signals)

1. In **ServerStorage**, insert a **Folder** named **GameModules** (skip if it exists).
2. In **ServerStorage → GameModules**, insert a **ModuleScript** named **GameEvents**. Paste this whole block into it:

```lua
-- ModuleScript: ServerStorage/GameModules/GameEvents
-- Signals that server Scripts use to tell each other what happened.
-- This require gives the Signal type too (Gaxia.Signal is the same module).
local Signal = require(game:GetService("ReplicatedStorage").Gaxia_Packages.Shared.Signal)

local GameEvents = {
	-- Fired by ChestServer when a player opens a chest: (player, coins)
	ChestOpened = Signal.new() :: Signal.Signal<Player, number>,
}

return GameEvents
```

Why a ModuleScript: every Script that requires it gets the same table, so they share the same signals.

## Step 2 — Create ChestServer (server cooldown, fires the signal)

Create a **Script** in **ServerScriptService** named **ChestServer**:

```lua
-- Script: ServerScriptService/ChestServer
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local GameEvents = require(ServerStorage.GameModules.GameEvents)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Cooldown"), "ChestServer needs the Cooldown package: install it (playbooks/start/01-install-packages.md)")

local Cooldown = GaxiaServer.Cooldown

local CHEST_COOLDOWN = 10 -- seconds between two chests, per player
local CHEST_COINS = 25

-- A chest with a "press E" prompt, made by the server.
local chest = Instance.new("Part")
chest.Name = "Chest"
chest.Size = Vector3.new(4, 3, 3)
chest.Position = Vector3.new(0, 1.5, -12)
chest.Anchored = true
chest.Color = Color3.fromRGB(120, 80, 40)
chest.Parent = workspace

local prompt = Instance.new("ProximityPrompt")
prompt.ActionText = "Open"
prompt.ObjectText = "Chest"
prompt.Parent = chest

prompt.Triggered:Connect(function(player: Player)
	-- One call checks AND starts the cooldown. false = still cooling down.
	if not Cooldown.ConsumePlayer(player, "ChestOpen", CHEST_COOLDOWN) then
		local left = Cooldown.GetPlayerRemaining(player, "ChestOpen")
		print(`[ChestServer] {player.Name} must wait {math.ceil(left)} s`)
		return
	end
	print(`[ChestServer] {player.Name} opened a chest`)
	GameEvents.ChestOpened:Fire(player, CHEST_COINS) -- every Script connected to it runs now
end)

print("[ChestServer] ready")
```

## Step 3 — Create ChestRewards (listens to the signal, pools parts)

Create a **Script** in **ServerScriptService** named **ChestRewards**:

```lua
-- Script: ServerScriptService/ChestRewards
local ServerStorage = game:GetService("ServerStorage")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local GameEvents = require(ServerStorage.GameModules.GameEvents)

assert(Gaxia.IsInstalled("Pool"), "ChestRewards needs the Pool package: install it (playbooks/start/01-install-packages.md)")
assert(Gaxia.IsInstalled("Scheduler"), "ChestRewards needs the Scheduler package: install it (playbooks/start/01-install-packages.md)")

local Pool = Gaxia.Pool
local Scheduler = Gaxia.Scheduler

-- Reuse coin parts instead of creating and destroying one every time.
local coinPool = Pool.new(function(): Part
	local part = Instance.new("Part")
	part.Name = "ChestCoin"
	part.Size = Vector3.new(2, 2, 0.4)
	part.Color = Color3.fromRGB(255, 200, 0)
	part.Anchored = true
	part.CanCollide = false
	return part
end, function(part: Part)
	part.Parent = nil -- hidden until the next Get
end)
coinPool.PreWarm(5)

GameEvents.ChestOpened:Connect(function(player: Player, coins: number)
	print(`[ChestRewards] {player.Name} gets {coins} coins`)
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end
	local coin = coinPool.Get()
	coin.CFrame = root.CFrame + Vector3.new(0, 5, 0)
	coin.Parent = workspace
	-- Give the part back to the pool after 2 seconds.
	Scheduler.After(2, function()
		coinPool.Return(coin)
	end)
end)

print("[ChestRewards] ready")
```

Pool functions use a dot: `coinPool.Get()`, `coinPool.Return(coin)`. Signals use a colon: `GameEvents.ChestOpened:Connect(...)`.

## Step 4 — Create PlayerTimers (one Trove per player, timers, promises)

Create a **Script** in **ServerScriptService** named **PlayerTimers**:

```lua
-- Script: ServerScriptService/PlayerTimers
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("Scheduler"), "PlayerTimers needs the Scheduler package: install it (playbooks/start/01-install-packages.md)")
assert(Gaxia.IsInstalled("Promise"), "PlayerTimers needs the Promise package: install it (playbooks/start/01-install-packages.md)")

-- Types only (part of the Promise package): lets a function say "this returns a promise of a string".
local PromiseTypes = require(game:GetService("ReplicatedStorage").Gaxia_Packages.Shared.PromiseTypes)

local Trove = Gaxia.Trove
local Scheduler = Gaxia.Scheduler
local Promise = Gaxia.Promise

local PLAYTIME_STEP = 10 -- seconds between two playtime prints

-- One Trove per player. Everything made for that player goes into it.
local troves: { [Player]: typeof(Trove.new()) } = {}

-- A promise that resolves with the player's name after `seconds`.
-- Gaxia.Promise has no types of its own. So every promise is made in a helper like
-- this one: the `any` local is returned as a PromiseTypes type, and the rest is checked.
local function welcomeAfter(player: Player, seconds: number): PromiseTypes.Promise<string>
	local promise: any = Promise.new(function(resolve)
		task.delay(seconds, resolve, player.Name)
	end)
	return promise
end

local function onPlayerAdded(player: Player)
	if troves[player] then
		return -- already handled
	end
	local trove = Trove.new()
	troves[player] = trove

	-- 1. A repeating timer. Scheduler.Every returns a function that stops it.
	local played = 0
	local stopPlaytime = Scheduler.Every(PLAYTIME_STEP, function()
		played += PLAYTIME_STEP
		print(`[PlayerTimers] {player.Name} has played {played} s`)
	end)
	trove:Add(function() -- the Trove runs this function when it is cleaned
		stopPlaytime()
	end)

	-- 2. A connection to a Roblox event. The Trove disconnects it.
	trove:Connect(player.CharacterAdded, function()
		print(`[PlayerTimers] {player.Name} spawned`)
	end)

	-- 3. An Instance made for this player. The Trove destroys it.
	local marker = Instance.new("Folder")
	marker.Name = `{player.Name}_Timers`
	marker.Parent = workspace
	trove:Add(marker)

	-- 4. A promise. The Trove cancels it if the player leaves before it finishes.
	local welcome = welcomeAfter(player, 3):andThen(function(name: string)
		print(`[PlayerTimers] welcome, {name}`)
	end)
	trove:Add(function()
		welcome:cancel()
	end)
end

local function onPlayerRemoving(player: Player)
	local trove = troves[player]
	if trove == nil then
		return
	end
	troves[player] = nil -- forget the player, or this table grows forever
	trove:Destroy() -- cancels the timer, disconnects, destroys the folder, cancels the promise
	print(`[PlayerTimers] cleaned up {player.Name}`)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[PlayerTimers] ready")
```

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[ChestServer] ready`, `[ChestRewards] ready` and `[PlayerTimers] ready`, and no red errors.
3. About 3 seconds later Output shows `[PlayerTimers] welcome, <YourName>`. Every 10 seconds: `[PlayerTimers] <YourName> has played 10 s` (then 20 s, …).
4. Walk to the brown block (the chest) and press **E**. Output shows `[ChestServer] <YourName> opened a chest` and `[ChestRewards] <YourName> gets 25 coins`. A gold block appears above you for 2 seconds.
5. Press **E** again at once. Output shows `[ChestServer] <YourName> must wait N s` (N is 10 or less).
6. Press **Stop**. Output shows `[PlayerTimers] cleaned up <YourName>`, and the playtime prints stop.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `local ChestOpened = Gaxia.Signal.new()` inside a Script | The signal in the `GameEvents` ModuleScript | Other Scripts cannot reach a local of a Script. |
| A Signal to talk to the client | `Gaxia.Net` (`Net.FireClient`, `Net.OnServer`) | Signals never cross between server and client. |
| `GameEvents.ChestOpened.Fire(player, 25)` | `GameEvents.ChestOpened:Fire(player, 25)` | Signal and Trove methods use a colon. |
| `coinPool:Get()`, `coinPool:Return(coin)` | `coinPool.Get()`, `coinPool.Return(coin)` | Pool functions use a dot. `coinPool:Return(coin)` puts the pool table in itself. |
| `player.CharacterAdded:Connect(...)` inside `onPlayerAdded` | `trove:Connect(player.CharacterAdded, ...)` | A connection you never disconnect leaks. The Trove disconnects it on leave. |
| `Scheduler.Every(...)` or `while true do task.wait(10) ... end` per player, never stopped | `trove:Add(function() stopPlaytime() end)` | The timer keeps running after the player left. |
| `trove:Add(stopPlaytime)` or `trove:AddPromise(welcome)` | `trove:Add(function() stopPlaytime() end)`, `trove:Add(function() welcome:cancel() end)` | Both run, but Script Analysis reports a type error. A new function always type-checks. |
| `trove:Destroy()` but `troves[player]` kept | `troves[player] = nil`, then `trove:Destroy()` | The table keeps every player who ever joined. |
| `Promise.delay(3)` or `Promise.new(...):andThen(...)` used directly | Make the promise in a helper typed `PromiseTypes.Promise<...>` (like `welcomeAfter`) | `Gaxia.Promise` has no types: Script Analysis (new type solver) reports errors on its functions. |
| `welcomeAfter(player, 3):expect()` | `local ok, name = welcomeAfter(player, 3):await()`, then check `ok` | `expect` throws an error when the promise fails or is cancelled. |
| `if not Cooldown.IsPlayerActive(...) then Cooldown.Start(...) end` | `if Cooldown.ConsumePlayer(player, "ChestOpen", 10) then` | One call checks and starts the cooldown. |
| The cooldown only in a LocalScript | `GaxiaServer.Cooldown` on the server | A cheater skips client code. |
| `GaxiaServer.Cooldown` for a daily reward | Save the time in player data, or use `DailyReward` ([live ops](live-ops.md)) | Per-player cooldowns are cleared when the player leaves and when the server restarts. |
| `GameEvents.ChestOpened:Wait()` at the top of a Script | `GameEvents.ChestOpened:Once(fn)` | `Wait` stops the script until the next fire, maybe forever. |
| Expecting `Scheduler.Every(10, fn)` to run `fn` at once | Call `fn()` yourself first | The first run is after 10 seconds. |

## Change it

- To react only to the next fire: `GameEvents.ChestOpened:Once(function(player, coins) ... end)`.
- To stop one listener: `local connection = GameEvents.ChestOpened:Connect(fn)`, later `connection:Disconnect()`. All listeners: `GameEvents.ChestOpened:DisconnectAll()`.
- To give real coins: in `ChestRewards`, call `GaxiaServer.Economy.Add(player, "Coins", coins)` ([coins and leaderstats](currency-and-leaderstats.md)).
- To run code 5 seconds from now and maybe cancel it: `local cancel = Scheduler.After(5, fn)`, later `cancel()`.
- To save only after the player stops clicking for 2 seconds: `local saveSoon = Scheduler.Debounce(function(player: Player) ... end, 2)`, then call `saveSoon(player)` on every click.
- To wait for a promise inside a function that may wait: `local ok, name = welcomeAfter(player, 3):await()`.
- One cooldown for the whole server (a boss): `Cooldown.Consume("BossSpawn", 300)`.
- To clean up when a part is destroyed instead of when a player leaves: `trove:AttachToInstance(part)`.
- To stop a client button from sending more than one request per second: wrap the send in `Scheduler.Throttle(fn, 1)`. The server still decides.
- On the client: make a Trove when a menu opens and `trove:Destroy()` it when the menu closes.

## See also

- [API: Signal](../api/Core.Signal.md) · [API: Trove](../api/Core.Trove.md) · [API: Scheduler](../api/Scheduler.md) · [API: Cooldown](../api/Cooldown.md) · [API: Promise](../api/Promise.md) · [API: Pool](../api/Pool.md)
- [Write your first server script](../start/02-server-script.md) · [Client ↔ server communication](../start/04-client-server-communication.md)
- [Effects and feel](effects-and-feel.md) · [Troubleshooting](../troubleshooting.md)
