# Settings, tuning values and feature flags

> Your game's settings live in one ModuleScript, Gaxia's limits are changed without editing Gaxia, and an admin can switch a "2x Coins" event on and off live.

**Use this when** the user asks for: "settings", "config", "change a limit", "tune values", "max coins per purchase", "faster leveling", "feature flag", "turn a feature on/off without updating", "double coins event", "where do I put game settings" (ไทย: "ตั้งค่า", "ปรับค่า", "แก้ค่า config", "ค่าสูงสุด", "เปิดปิดฟีเจอร์", "ฟีเจอร์แฟล็ก", "อีเวนต์เงินคูณสอง", "เก็บค่าตั้งค่าเกมไว้ที่ไหน").
**Packages:** `Economy` (for the round reward). `AntiCheatAdmin` for the `/flag` chat command (Step 5, Checks 4–5). `EConfig` and `Flags` are Core (always installed).
**You will create:** a ModuleScript `ReplicatedStorage/GameShared/GameConfig`, the Scripts `ServerScriptService/ConfigOverrides` and `ServerScriptService/RoundRewards`, and a LocalScript `StarterPlayer/StarterPlayerScripts/DoubleCoinsBanner` (Rojo: `GameShared/GameConfig.lua`, `<Name>.server.lua`, `DoubleCoinsBanner.client.lua`, see [02-server-script](../start/02-server-script.md)).

How it works — there are three layers:

| Layer | What it is | How you change it |
|---|---|---|
| `GaxiaServer.Config` | Gaxia's defaults, inside `Gaxia_Packages_Server/Config` | Never. Read it only: Install / Update replaces it. (Discord webhook URLs: `GaxiaServer.Webhook.SetChannel` in your own Script, see [webhooks-and-analytics](webhooks-and-analytics.md).) |
| Overrides | A value on top of a default, by key `"<Section>.<Key>"` | Server: `GaxiaServer.EConfig.Set(key, value)` / `GaxiaServer.EConfig.Clear(key)`. Admin chat: `/flag set <key> <value>`. |
| `ReplicatedStorage/GameShared/GameConfig` | Your game's own values (Step 1) | Edit the module. |

- `EConfig` (effective config) reads an override, else the default. `EConfig.Set` calls `Flags.Set`, so `/flag`, `EConfig` and `Flags` share one store. Read an override with `GaxiaServer.EConfig.Get(key, default)` (server) or `Gaxia.Flags.Get(key, default)` (client). Values: numbers, strings or booleans. `EConfig.Get` ignores (with a warning) an override whose type differs from the default's, so a number setting never receives a string.
- An override lasts until that server closes: not saved, not seen by other servers, but read by every client. So `ConfigOverrides` (Step 2) sets them on every server start, and `/flag set` is for live tests and events.

Gaxia keys you can override (the common ones; other packages read more keys, such as `Admin.ActionWhitelistSeconds`, `AntiCheat.Teleport.WhitelistGraceSeconds`, `Idle.DefaultRate`, `Vault.MaxCapacity`, `Mail.MaxMail`, `Leaderboard.CacheTTL`; a key Gaxia never reads does nothing):

| Key | Default | What it changes |
|---|---|---|
| `Economy.MaxTransaction` / `Economy.MaxBalance` | 1000000 / 1000000000 | Most one `Add` / `Spend` moves / highest balance |
| `Player.MaxWalkSpeed` | 500 | Highest speed `GaxiaServer.Player.SetWalkSpeed` sets |
| `AntiCheat.Enforce` / `AntiCheat.Enabled` | false / true | Kick on hard actions / the whole anti-cheat |
| `AntiCheat.Detector.<Name>.Enabled` | true (HumanoidState: false) | One of Speed, Fly, NoClip, Teleport, Heartbeat, Heuristic, WorldBounds, HumanoidState ([anticheat-and-bans](anticheat-and-bans.md)) |
| `Level.CurveBase` / `Level.CurveExponent` / `Level.StartLevel` | 100 / 1.5 / 1 | XP needed = CurveBase × level ^ CurveExponent |
| `Daily.DaySeconds` / `Daily.ResetWindow` | 86400 / 172800 | Daily reward gap / streak reset |
| `Pets.EggCost` / `Pets.MaxEquipSlots` / `Inventory.MaxItemCount` | 100 / 3 / 999999 | Egg price / pets equipped at once / most of one item |

## Step 1 — Put your game's settings in one module

1. In **ReplicatedStorage**, insert a **Folder** named **GameShared** (skip if it exists; [first client script](../start/03-client-script.md) uses the same folder).
2. In **ReplicatedStorage → GameShared**, insert a **ModuleScript** named **GameConfig**. Paste this whole block into it:

```lua
-- ModuleScript: ReplicatedStorage/GameShared/GameConfig
-- This game's own settings. Server and client scripts both read this module.
-- Clients can read everything in ReplicatedStorage: never put secrets here.
export type GameConfig = {
	RoundSeconds: number,
	RoundReward: number,
	DoubleCoins: boolean,
}
local GameConfig: GameConfig = {
	RoundSeconds = 60, -- length of one round, in seconds
	RoundReward = 10, -- Coins each player gets when a round ends
	DoubleCoins = false, -- default of the live flag "Game.DoubleCoins"
}
-- Frozen: a script that tries to change a value gets an error.
return table.freeze(GameConfig)
```

What it does: every value you may tune is in one place. Scripts read it with `require(game:GetService("ReplicatedStorage").GameShared.GameConfig)`.
Values that only the server needs (like `GameSettings` in [first server script](../start/02-server-script.md)) stay in `ServerStorage/GameModules`.

## Step 2 — Change Gaxia's limits at server start

Create a **Script** in **ServerScriptService** named **ConfigOverrides**:

```lua
-- Script: ServerScriptService/ConfigOverrides
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

local EConfig = GaxiaServer.EConfig

-- Gaxia settings this game changes: ["<Section>.<Key>"] = value. Runs on every server start.
local OVERRIDES: { [string]: number | boolean | string } = {
	["Economy.MaxTransaction"] = 5000000, -- default 1000000
	["Level.CurveBase"] = 50, -- default 100: faster leveling
}

for key, value in OVERRIDES do
	EConfig.Set(key, value)
	print(`[ConfigOverrides] {key} = {tostring(EConfig.Get(key, nil))}`)
end

-- Adds /flag set|get|clear for admins (only with the AntiCheatAdmin package).
-- Safe to call again from another script: the commands are added only once.
if GaxiaServer.IsInstalled("AntiCheatAdmin") then
	GaxiaServer.AntiCheatAdmin.Register()
end

print("[ConfigOverrides] ready")
```

What it does: `Economy.Add(player, "Coins", 2000000)` now adds 2,000,000 instead of being refused (above 1,000,000 it returns `false` and warns).

## Step 3 — Use your settings and a live flag on the server

Create a **Script** in **ServerScriptService** named **RoundRewards**:

```lua
-- Script: ServerScriptService/RoundRewards
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local GameConfig = require(game:GetService("ReplicatedStorage").GameShared.GameConfig)

assert(GaxiaServer.IsInstalled("Economy"), "RoundRewards needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local EConfig = GaxiaServer.EConfig
local Economy = GaxiaServer.Economy
-- Flags is the one shared module server code uses: there is no GaxiaServer.Flags.
local Flags = Gaxia.Flags

-- A live flag wins; GameConfig is the default.
local function isDoubleCoins(): boolean
	return EConfig.Enabled("Game.DoubleCoins", GameConfig.DoubleCoins)
end
local function roundReward(): number
	-- tonumber: "/flag set Game.RoundReward abc" must not break the game.
	local reward = tonumber(EConfig.Get("Game.RoundReward", GameConfig.RoundReward)) or GameConfig.RoundReward
	return if isDoubleCoins() then reward * 2 else reward
end

-- Runs when an admin types /flag set (or /flag clear) Game.DoubleCoins.
Flags.OnChanged("Game.DoubleCoins", function()
	print(`[RoundRewards] DoubleCoins is now {isDoubleCoins()}, reward = {roundReward()}`)
end)

print(`[RoundRewards] ready, round = {GameConfig.RoundSeconds}s, reward = {roundReward()}`)

-- This loop never ends, so it is the last thing in the script.
while true do
	task.wait(GameConfig.RoundSeconds)
	local reward = roundReward()
	for _, player in Players:GetPlayers() do
		-- Add returns false while the player's data is still loading.
		if Economy.Add(player, "Coins", reward) then
			print(`[RoundRewards] round over: {player.Name} +{reward} Coins`)
		end
	end
end
```

What it does: every 60 seconds each player gets 10 Coins, or 20 while the flag `Game.DoubleCoins` is on. Your own keys start with `Game.`, so they never clash with Gaxia's keys.

## Step 4 — Show the flag on the client

Do Steps 2 and 3 first: the banner reads the server's flag store, which they create. Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **DoubleCoinsBanner**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/DoubleCoinsBanner
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local GameConfig = require(game:GetService("ReplicatedStorage").GameShared.GameConfig)

local Flags = Gaxia.Flags
local screenGui = Instance.new("ScreenGui")
screenGui.ResetOnSpawn = false

local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(260, 50)
label.Position = UDim2.new(0.5, -130, 0, 60)
label.BackgroundColor3 = Color3.fromRGB(255, 200, 40)
label.TextScaled = true
label.Text = "2x COINS!"
label.Visible = false
label.Parent = screenGui
screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

-- The client only reads flags. Only the server can set them.
local function refresh()
	local on = Flags.Get("Game.DoubleCoins", GameConfig.DoubleCoins) == true
	label.Visible = on
	print(`[DoubleCoinsBanner] DoubleCoins = {on}`)
end

refresh()
Flags.OnChanged("Game.DoubleCoins", refresh)
print("[DoubleCoinsBanner] ready")
```

What it does: a yellow "2x COINS!" banner shows at the top of the screen while the flag is on.

## Step 5 — Switch the flag live

No code. Needs the `AntiCheatAdmin` package and the `admin` role (you are `owner` in a published place you own; otherwise `STAFF` in [admin-and-chat-commands](admin-and-chat-commands.md) Step 1). Type in chat:

- `/flag set Game.DoubleCoins true` turns it on in this server (`true`, `false` and numbers are converted).
- `/flag get Game.DoubleCoins` shows the value. `/flag clear Game.DoubleCoins` removes the override.

## Check that it works

Agent: check your scripts against Steps 1–4. The user runs these in Studio. No Studio? Send: "Please press Play, do the checks in the playbook, and paste the Output lines that start with `[ConfigOverrides]`, `[RoundRewards]` and `[DoubleCoinsBanner]`."

1. Press **Play** in Studio.
2. Output shows `[ConfigOverrides] Economy.MaxTransaction = 5000000`, `[ConfigOverrides] ready`, `[RoundRewards] ready, round = 60s, reward = 10`, `[DoubleCoinsBanner] DoubleCoins = false`, `[DoubleCoinsBanner] ready`, and no red errors.
3. After 60 seconds Output shows `[RoundRewards] round over: <YourName> +10 Coins`.
4. Type `/flag set Game.DoubleCoins true` (needs Step 5's package and role). The banner appears. Output shows `[RoundRewards] DoubleCoins is now true, reward = 20`.
5. Type `/flag clear Game.DoubleCoins`. The banner disappears.
6. No `AntiCheatAdmin` or no `admin` role? Do this instead of 4–5: add `GaxiaServer.EConfig.Set("Game.DoubleCoins", true)` at the end of `ConfigOverrides`, press Play: Output shows `[DoubleCoinsBanner] DoubleCoins = true`. Then remove that line.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Editing `Gaxia_Packages_Server/Config`, or `Config.Economy.MaxTransaction = 5000000` in a script | An entry in `OVERRIDES` (Step 2) | Install / Update replaces the package. A key Gaxia does not read through `EConfig` needs a framework change, which is not allowed. |
| `EConfig.Set("Economy.MaxTransaction", "5000000")`, or `/flag set Economy.MaxTransaction` with no value (that sets it to `true`) | A number: `5000000` | `EConfig.Get` ignores an override whose type differs from the default's: Output warns `[EConfig] ignoring override Economy.MaxTransaction = 5000000 (string)` and the default 1000000 stays in use until `/flag set Economy.MaxTransaction 5000000` (or `/flag clear`). |
| A typo such as `"Economy.MaxTransation"` | Copy the key from the table | A wrong key is accepted and does nothing. `/flag get` only shows what you typed. |
| `EConfig.Set("Game.Prices", { Sword = 100 })` | Tables go in `GameConfig` | An override must be a number, string or boolean (a table errors). |
| `Flags.Set(...)` in a LocalScript | Set on the server | `Flags.Set` is server-only; it errors on the client. |
| An API key or webhook URL in `GameConfig` or an override | Webhook URLs: `WebhookSetup` ([webhooks-and-analytics](webhooks-and-analytics.md)). Other secrets: a ModuleScript in `ServerStorage/GameModules` | Clients can read ReplicatedStorage and every override. |
| Changing anti-cheat detector numbers (`Speed.ToleranceMultiplier`), `BanPolicy`, `Data` store names or admin roles here | Not possible from game code today: turn a detector off instead; give roles in [StaffRoles](admin-and-chat-commands.md) | Gaxia does not read them through `EConfig` (detector numbers are fixed when the server starts). |

## Change it

- To add a setting: add a line to the type and to the table in `GameConfig`, then read `GameConfig.Name`. To make it switchable live: read it as `EConfig.Get("Game.Name", GameConfig.Name)` (server) or `Flags.Get("Game.Name", GameConfig.Name)` (client).
- Server-only secrets: a ModuleScript `ServerStorage/GameModules/GameSecrets` shaped like `GameConfig`, required only from Scripts.
- To read a Gaxia value with its override: `EConfig.Get("Economy.MaxTransaction", Config.Economy.MaxTransaction)`, with `local Config = GaxiaServer.Config`. `EConfig.IsOverridden(key)` tells whether one is set.
- To switch a flag from server code (for example a weekend event): `GaxiaServer.EConfig.Set("Game.DoubleCoins", true)`.
- To turn on anti-cheat kicking: [anticheat-and-bans](anticheat-and-bans.md) Step 4.
- To choose which services start at boot (`ServerStorage/GaxiaFeatures`) or which client modules load at spawn (`ReplicatedStorage/GaxiaClientFeatures`): [01-install-packages](../start/01-install-packages.md), *Change it*. Both **replace** the default list. Shapes: `return { Services = { "Data", "Player", ... } }` and `return { Client = { { Key = "AntiCheat", RequiresServer = "AntiCheat" }, ... } }`.

## See also

- [API: EConfig](../api/Core.EffectiveConfig.md) · [API: Flags](../api/Core.Flags.md) · [API: Config](../api/Core.Config.md)
- [Admin and chat commands](admin-and-chat-commands.md) · [Anti-cheat and bans](anticheat-and-bans.md) · [Currency and leaderstats](currency-and-leaderstats.md)
