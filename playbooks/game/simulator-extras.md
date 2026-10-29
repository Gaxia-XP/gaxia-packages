# Add rebirths, upgrades, boosts and auto-collect to a simulator

> The coin simulator gets a rebirth (reset Coins for a saved, permanent multiplier), a Coin Bonus upgrade bought with Coins, a 2x boost for 5 minutes that keeps running after a rejoin, and an auto-collect game pass. One server function combines every multiplier.

**Use this when** the user asks for: "rebirth", "prestige", "upgrades", "multiplier", "2x boost", "timed boost", "potion", "auto collect", "auto-collect game pass", "simulator extras" (ไทย: "รีเบิร์ธ", "เกิดใหม่", "อัปเกรด", "ตัวคูณ", "บูสต์ 2 เท่า", "บูสต์มีเวลา", "เก็บเหรียญอัตโนมัติ", "เกมพาสเก็บอัตโนมัติ").
**Packages:** `Data`, `Player`, `Economy`, `Monetization`, `UI.Toast`, `UI.StateBinding`. The [example-simulator](example-simulator.md) install already has all of them (`Shop` brings `Monetization`). Every script stops with a clear message if one is missing.
**You will create:** a ModuleScript `ServerStorage/GameModules/SimMultiplier`, the Scripts `ServerScriptService/SimExtrasStats`, `ServerScriptService/SimExtrasShop` and `ServerScriptService/SimAutoCollect`, and a LocalScript `StarterPlayer/StarterPlayerScripts/SimExtrasHud`. You change two lines in `SimCoins`.

Build [example-simulator](example-simulator.md) first. This playbook adds to it.

| Part | Script | What it does |
|---|---|---|
| Numbers, saved field names, and `Get` (all multipliers in one function) | `SimMultiplier` | Every server script asks it "how many Coins is one coin worth?" |
| Saved defaults, HUD values, the Rebirths column, boost countdown | `SimExtrasStats` | Sends the values to the screen every second |
| Rebirth, Coin Bonus and 2x boost, bought on the server | `SimExtrasShop` | One remote, `SimExtrasBuy` |
| Auto-collect game pass | `SimAutoCollect` | Picks up coin parts near owners |
| Labels and buttons | `SimExtrasHud` | Asks the server, shows the answer as a toast |

## Step 1 — Put every multiplier in one ModuleScript

In **ServerStorage → GameModules** (the Folder from example-simulator), insert a **ModuleScript**. Name it **SimMultiplier**. Paste this whole block into it:

```lua
-- ModuleScript: ServerStorage/GameModules/SimMultiplier
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

local Data = GaxiaServer.Data

-- Every number of the extras lives here. Prices must be whole numbers.
local SimMultiplier = {
	BaseCoinValue = 5, -- Coins for one coin part before multipliers (SimCoins uses this now)

	RebirthPrice = 500, -- Coins for the 1st rebirth; the 2nd costs 2 x 500, the 3rd 3 x 500, ...
	RebirthBonus = 0.5, -- each rebirth adds +0.5 to the multiplier, forever

	BonusMaxLevel = 10, -- the Coin Bonus upgrade has levels 1 to 10
	BonusPrice = 50, -- Coins for level 1; every next level costs 2 times more
	BonusPerLevel = 0.25, -- each level adds +25% Coins

	BoostMinutes = 5, -- one 2x boost lasts 5 minutes
	BoostPrice = 200, -- Coins for one boost
	BoostMaxMinutes = 30, -- boosts stack up to 30 minutes
	BoostMultiplier = 2,

	AutoCollectPassId = 0, -- your game pass ID (a number). 0 = not set yet: the button only warns
	AutoCollectRadius = 30, -- auto-collect picks up coin parts up to 30 studs from the player
	AutoCollectSeconds = 1, -- it looks for coin parts every 1 second
	StudioAutoCollect = false, -- Studio only: true = every tester has auto-collect without the pass

	StudioTestCoins = 1000, -- Studio only: each tester starts every Play with at least 1000 Coins. 0 = off

	-- Saved fields. DoubleField must be the same text as UpgradeField in SimConfig.
	DoubleField = "SimDoubleCoins",
	RebirthsField = "SimRebirths",
	BonusLevelField = "SimBonusLevel",
	BoostEndsField = "SimBoostEndsAt", -- the os.time() when the boost ends (0 = no boost)
}

-- A saved number, or 0 when it is missing or the data is not loaded.
local function savedNumber(player: Player, field: string): number
	local value = Data.Get(player, field)
	if typeof(value) == "number" then
		return value
	end
	return 0
end

function SimMultiplier.GetRebirths(player: Player): number
	return savedNumber(player, SimMultiplier.RebirthsField)
end

function SimMultiplier.GetBonusLevel(player: Player): number
	return savedNumber(player, SimMultiplier.BonusLevelField)
end

-- Coins for the next rebirth.
function SimMultiplier.RebirthCost(player: Player): number
	return SimMultiplier.RebirthPrice * (SimMultiplier.GetRebirths(player) + 1)
end

-- Coins for the next Coin Bonus level, or 0 when it is at the max level.
function SimMultiplier.BonusCost(player: Player): number
	local level = SimMultiplier.GetBonusLevel(player)
	if level >= SimMultiplier.BonusMaxLevel then
		return 0
	end
	return SimMultiplier.BonusPrice * 2 ^ level
end

-- Seconds left on the 2x boost (0 = no boost). os.time() keeps going while the player is offline.
function SimMultiplier.BoostSecondsLeft(player: Player): number
	return math.max(0, savedNumber(player, SimMultiplier.BoostEndsField) - os.time())
end

-- THE one function: every multiplier of the game, combined.
function SimMultiplier.Get(player: Player): number
	local multiplier = 1
	if Data.Get(player, SimMultiplier.DoubleField) == true then
		multiplier *= 2 -- the 2x Coins upgrade from SimShop
	end
	multiplier *= 1 + SimMultiplier.GetRebirths(player) * SimMultiplier.RebirthBonus
	multiplier *= 1 + SimMultiplier.GetBonusLevel(player) * SimMultiplier.BonusPerLevel
	if SimMultiplier.BoostSecondsLeft(player) > 0 then
		multiplier *= SimMultiplier.BoostMultiplier
	end
	return multiplier
end

-- The multiplier rounded to 2 decimals, for text (1.875 becomes 1.88).
function SimMultiplier.Rounded(player: Player): number
	return math.floor(SimMultiplier.Get(player) * 100 + 0.5) / 100
end

-- Coins for one coin part: a whole number, at least 1.
function SimMultiplier.CoinPayout(player: Player): number
	return math.max(1, math.floor(SimMultiplier.BaseCoinValue * SimMultiplier.Get(player)))
end

return SimMultiplier
```

What it does: `Get` multiplies the 2x upgrade, rebirths, Coin Bonus and the boost. Every server script uses `CoinPayout`, so they never disagree.

## Step 2 — Make coin parts pay with the combined multiplier

Open the Script **ServerScriptService → SimCoins** (from example-simulator). Under the line `local SimConfig = require(ServerStorage.GameModules.SimConfig)`, add:

```lua
-- fragment
local SimMultiplier = require(ServerStorage.GameModules.SimMultiplier)
```

Find the line `local amount = SimConfig.CoinValue * SimConfig.GetMultiplier(player)`. Replace it with:

```lua
-- fragment
local amount = SimMultiplier.CoinPayout(player)
```

Do not change anything else in `SimCoins`. `SimConfig.GetMultiplier` stays: `SimShop` still uses it to check "already owns 2x".

`SimConfig.CoinValue` is not used anymore. To change what one coin is worth, change `BaseCoinValue` in `SimMultiplier`.

## Step 3 — Save the new fields and send them to the screen

Create a **Script** in **ServerScriptService** named **SimExtrasStats**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/SimExtrasStats
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local SimMultiplier = require(ServerStorage.GameModules.SimMultiplier)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Economy"), "SimExtrasStats needs the Economy package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Player"), "SimExtrasStats needs the Player package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local PlayerService = GaxiaServer.Player -- the Gaxia "Player" package (Players above is Roblox's service)
local State = Gaxia.State

-- New players start with 0 rebirths, Coin Bonus level 0 and no boost. At the top: before players load.
Data.SetDefaults({
	[SimMultiplier.RebirthsField] = 0,
	[SimMultiplier.BonusLevelField] = 0,
	[SimMultiplier.BoostEndsField] = 0,
})

-- The values the HUD shows. Per-player keys end with "_<Name>".
local hudState = State.Create("SimExtrasState", {
	BoostMinutes = SimMultiplier.BoostMinutes,
	BoostPrice = SimMultiplier.BoostPrice,
	BonusPercent = math.floor(SimMultiplier.BonusPerLevel * 100 + 0.5), -- rounded: 0.1 * 100 is not exactly 10
})
local KEYS = { "Multiplier_", "RebirthPrice_", "BonusPrice_", "BoostLeft_" }

local WATCHED: { [string]: boolean } = { -- a change to one of these fields refreshes the HUD at once
	[SimMultiplier.DoubleField] = true,
	[SimMultiplier.RebirthsField] = true,
	[SimMultiplier.BonusLevelField] = true,
	[SimMultiplier.BoostEndsField] = true,
}

local loaded: { [Player]: boolean } = {} -- players whose data is loaded
local boosted: { [Player]: boolean } = {} -- had a boost at the last refresh

-- Sends this player's values to the HUD and the player list.
local function refresh(player: Player)
	local name = player.Name
	hudState:Set("Multiplier_" .. name, SimMultiplier.Rounded(player))
	hudState:Set("RebirthPrice_" .. name, SimMultiplier.RebirthCost(player))
	hudState:Set("BonusPrice_" .. name, SimMultiplier.BonusCost(player))
	hudState:Set("BoostLeft_" .. name, SimMultiplier.BoostSecondsLeft(player))
	local rebirths = SimMultiplier.GetRebirths(player)
	if PlayerService.GetLeaderstat(player, "Rebirths") ~= rebirths then
		PlayerService.SetLeaderstat(player, "Rebirths", rebirths) -- a Rebirths column in the player list
	end
end

Data.OnDataChanged:Connect(function(player: Player, key: string, _value: any)
	if loaded[player] and WATCHED[key] then
		refresh(player)
	end
end)

local function onPlayerAdded(player: Player)
	-- Wait until the saved data is loaded (nil = the player left).
	if Data.WaitFor(player, 120) == nil or player.Parent == nil then
		return
	end
	loaded[player] = true
	boosted[player] = SimMultiplier.BoostSecondsLeft(player) > 0
	refresh(player)
	print(`[SimExtrasStats] {player.Name} loaded: {SimMultiplier.GetRebirths(player)} rebirths, bonus level {SimMultiplier.GetBonusLevel(player)}, boost {SimMultiplier.BoostSecondsLeft(player)} s, multiplier x{SimMultiplier.Rounded(player)}`)

	-- Studio only: top the Coins up to StudioTestCoins (it never adds more on top). Never in a live game.
	if RunService:IsStudio() and SimMultiplier.StudioTestCoins > 0 then
		if Economy.Get(player, "Coins") < SimMultiplier.StudioTestCoins then
			Economy.Set(player, "Coins", SimMultiplier.StudioTestCoins)
		end
		print(`[SimExtrasStats] Studio test: {player.Name} has at least {SimMultiplier.StudioTestCoins} Coins`)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	loaded[player] = nil
	boosted[player] = nil
	for _, prefix in KEYS do
		hudState:Set(prefix .. player.Name, nil) -- nil deletes the key
	end
end)

print("[SimExtrasStats] ready")

-- Every second: count the boost down and notice when it ends. This loop never ends, so it is last.
while true do
	task.wait(1)
	for player in loaded do
		local hasBoost = SimMultiplier.BoostSecondsLeft(player) > 0
		if boosted[player] and not hasBoost then
			print(`[SimExtrasStats] {player.Name}'s boost ended, multiplier now x{SimMultiplier.Rounded(player)}`)
		end
		boosted[player] = hasBoost
		refresh(player)
	end
end
```

What it does: it adds the three saved fields, a **Rebirths** column, and the HUD values. The boost end time is saved, so a rejoin shows the right time left.

## Step 4 — Sell rebirth, Coin Bonus and the boost on the server

Create a **Script** in **ServerScriptService** named **SimExtrasShop**:

```lua
-- Script: ServerScriptService/SimExtrasShop
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local SimMultiplier = require(ServerStorage.GameModules.SimMultiplier)

assert(GaxiaServer.IsInstalled("Economy"), "SimExtrasShop needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy

local function buyCoinBonus(player: Player): (boolean, string)
	local level = SimMultiplier.GetBonusLevel(player)
	local cost = SimMultiplier.BonusCost(player)
	if cost == 0 then
		return false, "Coin Bonus is at its max level"
	end
	if not Economy.Spend(player, "Coins", cost) then
		return false, `Not enough Coins (you need {cost})`
	end
	if not Data.Set(player, SimMultiplier.BonusLevelField, level + 1) then
		Economy.Add(player, "Coins", cost) -- give the Coins back
		return false, "Something went wrong, your Coins were returned"
	end
	print(`[SimExtrasShop] {player.Name} bought Coin Bonus level {level + 1} for {cost} Coins, multiplier now x{SimMultiplier.Rounded(player)}`)
	return true, `Coin Bonus level {level + 1}! Multiplier x{SimMultiplier.Rounded(player)}`
end

local function buyBoost(player: Player): (boolean, string)
	local secondsLeft = SimMultiplier.BoostSecondsLeft(player)
	local addSeconds = SimMultiplier.BoostMinutes * 60
	if secondsLeft + addSeconds > SimMultiplier.BoostMaxMinutes * 60 then
		return false, `Boosts stack up to {SimMultiplier.BoostMaxMinutes} minutes`
	end
	if not Economy.Spend(player, "Coins", SimMultiplier.BoostPrice) then
		return false, `Not enough Coins (you need {SimMultiplier.BoostPrice})`
	end
	-- Save the END time, not the time left: it keeps counting while the player is offline.
	if not Data.Set(player, SimMultiplier.BoostEndsField, os.time() + secondsLeft + addSeconds) then
		Economy.Add(player, "Coins", SimMultiplier.BoostPrice)
		return false, "Something went wrong, your Coins were returned"
	end
	print(`[SimExtrasShop] {player.Name} bought a 2x boost: {secondsLeft + addSeconds} s left, multiplier now x{SimMultiplier.Rounded(player)}`)
	return true, `2x boost for {SimMultiplier.BoostMinutes} more minutes!`
end

local function rebirth(player: Player): (boolean, string)
	local rebirths = SimMultiplier.GetRebirths(player)
	local cost = SimMultiplier.RebirthCost(player)
	if Economy.Get(player, "Coins") < cost then
		return false, `You need {cost} Coins to rebirth`
	end
	if not Data.Set(player, SimMultiplier.RebirthsField, rebirths + 1) then
		return false, "Something went wrong, try again"
	end
	Economy.Set(player, "Coins", 0) -- a rebirth resets Coins to 0
	print(`[SimExtrasShop] {player.Name} rebirthed: {rebirths + 1} rebirths, multiplier now x{SimMultiplier.Rounded(player)}`)
	return true, `Rebirth {rebirths + 1}! Multiplier x{SimMultiplier.Rounded(player)}`
end

-- The client sends only the NAME of what it wants. Prices live here, on the server.
local ACTIONS: { [string]: (Player) -> (boolean, string) } = {
	CoinBonus = buyCoinBonus,
	Boost = buyBoost,
	Rebirth = rebirth,
}

Net.OnInvoke("SimExtrasBuy", function(player: Player, action: any): (boolean, string)
	local buy = if typeof(action) == "string" then ACTIONS[action] else nil
	if buy == nil then
		return false, "Unknown action"
	end
	if not Data.IsLoaded(player) then
		return false, "Your data is still loading"
	end
	return buy(player)
end, { rate = 2, burst = 4 })

print("[SimExtrasShop] ready")
```

What it does: one remote, `SimExtrasBuy`, with `"CoinBonus"`, `"Boost"` or `"Rebirth"`. The server checks the price and saves the result.

## Step 5 — Add the auto-collect game pass

1. Publish the place. On **create.roblox.com**, create a pass named `Auto-Collect` (see [robux-purchases](robux-purchases.md) Step 1). Copy its **Pass ID**.
2. In `SimMultiplier`, change `AutoCollectPassId = 0` to your Pass ID. `0` is fine until then: the script starts, and the button only warns.
3. Create a **Script** in **ServerScriptService** named **SimAutoCollect**:

```lua
-- Script: ServerScriptService/SimAutoCollect
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local SimMultiplier = require(ServerStorage.GameModules.SimMultiplier)

assert(GaxiaServer.IsInstalled("Monetization"), "SimAutoCollect needs the Monetization package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "SimAutoCollect needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Economy = GaxiaServer.Economy
local Monetization = GaxiaServer.Monetization

local PASS_ID = SimMultiplier.AutoCollectPassId

-- Other scripts and the HUD check: player:GetAttribute("SimAutoCollect") == true
local function giveAutoCollect(player: Player)
	if player:GetAttribute("SimAutoCollect") == true then
		return
	end
	player:SetAttribute("SimAutoCollect", true)
	print(`[SimAutoCollect] {player.Name} has auto-collect`)
end

local function onPlayerAdded(player: Player)
	if RunService:IsStudio() and SimMultiplier.StudioAutoCollect then
		giveAutoCollect(player)
	elseif PASS_ID ~= 0 and Monetization.OwnsGamePass(player, PASS_ID) then
		giveAutoCollect(player)
	end
end

-- Fires when a player buys a pass in this server.
Monetization.OnGamePassPurchased:Connect(function(player: Player, gamePassId: number)
	if gamePassId == PASS_ID then
		giveAutoCollect(player)
	end
end)

-- The client asks to open the Robux window. It sends nothing: the server knows the pass.
Net.OnServer("SimBuyAutoCollect", function(player: Player)
	if PASS_ID == 0 then
		warn("[SimAutoCollect] no Pass ID: paste it into AutoCollectPassId in SimMultiplier")
	elseif player:GetAttribute("SimAutoCollect") == true then
		print(`[SimAutoCollect] {player.Name} already has auto-collect`)
	else
		Monetization.PromptGamePass(player, PASS_ID)
	end
end, { rate = 2, burst = 4 })

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- Picks up every coin part near one player. Pays like a touch (SimMultiplier.CoinPayout).
local function collectNear(player: Player, folder: Instance)
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end
	local count, total = 0, 0
	for _, coin in folder:GetChildren() do
		if coin:IsA("BasePart") and (coin.Position - root.Position).Magnitude <= SimMultiplier.AutoCollectRadius then
			local amount = SimMultiplier.CoinPayout(player)
			if not Economy.Add(player, "Coins", amount) then
				return -- data not loaded yet: try again next time
			end
			coin:Destroy()
			count += 1
			total += amount
		end
	end
	if count > 0 then
		print(`[SimAutoCollect] {player.Name} auto-collected {count} coins, +{total} Coins`)
	end
end

print("[SimAutoCollect] ready")

-- This loop never ends, so it is the last thing in the script.
while true do
	task.wait(SimMultiplier.AutoCollectSeconds)
	local folder = workspace:FindFirstChild("SimCoinParts") -- made by SimCoins
	if folder then
		for _, player in Players:GetPlayers() do
			if player:GetAttribute("SimAutoCollect") == true then
				collectNear(player, folder)
			end
		end
	end
end
```

What it does: owners of the pass get the `SimAutoCollect` attribute. Every second, coin parts within 30 studs of them are collected and paid.

## Step 6 — Show the multiplier and the buttons on the client

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **SimExtrasHud**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/SimExtrasHud
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.Toast"), "SimExtrasHud needs the UI.Toast package: install it (playbooks/start/01-install-packages.md)")
assert(Gaxia.IsInstalled("UI.StateBinding"), "SimExtrasHud needs the UI.StateBinding package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local State = Gaxia.State
local Toast = Gaxia.UI.Toast
local StateBinding = Gaxia.UI.StateBinding
local player = Players.LocalPlayer

-- 1. Build the screen in code: a grid of 2 columns at the top middle (it fits on a phone too).
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SimExtrasHud"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(346, 102) -- 2 columns of 170 px, 3 rows of 30 px, 6 px gaps
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Position = UDim2.new(0.5, 0, 0, 6) -- top middle, under the Roblox top bar
panel.BackgroundTransparency = 1
panel.Parent = screenGui

local layout = Instance.new("UIGridLayout")
layout.CellSize = UDim2.fromOffset(170, 30) -- every label and button gets this size
layout.CellPadding = UDim2.fromOffset(6, 6)
layout.FillDirectionMaxCells = 2
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = panel

local function makeLabel(name: string, order: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.LayoutOrder = order
	label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	label.BackgroundTransparency = 0.4
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "..."
	label.Parent = panel
	return label
end

local function makeButton(name: string, order: number, color: Color3): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.LayoutOrder = order
	button.BackgroundColor3 = color
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Font = Enum.Font.GothamBold
	button.TextScaled = true
	button.Text = "..."
	button.Parent = panel
	return button
end

local multiplierLabel = makeLabel("MultiplierLabel", 1)
local boostLabel = makeLabel("BoostLabel", 2)
local bonusButton = makeButton("CoinBonusButton", 3, Color3.fromRGB(40, 160, 70))
local boostButton = makeButton("BoostButton", 4, Color3.fromRGB(140, 60, 200))
local rebirthButton = makeButton("RebirthButton", 5, Color3.fromRGB(220, 120, 20))
local autoButton = makeButton("AutoCollectButton", 6, Color3.fromRGB(30, 110, 220))

-- 2. Get the values from SimExtrasStats. State.Get waits for the server to create them.
local hudState = State.Get("SimExtrasState")
assert(hudState, "SimExtrasHud: state 'SimExtrasState' not found. Is the Script ServerScriptService/SimExtrasStats running?")

local name = player.Name -- the per-player keys end with "_<Name>", as in SimExtrasStats
boostButton.Text = `Buy 2x Boost ({hudState:Get("BoostMinutes")} min) - {hudState:Get("BoostPrice")} Coins`

-- 3. Bind the texts. They update by themselves on every change.
StateBinding.BindText(multiplierLabel, hudState, "Multiplier_" .. name, function(value: any): string
	if value == nil then
		return "Multiplier: ..." -- the server is still loading this player's data
	end
	return `Multiplier: x{value}`
end)
StateBinding.BindText(boostLabel, hudState, "BoostLeft_" .. name, function(value: any): string
	if typeof(value) ~= "number" or value <= 0 then
		return "2x Boost: off"
	end
	return string.format("2x Boost: %d:%02d left", value // 60, value % 60)
end)
StateBinding.BindText(bonusButton, hudState, "BonusPrice_" .. name, function(value: any): string
	if value == nil then
		return "..."
	elseif value == 0 then
		return "Coin Bonus: MAX"
	end
	return `Coin Bonus +{hudState:Get("BonusPercent")}% - {value} Coins`
end)
StateBinding.BindText(rebirthButton, hudState, "RebirthPrice_" .. name, function(value: any): string
	if value == nil then
		return "..."
	end
	return `Rebirth (resets Coins) - {value} Coins`
end)

-- 4. Each click asks the server. The answer is shown as a toast.
local busy = false
local function ask(action: string)
	if busy then
		return -- wait for the answer before asking again
	end
	busy = true
	local called, ok, message = pcall(Net.InvokeServer, "SimExtrasBuy", action)
	if not called or ok == nil then
		ok, message = false, "No answer, try again"
	end
	print(`[SimExtrasHud] {action}: {tostring(ok)} {tostring(message)}`)
	Toast.Show({
		Title = "Upgrades",
		Text = tostring(message),
		Variant = if ok == true then "success" else "error",
		Duration = 4,
	})
	busy = false
end

bonusButton.Activated:Connect(function()
	ask("CoinBonus")
end)
boostButton.Activated:Connect(function()
	ask("Boost")
end)
rebirthButton.Activated:Connect(function()
	ask("Rebirth")
end)

-- 5. The auto-collect button opens the Robux window (the server decides).
local function showAutoCollect()
	if player:GetAttribute("SimAutoCollect") == true then
		autoButton.Text = "Auto-Collect: ON"
	else
		autoButton.Text = "Buy Auto-Collect (Robux)"
	end
end
player:GetAttributeChangedSignal("SimAutoCollect"):Connect(showAutoCollect)
showAutoCollect()

autoButton.Activated:Connect(function()
	Net.FireServer("SimBuyAutoCollect")
	print("[SimExtrasHud] asked to buy Auto-Collect")
end)

print("[SimExtrasHud] ready")
```

What it does: two labels (multiplier, boost time left) and four buttons. Every answer appears as a toast.

## Check that it works

If you cannot press Play, ask the user to do these steps and paste the Output lines.

**Part A: no saved data.** Turn **Enable Studio Access to API Services** off (Home → Game Settings → Security) for items 1-7. Then every Play starts from 0 rebirths, bonus level 0, no boost and no 2x Coins, so the numbers below are exact. (If you test with API access on and own 2x Coins from example-simulator, every multiplier shown is 2 times higher: that is fine.)

1. Press **Play**. Output shows `[SimExtrasStats] ready`, `[SimExtrasShop] ready`, `[SimAutoCollect] ready`, `[SimExtrasHud] ready` (and the example-simulator lines), and no red errors.
2. Output shows `[SimExtrasStats] <YourName> loaded: 0 rebirths, bonus level 0, boost 0 s, multiplier x1`, then `[SimExtrasStats] Studio test: <YourName> has at least 1000 Coins`. You have 1000 Coins. The `[SimStats] ... loaded:` line may say 0, 500 or 1000 Coins (the scripts start in any order): all are fine.
3. The player list has a **Rebirths** column (0). At the top middle of the screen, the panel shows `Multiplier: x1`, `2x Boost: off` and four buttons.
4. Click **Coin Bonus +25% - 50 Coins**. Output shows `[SimExtrasShop] <YourName> bought Coin Bonus level 1 for 50 Coins, multiplier now x1.25`. The button shows `- 100 Coins`.
5. Click **Buy 2x Boost (5 min) - 200 Coins**. The label shows `2x Boost: 4:59 left` and counts down. The multiplier shows `x2.5`.
6. Click **Rebirth (resets Coins) - 500 Coins**. Output shows `rebirthed: 1 rebirths, multiplier now x3.75`. Coins become 0. Rebirths becomes 1. The button shows `- 1000 Coins`.
7. Walk into a coin. Output shows `[SimCoins] <YourName> +18 Coins` (5 x 3.75, rounded down).
8. Phone test: in Studio, open **Test → Device** (the device emulator) and pick a phone in landscape. All four buttons and both labels are on the screen and can be clicked. Stop.

**Part B: saving and Robux.** These need API access.

9. Turn **Enable Studio Access to API Services** on. Press **Play**. Click **Coin Bonus**, **Buy 2x Boost** and **Rebirth** once each (skip Rebirth if it costs more Coins than you have). Note the `bonus level`, the rebirths and the boost time left.
10. Stop, then press **Play** again within 5 minutes. The `loaded:` line shows the same rebirths and bonus level as before you stopped, and the boost seconds still left (a bit less: the boost kept counting while you were away).
11. Click **Buy Auto-Collect (Robux)**. With `AutoCollectPassId = 0`, Output warns `no Pass ID`: that is expected. With your Pass ID, a test purchase window opens; buy it (Studio test purchases cost no Robux). Output shows `has auto-collect`, the button shows `Auto-Collect: ON`, and `auto-collected N coins` lines appear when you stand near coins.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Error `SimMultiplier is not a valid member of Folder` | The ModuleScript `SimMultiplier` inside **ServerStorage → GameModules** | The require path must match the Explorer exactly. |
| `SimCoins` still uses `SimConfig.CoinValue * SimConfig.GetMultiplier(player)` | `SimMultiplier.CoinPayout(player)` (Step 2) | Otherwise rebirths, Coin Bonus and the boost give nothing. |
| Changing `CoinValue` in `SimConfig` to make coins worth more | Change `BaseCoinValue` in `SimMultiplier` | After Step 2, `SimConfig.CoinValue` is not used anymore. |
| Changing `GetMultiplier` in `SimConfig` to return the combined value | Leave it; use `SimMultiplier.Get` | `SimShop` checks `GetMultiplier(player) == 2` to know who owns 2x Coins. |
| Saving "seconds left" for the boost | Save the end time: `os.time() + seconds` | Seconds left would need saving every second, and stop while the player is offline. |
| `Economy.Spend(player, "Coins", Economy.Get(player, "Coins"))` for a rebirth | `Economy.Set(player, "Coins", 0)` | Spend refuses amounts over 1,000,000 (`Economy.MaxTransaction`). |
| `BonusPrice = 49.5` or `RebirthPrice = 500.5` | Whole numbers | `Economy.Spend` refuses decimals with a warning. |
| The client sends the price or the multiplier | Send only `"CoinBonus"`, `"Boost"` or `"Rebirth"` | A cheater can send any value. |
| `DoubleField` not equal to `UpgradeField` in `SimConfig` | Both `"SimDoubleCoins"` | `Get` would never see the 2x Coins upgrade. |
| Auto-collect saved in player data | Check the pass on every join (`OwnsGamePass`) | Passes can be refunded; the pass is the truth. |
| Testing the real coin loop in Studio with `StudioTestCoins = 1000` | Set `StudioTestCoins = 0` in `SimMultiplier` (and delete the Script `StudioTestCoins` from example-simulator) | Both top your Coins up on every Play in Studio. They never give Coins in a live game. |
| Expecting the boost to pause while offline | It keeps counting (`os.time`) | This is on purpose: the saved end time works with no extra code. |

## Change it

- Prices, coin value (`BaseCoinValue`), bonus per level, boost length, auto-collect radius: change the numbers in `SimMultiplier`. Nothing else.
- To reset the Coin Bonus on rebirth too: in `rebirth` of `SimExtrasShop`, under `Economy.Set(player, "Coins", 0)`, add `Data.Set(player, SimMultiplier.BonusLevelField, 0)`.
- A new multiplier (a VIP pass, a pet): add one `multiplier *= ...` line inside `SimMultiplier.Get`. Every coin uses it at once.
- To test auto-collect without a pass: set `StudioAutoCollect = true` in `SimMultiplier` (Studio only).
- To test the real economy in Studio: set `StudioTestCoins = 0` in `SimMultiplier`.

### Sell the 2x boost for Robux too

1. On **create.roblox.com**, create a developer product named `2x Boost` (see [robux-purchases](robux-purchases.md) Step 1). Copy its **Product ID**.
2. Create a **Script** in **ServerScriptService** named **SimBoostRobux**. Paste this whole block, then paste your ID on the `BOOST_PRODUCT_ID` line. `0` is fine until then: the button only warns.

```lua
-- Script: ServerScriptService/SimBoostRobux
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local SimMultiplier = require(ServerStorage.GameModules.SimMultiplier)

assert(GaxiaServer.IsInstalled("Monetization"), "SimBoostRobux needs the Monetization package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Monetization = GaxiaServer.Monetization

local BOOST_PRODUCT_ID = 0 -- your developer product ID (a number). 0 = not set yet

if BOOST_PRODUCT_ID ~= 0 then
	-- Runs once per purchase. error() means "not given yet": Roblox retries later (for example when the data is not loaded).
	Monetization.RegisterProduct(BOOST_PRODUCT_ID, function(player: Player, receipt)
		-- The player paid Robux, so never refuse: add the minutes, but stop at BoostMaxMinutes.
		local seconds = SimMultiplier.BoostSecondsLeft(player) + SimMultiplier.BoostMinutes * 60
		seconds = math.min(seconds, SimMultiplier.BoostMaxMinutes * 60)
		if not Data.Set(player, SimMultiplier.BoostEndsField, os.time() + seconds) then
			error("SimBoostRobux: the boost was not saved, Roblox will retry")
		end
		print(`[SimBoostRobux] {player.Name} bought a 2x boost for Robux: {seconds} s left (purchase {receipt.PurchaseId})`)
	end)
end

-- The client asks to open the Robux window. It sends nothing: the server knows the product.
Net.OnServer("SimBuyBoostRobux", function(player: Player)
	if BOOST_PRODUCT_ID == 0 then
		warn("[SimBoostRobux] no Product ID: paste it into BOOST_PRODUCT_ID in SimBoostRobux")
	else
		Monetization.PromptProduct(player, BOOST_PRODUCT_ID)
	end
end, { rate = 2, burst = 4 })

print("[SimBoostRobux] ready")
```

3. Open the LocalScript **SimExtrasHud**. Above the last line `print("[SimExtrasHud] ready")`, paste:

```lua
-- fragment
panel.Size = UDim2.fromOffset(346, 138) -- one more row of buttons
local robuxBoostButton = makeButton("RobuxBoostButton", 7, Color3.fromRGB(0, 170, 120))
robuxBoostButton.Text = "2x Boost (Robux)"
robuxBoostButton.Activated:Connect(function() Net.FireServer("SimBuyBoostRobux") end)
```

4. Check: press **Play**. Output shows `[SimBoostRobux] ready`. Click **2x Boost (Robux)**. With ID `0`, Output warns `no Product ID`. With your ID and API access on, a test window opens; buy it. Output shows `bought a 2x boost for Robux`, and the boost label counts down.

## See also

- [Example simulator](example-simulator.md) · [Robux purchases](robux-purchases.md) · [Shop](shop.md) · [Player data](player-data.md) · [Show values on screen](show-values-on-screen.md)
- [API: Economy](../api/Economy.md) · [API: Data](../api/Data.md) · [API: Monetization](../api/Monetization.md) · [API: State](../api/Core.ReplicatedState.md) · [Troubleshooting](../troubleshooting.md)
