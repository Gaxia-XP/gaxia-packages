# Save and load player data

> Every player has saved fields of your own (wins, unlocked areas, play time) that load when they join and save by themselves.

**Use this when** the user asks for: "save player data", "save progress", "DataStore", "remember X when the player comes back", "add a saved field", "data migration" (ไทย: "เซฟข้อมูลผู้เล่น", "บันทึกความคืบหน้า", "เก็บข้อมูลไว้ตอนออกเกม", "เพิ่มข้อมูลที่ต้องเซฟ", "ดาต้าสโตร์").
**Packages:** `Data` (it also installs `Migration`). The script below stops with a clear message if it is missing.
**You will create:** the Scripts `ServerScriptService/PlayerStats`, `ServerScriptService/PlayTimeTracker` and (only when you change saved data later) `ServerScriptService/DataMigrations`.

How it works:

- `GaxiaServer.Data` loads a player's data a moment **after** they join, and saves it by itself: every 30 seconds, when they leave, and when the server shuts down.
- Read with `Data.Get(player, "Key")`, write with `Data.Set(player, "Key", value)`. `Data.Set` can create a new key. New keys are saved like the built-in ones.
- Before the data is loaded, `Data.Get` returns `nil` and `Data.Set` returns `false` (nothing is written). Always wait first: `Data.WaitFor(player)` (it returns `nil` if the player leaves or 120 seconds pass; `Data.WaitFor(player, 60)` waits 60 seconds instead).
- Your own fields and their starting values are listed once with `Data.SetDefaults` (Step 1). Every player gets the fields they do not have yet as their data loads, so once `Data.WaitFor` returns, every script can read them.
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
-- Every player who does not have a field yet gets it when their data loads
-- (new players, and fields you add in an update). Each player gets their own copy of the tables.
-- Save only numbers, strings, booleans and tables of them, with string keys (or a list).
-- Call it here, at the top of the script, before any player's data loads.
Data.SetDefaults({
	Wins = 0,
	Visits = 0,
	Unlocked = {}, -- for example { Desert = true }
})

local function onPlayerAdded(player: Player)
	-- Wait until the data is loaded. nil means the player left (or it took over 120 seconds).
	local data = Data.WaitFor(player)
	if data == nil then
		return
	end

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

What it does: it adds your fields to every player's data as it loads, then counts the visit.
To add a field in a later update, add it to the `Data.SetDefaults` table: players who already have saves get it with its starting value on their next join.

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

Use the same pattern anywhere on the server (for example when a round is won):

```lua
-- fragment
if Data.IsLoaded(player) then
	Data.Set(player, "Wins", Data.Get(player, "Wins") + 1)
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

If a step is missing or errors, Output shows one of these warnings, and the player joins with their data unchanged (no step is applied):

- `[DataMigration] No migration registered from v1 -> target v2. Chain incomplete; data left at v1.`: add the missing `Migration.Register(1, 2, ...)`.
- `[DataMigration] Migration v1 -> v2 failed: <error> (data left at v1)`: fix the error in that function.

Nothing is reset or deleted. Steps are all or nothing: they run on a copy of the data, and the copy is kept only when every step succeeds. When one fails, the save stays exactly as it was (old version, no step applied), so the steps run again on the next join. Fix the script, then stop and press **Play** again. More help: [troubleshooting](../troubleshooting.md).

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
| `Data.SetDefaults` inside `PlayerAdded`, after a `task.wait`, or in a function called later | `Data.SetDefaults({ ... })` at the top of a Script | Players already loaded miss the fields until it runs (Output warns `SetDefaults was called after player data loaded`): `attempt to perform arithmetic (add) on nil`. |
| `Data.Set(player, "Wins", 0)` for each player in `PlayerAdded` to create fields | `Data.SetDefaults({ Wins = 0 })` once | It runs after the load, so other scripts can see the field missing; it also resets a saved value if you forget the `nil` check. |
| Saving an `Instance`, `Vector3`, `CFrame` or `Color3` | Save numbers: `{ X = 1, Y = 2, Z = 3 }`, or the part's name | DataStores save only numbers, strings, booleans and tables. Other values are lost or the save fails. |
| `{ [player.UserId] = true }` or a list with holes | String keys: `{ [tostring(player.UserId)] = true }` | Tables with number keys that are not a list 1, 2, 3 cannot be saved. |
| `Data.Set(player, "Coins", 100)` | `GaxiaServer.Economy.Set(player, "Coins", 100)` to set the balance (or `GaxiaServer.Economy.Add` to give) | Economy fires `OnTransaction`, which updates leaderstats. See [currency-and-leaderstats](currency-and-leaderstats.md). |
| Your field named `Level`, `Inventory`, `Quests`, `Pets`, `Inv`, `Daily`, `Social` … | A name of your own: `Wins`, `BestLapTime` | Built-in fields and other packages use these names; yours would overwrite theirs. |
| `local t = Data.Get(player, "Unlocked")`, then `t.Snow = true` and no `Data.Set` | Also call `Data.Set(player, "Unlocked", t)` | It still saves (`Get` returns the live table), but only `Data.Set` fires `Data.OnDataChanged`, so scripts that listen miss the change. |
| Editing `Data.DEFAULT_PROFILE` | `Data.SetDefaults` from Step 1 | `DEFAULT_PROFILE` belongs to the framework (type error, and Update replaces it). |
| `Data.SetDefaults({ Coins = 100 })` to change the starting coins | Give coins with `GaxiaServer.Economy.Add` | Built-in fields keep their starting values: `SetDefaults` ignores them and warns. |
| A log or history table that grows forever | Keep the last N entries | One player's data must stay under 4 MB. |

## Change it

- To save at once after something important (for example a Robux purchase): `Data.Save(player)`. Normal changes do not need it.
- To run code exactly when data loads, instead of `Data.WaitFor`: `Data.OnLoaded:Connect(function(player, data) ... end)` at the top level of a Script. It fires once per player, so it misses players loaded before your script connected. Your `Data.SetDefaults` fields are already in `data`.
- To react to every change: `Data.OnDataChanged:Connect(function(player, key, value) ... end)`. It fires after each `Data.Set`.
- To clean up when a player's data is released (leave or shutdown): `Data.OnReleased:Connect(function(player) ... end)`.
- To add a field **inside** an existing table later (for example `Settings.Volume`), list it with the table: `Data.SetDefaults({ Settings = { Volume = 1 } })`. Nested tables are merged, so the built-in `Settings.Music` and `Settings.SFX` stay. A list default (for example `Loadout = { "Sword" }`) is different: a player gets it only when they have no `Loadout` yet, and a saved list is never changed. Use a migration step (Step 3) only when an existing value changes its meaning or shape.
- Data settings in `GaxiaServer.Config.Data` (`StoreName` `"GaxiaPlayerData"`, `WaitForDefaultTimeout` 120 seconds, `Backup.Enabled` off, the 30-second auto-save) cannot be changed from game code. To wait a different time, pass a timeout: `Data.WaitFor(player, 60)`. To save at once, use `Data.Save(player)`.

## See also

- [API: Data](../api/Data.md) · [API: Migration](../api/Migration.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Items and inventory](items-and-inventory.md) · [Client ↔ server](../start/04-client-server-communication.md)
- [Show values on screen](show-values-on-screen.md) · [Troubleshooting](../troubleshooting.md)
