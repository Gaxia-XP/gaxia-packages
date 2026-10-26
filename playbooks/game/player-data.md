# Save and load player data

> Every player has saved fields of your own (wins, unlocked areas, play time) that load when they join and save by themselves.

**Use this when** the user asks for: "save player data", "save progress", "DataStore", "remember X when the player comes back", "add a saved field", "data migration" (ไทย: "เซฟข้อมูลผู้เล่น", "บันทึกความคืบหน้า", "เก็บข้อมูลไว้ตอนออกเกม", "เพิ่มข้อมูลที่ต้องเซฟ", "ดาต้าสโตร์").
**Packages:** `Data` (it also installs `Migration`). The script below stops with a clear message if it is missing.
**You will create:** the Scripts `ServerScriptService/PlayerStats`, `ServerScriptService/PlayTimeTracker` and (only when you change saved data later) `ServerScriptService/DataMigrations`.

How it works:

- `GaxiaServer.Data` loads a player's data a moment **after** they join, and saves it by itself: every 30 seconds, when they leave, and when the server shuts down.
- Read with `Data.Get(player, "Key")`, write with `Data.Set(player, "Key", value)`. `Data.Set` can create a new key. New keys are saved like the built-in ones.
- Before the data is loaded, `Data.Get` returns `nil` and `Data.Set` returns `false` (nothing is written). Always wait first: `Data.WaitFor(player, 120)` (it returns `nil` if the player leaves or 120 seconds pass).
- Your own fields are added by `PlayerStats` (Step 1) just after the load. Other scripts can run first, so they read your fields with a default: `Data.Get(player, "Wins") or 0`.
- Built-in fields: `Coins`, `Gems`, `Level`, `Experience`, `Inventory`, `Settings`, `PlayTime`, `LastLogin`, `__version`.
- Names other packages save under (never use them for your own fields): `Quests`, `Achievements`, `Inv`, `Pets`, `Daily`, `Mailbox`, `Vault`, `VaultCapacity`, `Codex`, `LootPity`, `Placements`, `RefineJobs`, `IdleLastSeen`, `ProtectedUntil`, `RaidRevenge`, `ProcessedReceipts`, `Social`.

## Step 1 — Add your own saved fields

Create a **Script** in **ServerScriptService** named **PlayerStats**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/PlayerStats
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Data"), "PlayerStats needs the Data package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data

-- Your game's own saved fields and their starting values.
-- A function, so every player gets NEW tables (never one table shared by all players).
-- Save only numbers, strings, booleans and tables of them, with string keys.
local function newDefaults(): { [string]: any }
	return {
		Wins = 0,
		Visits = 0,
		Unlocked = {}, -- for example { Desert = true }
	}
end

-- Give the player every field they do not have yet (new players, or fields added in an update).
local function addMissingFields(player: Player)
	for key, value in newDefaults() do
		if Data.Get(player, key) == nil then
			Data.Set(player, key, value)
		end
	end
end

local function onPlayerAdded(player: Player)
	-- Wait until the data is loaded. nil means the player left (or it took over 120 seconds).
	local data = Data.WaitFor(player, 120)
	if data == nil then
		return
	end
	addMissingFields(player)

	local visits: number = Data.Get(player, "Visits") + 1
	Data.Set(player, "Visits", visits)
	print(`[PlayerStats] {player.Name} loaded: Wins = {Data.Get(player, "Wins")}, visit #{visits}, PlayTime = {Data.Get(player, "PlayTime")}`)
end

-- Players who join later, and players who are already in the game.
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[PlayerStats] ready")
```

What it does: when a player's data is loaded, it adds your fields if missing, then counts the visit.

## Step 2 — Change a saved value while the game runs

Create a **Script** in **ServerScriptService** named **PlayTimeTracker**:

```lua
-- Script: ServerScriptService/PlayTimeTracker
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Data"), "PlayTimeTracker needs the Data package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local STEP_SECONDS = 10

print("[PlayTimeTracker] ready")

-- This loop never ends, so it is the last thing in the script.
while true do
	task.wait(STEP_SECONDS)
	for _, player in Players:GetPlayers() do
		-- Skip players whose data is not loaded yet.
		if Data.IsLoaded(player) then
			local playTime: number = Data.Get(player, "PlayTime") + STEP_SECONDS
			Data.Set(player, "PlayTime", playTime)
			print(`[PlayTimeTracker] {player.Name} has played {playTime} seconds`)
		end
	end
end
```

What it does: every 10 seconds it adds 10 to the built-in `PlayTime` field of every loaded player.
`PlayTime` has no package of its own, so `Data.Set` is correct here. Currencies such as `Coins` and `Gems` must go through `Economy` instead.

Use the same pattern anywhere on the server (for example when a round is won). Read your own fields with `or 0`:

```lua
-- fragment
if Data.IsLoaded(player) then
	Data.Set(player, "Wins", (Data.Get(player, "Wins") or 0) + 1)
end
```

## Step 3 — (Only when you change saved data in an update) Upgrade old saves

Do this step only when a field changes its meaning or shape after players already have saves.
Example: `Unlocked` used to be a list `{ "Desert", "Snow" }`, and now it is `{ Desert = true, Snow = true }`.

Create a **Script** in **ServerScriptService** named **DataMigrations**:

```lua
-- Script: ServerScriptService/DataMigrations
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Migration"), "DataMigrations needs the Migration package: install it (playbooks/start/01-install-packages.md)")

local Migration = GaxiaServer.Migration

-- Version 1 -> 2: "Unlocked" changes from a list to a set.
-- This also runs for brand-new players (their data starts at version 1), so it must work
-- when the field is missing.
Migration.Register(1, 2, function(data: { [string]: any })
	local unlocked = data.Unlocked
	if typeof(unlocked) == "table" and #unlocked > 0 then
		local set: { [string]: boolean } = {}
		for _, areaName in unlocked do
			set[areaName] = true
		end
		data.Unlocked = set
	end
end)

-- The newest version. Raise it by 1 each time you add a step.
Migration.SetCurrentVersion(2)

print(`[DataMigrations] ready, data version {Migration.GetCurrentVersion()}`)
```

What it does: registered steps run when a save loads, before `Data.Get` returns it.
Keep `DataMigrations` free of any `task.wait` or other wait, so it registers before the first player loads.
Keep every old step forever. The next change is `Migration.Register(2, 3, ...)` and `Migration.SetCurrentVersion(3)`.

If a step is missing or errors, Output shows one of these warnings, and the player joins with the data as it was before that step:

- `[DataMigration] No migration registered from v1 -> target v2. Chain incomplete.`: add the missing `Migration.Register(1, 2, ...)`.
- `[DataMigration] Migration v1 -> v2 failed: <error>`: fix the error in that function.

Nothing is reset or deleted. The save keeps its old version, so the step runs again on the next join. A step that errors halfway may already have changed part of the data, so write every step so it is safe to run twice. Fix the script, then stop and press **Play** again. More help: [troubleshooting](../troubleshooting.md).

## Check that it works

1. In Studio open **Game Settings** (Home tab) **→ Security** and turn on **Enable Studio Access to API Services**. The place must be published first (**File → Publish to Roblox**). If you cannot click in Studio, tell the user to do this item and wait for their answer before item 2. Without it, Output shows `[ProfileService]: Roblox API services unavailable - data will not be saved` and data resets on every Play (items 2 to 4 still work; item 5 shows `visit #1` again).
2. Press **Play**. Output shows `[PlayerStats] ready`, `[PlayTimeTracker] ready` (and `[DataMigrations] ready, data version 2` if you did Step 3), and no red errors.
3. Within a few seconds Output shows `[PlayerStats] <YourName> loaded: Wins = 0, visit #1, PlayTime = 0`.
4. After 10 seconds Output shows `[PlayTimeTracker] <YourName> has played 10 seconds`.
5. Wait until the line of item 4 appears, then stop and press **Play** again. Output shows `visit #2` and `PlayTime = 10` (or more). The data was saved.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `DataStoreService:GetDataStore(...)` for player data | `Data.Get` / `Data.Set` | Data already saves with session locking. A second store can overwrite it and lose progress. |
| `Data.Get(player, "Wins")` in `PlayerAdded` right away | `Data.WaitFor(player, 120)` first | Data loads after the player joins. Before that `Get` returns `nil` and `Set` returns `false`. |
| `Data.Get(player, "Wins") + 1` in any script except `PlayerStats` | `(Data.Get(player, "Wins") or 0) + 1` | Your own fields can be missing for a moment after the load (and inside `Data.OnLoaded`): `attempt to perform arithmetic (add) on nil`. |
| `local DEFAULTS = { Unlocked = {} }` copied to every player | `newDefaults()` returns new tables each call | One shared table: unlocking for one player unlocks for all. |
| Saving an `Instance`, `Vector3`, `CFrame` or `Color3` | Save numbers: `{ X = 1, Y = 2, Z = 3 }`, or the part's name | DataStores save only numbers, strings, booleans and tables. Other values are lost or the save fails. |
| `{ [player.UserId] = true }` or a list with holes | String keys: `{ [tostring(player.UserId)] = true }` | Tables with number keys that are not a list 1, 2, 3 cannot be saved. |
| `Data.Set(player, "Coins", 100)` | `GaxiaServer.Economy.Set(player, "Coins", 100)` to set the balance (or `GaxiaServer.Economy.Add` to give) | Economy fires `OnTransaction`, which updates leaderstats. See [currency-and-leaderstats](currency-and-leaderstats.md). |
| Your field named `Level`, `Inventory`, `Quests`, `Pets`, `Inv`, `Daily`, `Social` … | A name of your own: `Wins`, `BestLapTime` | Built-in fields and other packages use these names; yours would overwrite theirs. |
| `local t = Data.Get(player, "Unlocked")`, then `t.Snow = true` and no `Data.Set` | Also call `Data.Set(player, "Unlocked", t)` | It still saves (`Get` returns the live table), but only `Data.Set` fires `Data.OnDataChanged`, so scripts that listen miss the change. |
| Editing `Data.DEFAULT_PROFILE` | `addMissingFields` from Step 1 | `DEFAULT_PROFILE` belongs to the framework (type error, and Update replaces it). |
| A log or history table that grows forever | Keep the last N entries | One player's data must stay under 4 MB. |

## Change it

- To save at once after something important (for example a Robux purchase): `Data.Save(player)`. Normal changes do not need it.
- To run code exactly when data loads, instead of `Data.WaitFor`: `Data.OnLoaded:Connect(function(player, data) ... end)` at the top level of a Script. It fires once per player, so it misses players loaded before your script connected. Your own fields may not exist yet here: read them with `or 0`.
- To react to every change: `Data.OnDataChanged:Connect(function(player, key, value) ... end)`. It fires after each `Data.Set`.
- To clean up when a player's data is released (leave or shutdown): `Data.OnReleased:Connect(function(player) ... end)`.
- To add a field **inside** an existing table later (for example `Settings.Volume`), read it with a default: `local volume = (Data.Get(player, "Settings") or {}).Volume or 1`. `addMissingFields` only adds top-level fields. Use a migration step (Step 3) only when an existing value changes its meaning or shape.
- Data settings in `GaxiaServer.Config.Data` (`StoreName` `"GaxiaPlayerData"`, `WaitForDefaultTimeout` 30 seconds, `Backup.Enabled` off, the 30-second auto-save) cannot be changed from game code. To wait longer, pass a timeout: `Data.WaitFor(player, 120)`. To save at once, use `Data.Save(player)`.

## See also

- [API: Data](../api/Data.md) · [API: Migration](../api/Migration.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Items and inventory](items-and-inventory.md) · [Client ↔ server](../start/04-client-server-communication.md)
- [Show values on screen](show-values-on-screen.md) · [Troubleshooting](../troubleshooting.md)
