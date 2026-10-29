# Build a small simulator game from scratch

> A complete coin simulator: coins appear on the map, players walk into them to collect Coins, the Coins are saved and shown in the player list and on screen, and a shop button sells a 2x Coins upgrade with a pop-up message.

**Use this when** the user asks for: "make a simulator", "a whole small game", "a coin collecting game", "build a game from scratch", "example game", "starter game" (ไทย: "ทำเกม simulator", "ทำเกมทั้งเกม", "เกมเก็บเหรียญ", "สร้างเกมตั้งแต่ศูนย์", "ตัวอย่างเกม", "เกมเริ่มต้น").
**Packages:** `Data`, `Player`, `AntiCheat`, `Admin`, `Input`, `Economy`, `Shop`, `UI.Toast`, `UI.StateBinding` (Step 1 installs them; every script stops with a clear message if one is missing).
**You will create:** a ModuleScript `ServerStorage/GameModules/SimConfig`, the Scripts `ServerScriptService/SimStats`, `ServerScriptService/SimCoins` and `ServerScriptService/SimShop`, a LocalScript `StarterPlayer/StarterPlayerScripts/SimHud`, and (to test) the Script `ServerScriptService/StudioTestCoins`.

How the game fits together (each part reuses a pattern from another playbook):

| Part | Script | Pattern from |
|---|---|---|
| Settings in one place, and the "has 2x?" check | `SimConfig` | [02-server-script](../start/02-server-script.md) (GameModules) |
| Coins column in the player list, and the values the HUD shows | `SimStats` | [currency-and-leaderstats](currency-and-leaderstats.md), [show-values-on-screen](show-values-on-screen.md) |
| Coin parts on the map, picked up on touch | `SimCoins` | [currency-and-leaderstats](currency-and-leaderstats.md) (`Economy.Add`) |
| The 2x Coins upgrade, bought on the server | `SimShop` | [shop](shop.md), [04-client-server](../start/04-client-server-communication.md) |
| Coins label, buy button and pop-up message | `SimHud` | [show-values-on-screen](show-values-on-screen.md), [ui](ui.md) |
| Test Coins in Studio | `StudioTestCoins` | [currency-and-leaderstats, Studio test Coins](currency-and-leaderstats.md#studio-test-coins-used-by-other-playbooks) |

## Step 1 — Install the packages

Start from a new **Baseplate** place in Studio (File → New → Baseplate). Then install Gaxia with exactly this pick:

- **Gaxia Companion** (no Rojo): in the **Install** tab click **None**, then tick `Data`, `Player`, `AntiCheat`, `Admin`, `Input`, `Economy`, `Shop`, `UI.Toast`, `UI.StateBinding`. Click **Install / Update Gaxia in this place**. Do not click **All**.
- **Rojo:** in the `gaxia-packages` folder run:

```sh
node tools/packages.mjs build --select Data,Player,AntiCheat,Admin,Input,Economy,Shop,UI.Toast,UI.StateBinding --out ../MyGame/gaxia
```

Full install steps (plugin setup, Rojo serve, status lines): [01-install-packages](../start/01-install-packages.md), Step 2. `Shop` also installs `Level` and `Monetization`: do not tick them.

## Step 2 — Create the game settings

1. In **ServerStorage**, insert a **Folder**. Name it **GameModules**.
2. In **ServerStorage → GameModules**, insert a **ModuleScript**. Name it **SimConfig**. Paste this whole block into it:

```lua
-- ModuleScript: ServerStorage/GameModules/SimConfig
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

local Data = GaxiaServer.Data

-- Every number of the game lives here. Change values here, never inside the Scripts.
local SimConfig = {
	CoinValue = 5, -- Coins for one coin part (before the 2x upgrade)
	MaxCoinParts = 15, -- most coin parts on the map at once
	SpawnSeconds = 1, -- a new coin part every N seconds, until there are MaxCoinParts
	SpawnCenter = Vector3.new(0, 3, 0), -- middle of the coin area (3 studs above the Baseplate)
	SpawnRadius = 40, -- coins appear up to this many studs from SpawnCenter (a whole number)
	UpgradePrice = 100, -- Coins for the 2x Coins upgrade
	UpgradeField = "SimDoubleCoins", -- saved field: true once the player bought 2x Coins
}

-- 2 when the player owns the 2x Coins upgrade, else 1.
function SimConfig.GetMultiplier(player: Player): number
	if Data.Get(player, SimConfig.UpgradeField) == true then
		return 2
	end
	return 1
end

return SimConfig
```

What it does: the three server Scripts read the same numbers and the same `GetMultiplier`, so they never disagree.

## Step 3 — Show Coins in the player list and prepare the HUD values

Create a **Script** in **ServerScriptService** named **SimStats**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/SimStats
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local SimConfig = require(ServerStorage.GameModules.SimConfig)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Economy"), "SimStats needs the Economy package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Player"), "SimStats needs the Player package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local PlayerService = GaxiaServer.Player -- the Gaxia "Player" package (Players above is Roblox's service)
local State = Gaxia.State

-- The values the HUD shows. Per-player keys: "Coins_<Name>" and "Double_<Name>".
local hudState = State.Create("SimHudState", { UpgradePrice = SimConfig.UpgradePrice })

local function coinKey(player: Player): string
	return "Coins_" .. player.Name
end

local function doubleKey(player: Player): string
	return "Double_" .. player.Name
end

-- Every Economy change (coin pickup, purchase, test Coins): update the player list and the HUD.
Economy.OnTransaction:Connect(function(player: Player, currency: string, _delta: number, newBalance: number)
	if currency == "Coins" then
		PlayerService.SetLeaderstat(player, "Coins", newBalance)
		hudState:Set(coinKey(player), newBalance)
	end
end)

-- SimShop saves the upgrade with Data.Set: show it on the HUD.
Data.OnDataChanged:Connect(function(player: Player, key: string, value: any)
	if key == SimConfig.UpgradeField then
		hudState:Set(doubleKey(player), value == true)
	end
end)

local function onPlayerAdded(player: Player)
	-- Coins are in the saved data: wait until it is loaded (nil = the player left).
	if Data.WaitFor(player, 120) == nil or player.Parent == nil then
		return
	end
	local coins = Economy.Get(player, "Coins")
	PlayerService.SetupLeaderstats(player, { Coins = coins })
	hudState:Set(coinKey(player), coins)
	hudState:Set(doubleKey(player), SimConfig.GetMultiplier(player) == 2)
	print(`[SimStats] {player.Name} loaded: {coins} Coins, multiplier x{SimConfig.GetMultiplier(player)}`)
end

-- Players who join later, and players who are already in the game.
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	hudState:Set(coinKey(player), nil) -- nil deletes the player's keys
	hudState:Set(doubleKey(player), nil)
end)

print("[SimStats] ready")
```

What it does: it builds the **Coins** column from the saved balance and keeps it and the HUD values up to date.

## Step 4 — Spawn coins that players collect

Create a **Script** in **ServerScriptService** named **SimCoins**:

```lua
-- Script: ServerScriptService/SimCoins
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local SimConfig = require(ServerStorage.GameModules.SimConfig)

assert(GaxiaServer.IsInstalled("Economy"), "SimCoins needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Economy = GaxiaServer.Economy

local PICKUP_DISTANCE = 12 -- the character must be this close (studs): a far-away fake touch pays nothing

local coinFolder = Instance.new("Folder")
coinFolder.Name = "SimCoinParts"
coinFolder.Parent = workspace

local function spawnCoin()
	local radius = SimConfig.SpawnRadius
	local coin = Instance.new("Part")
	coin.Name = "Coin"
	coin.Shape = Enum.PartType.Ball
	coin.Size = Vector3.new(2, 2, 2)
	coin.Color = Color3.fromRGB(255, 200, 0)
	coin.Material = Enum.Material.Neon
	coin.Anchored = true
	coin.CanCollide = false -- players walk through it; Touched still fires
	coin.Position = SimConfig.SpawnCenter + Vector3.new(math.random(-radius, radius), 0, math.random(-radius, radius))
	coin.Parent = coinFolder

	local collected = false
	-- The connection is removed with the part by coin:Destroy(): no Trove needed.
	coin.Touched:Connect(function(hit: BasePart)
		if collected then
			return -- several body parts touch at once: pay only once
		end
		local character = hit.Parent
		if character == nil or not character:IsA("Model") then
			return
		end
		local player = Players:GetPlayerFromCharacter(character)
		local root = character:FindFirstChild("HumanoidRootPart")
		if player == nil or root == nil or not root:IsA("BasePart") then
			return -- not a player's character
		end
		if (root.Position - coin.Position).Magnitude > PICKUP_DISTANCE then
			return
		end
		collected = true
		local amount = SimConfig.CoinValue * SimConfig.GetMultiplier(player)
		-- Add returns false (and gives nothing) while the player's data is still loading.
		if not Economy.Add(player, "Coins", amount) then
			collected = false -- leave the coin for later
			return
		end
		coin:Destroy()
		print(`[SimCoins] {player.Name} +{amount} Coins (now {Economy.Get(player, "Coins")})`)
	end)
end

print("[SimCoins] ready")

-- This loop never ends, so it is the last thing in the script.
while true do
	if #coinFolder:GetChildren() < SimConfig.MaxCoinParts then
		spawnCoin()
	end
	task.wait(SimConfig.SpawnSeconds)
end
```

What it does: it keeps up to 15 gold balls on the map. Touching one pays 5 Coins (10 with the upgrade) and removes it. `SimStats` updates the player list.

## Step 5 — Sell the 2x Coins upgrade on the server

Create a **Script** in **ServerScriptService** named **SimShop**:

```lua
-- Script: ServerScriptService/SimShop
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local SimConfig = require(ServerStorage.GameModules.SimConfig)

assert(GaxiaServer.IsInstalled("Shop"), "SimShop needs the Shop package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local Shop = GaxiaServer.Shop

local UPGRADE_ID = "DoubleCoins"

-- The price lives only here, on the server. error() in grant makes Shop give the Coins back.
Shop.RegisterItem(UPGRADE_ID, {
	id = UPGRADE_ID,
	name = "2x Coins",
	cost = SimConfig.UpgradePrice,
	currency = "Coins",
	grant = function(player: Player)
		if not Data.Set(player, SimConfig.UpgradeField, true) then
			error("Data.Set failed")
		end
	end,
})

-- Text the player sees for each failure reason from Shop.Purchase.
local MESSAGES: { [string]: string } = {
	not_loaded = "Your data is still loading",
	insufficient_funds = "Not enough Coins",
	grant_failed = "Something went wrong, your Coins were returned",
}

-- The client sends nothing: the server knows the item, the price and who owns it.
Net.OnInvoke("SimBuyUpgrade", function(player: Player): (boolean, string)
	if SimConfig.GetMultiplier(player) == 2 then
		return false, "You already own 2x Coins" -- Shop never checks ownership itself
	end
	local ok, reason = Shop.Purchase(player, UPGRADE_ID)
	if not ok then
		print(`[SimShop] {player.Name} could not buy 2x Coins: {reason}`)
		return false, MESSAGES[reason or ""] or "Purchase failed"
	end
	print(`[SimShop] {player.Name} bought 2x Coins, Coins left: {Economy.Get(player, "Coins")}`)
	return true, "2x Coins bought! Every coin now gives double."
end, { rate = 2, burst = 4 })

print("[SimShop] ready")
```

What it does: one remote, `SimBuyUpgrade`. It checks ownership, then `Shop.Purchase` takes the Coins and saves the upgrade. While the data is still loading, `Shop.Purchase` returns `not_loaded` and takes nothing.

## Step 6 — Show Coins, the buy button and the pop-up on the client

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **SimHud**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/SimHud
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.Toast"), "SimHud needs the UI.Toast package: install it (playbooks/start/01-install-packages.md)")
assert(Gaxia.IsInstalled("UI.StateBinding"), "SimHud needs the UI.StateBinding package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local State = Gaxia.State
local Toast = Gaxia.UI.Toast
local StateBinding = Gaxia.UI.StateBinding
local player = Players.LocalPlayer

-- 1. Build the screen in code.
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SimHud"
screenGui.ResetOnSpawn = false -- keep the HUD after the character respawns
screenGui.Parent = player:WaitForChild("PlayerGui")

local coinsLabel = Instance.new("TextLabel")
coinsLabel.Name = "CoinsLabel"
coinsLabel.Size = UDim2.fromOffset(220, 44)
coinsLabel.Position = UDim2.new(0, 10, 0.5, -22)
coinsLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
coinsLabel.BackgroundTransparency = 0.4
coinsLabel.TextColor3 = Color3.fromRGB(255, 220, 0)
coinsLabel.Font = Enum.Font.GothamBold
coinsLabel.TextScaled = true
coinsLabel.Text = "Coins: ..."
coinsLabel.Parent = screenGui

local buyButton = Instance.new("TextButton")
buyButton.Name = "BuyDoubleButton"
buyButton.Size = UDim2.fromOffset(260, 50)
buyButton.Position = UDim2.new(0.5, -130, 1, -110)
buyButton.BackgroundColor3 = Color3.fromRGB(40, 160, 70)
buyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
buyButton.Font = Enum.Font.GothamBold
buyButton.TextScaled = true
buyButton.Text = "..."
buyButton.Parent = screenGui

-- 2. Get the values from SimStats. State.Get waits (up to ~20 s) for the server to create them.
local hudState = State.Get("SimHudState")
assert(hudState, "SimHud: state 'SimHudState' not found. Is the Script ServerScriptService/SimStats running?")

-- Must be the same keys as coinKey() and doubleKey() in SimStats.
local myCoinKey = "Coins_" .. player.Name
local myDoubleKey = "Double_" .. player.Name
local price = hudState:Get("UpgradePrice")

-- 3. Bind the label and the button text. They update by themselves on every change.
StateBinding.BindText(coinsLabel, hudState, myCoinKey, function(value: any): string
	if value == nil then
		return "Coins: ..." -- the server is still loading this player's data
	end
	return `Coins: {value}`
end)
StateBinding.BindText(buyButton, hudState, myDoubleKey, function(value: any): string
	if value == true then
		return "2x Coins: OWNED"
	end
	return `Buy 2x Coins - {price} Coins`
end)

-- 4. A click asks the server. The answer is shown as a pop-up (toast).
local busy = false
buyButton.Activated:Connect(function()
	if busy then
		return -- wait for the answer before asking again
	end
	busy = true
	-- pcall: the button keeps working if the call errors.
	local called, ok, message = pcall(Net.InvokeServer, "SimBuyUpgrade")
	if not called or ok == nil then
		ok, message = false, "No answer, try again" -- the call failed, or the server dropped it (too many requests)
	end
	print(`[SimHud] buy 2x Coins: {tostring(ok)} {tostring(message)}`)
	Toast.Show({
		Title = "Shop",
		Text = tostring(message),
		Variant = if ok == true then "success" else "error",
		Duration = 4,
	})
	task.wait(1)
	busy = false
end)

print("[SimHud] ready")
```

What it does: the label shows your Coins, the button shows the price (or OWNED), and every answer appears as a toast at the top right.

## Step 7 — Give yourself test Coins in Studio

Create the Script **StudioTestCoins** in **ServerScriptService**. Copy it exactly from [currency-and-leaderstats, Studio test Coins](currency-and-leaderstats.md#studio-test-coins-used-by-other-playbooks).
It gives every tester at least 500 Coins on each Play, only in Studio, so you can test the shop without collecting 20 coins first.

## Check that it works

If you cannot press Play, ask the user to do these steps and paste the Output lines.

1. Press **Play** in Studio. Output shows `[SimStats] ready`, `[SimCoins] ready`, `[SimShop] ready` and `[SimHud] ready` (any order), and no red errors.
2. Within a few seconds Output shows `[SimStats] <YourName> loaded: <N> Coins, multiplier x1` (`<N>` is 0 or 500) and `[StudioTestCoins] <YourName> now has at least 500 Coins`. (With saved data from earlier Plays, the numbers below are higher: that is fine.)
3. The player list (top right) has a **Coins** column. The left label shows the same number. The button shows `Buy 2x Coins - 100 Coins`.
4. Gold balls appear around the spawn, one per second, up to 15. Walk into one. Output shows `[SimCoins] <YourName> +5 Coins (now 505)`, and the column and label show 505.
5. Click the green button. Output shows `[SimShop] <YourName> bought 2x Coins, Coins left: 405` and `[SimHud] buy 2x Coins: true 2x Coins bought! Every coin now gives double.`. A green **Shop** toast appears, and the button shows `2x Coins: OWNED`.
6. Walk into another coin. Output shows `[SimCoins] <YourName> +10 Coins (now 415)`.
7. Click the button again. Output shows `[SimHud] buy 2x Coins: false You already own 2x Coins`, with a red toast.
8. Saving: with **Enable Studio Access to API Services** on ([player-data](player-data.md)), stop and press **Play** again. Step 2's line now says `multiplier x2`. Without API access every Play starts again from 500 test Coins and x1: that is expected.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Error `GameModules is not a valid member of ServerStorage` | A **Folder** named exactly `GameModules` with the ModuleScript `SimConfig` inside (Step 2) | The require path must match the Explorer exactly. |
| `player.leaderstats.Coins.Value += 5` in `SimCoins` | `Economy.Add(player, "Coins", amount)` | The save does not change, and AntiCheat reports `StatTamper` (a kick once enforcing is on). |
| `Data.Set(player, "Coins", ...)` | `Economy.Add` / `Economy.Spend` | Only Economy fires `OnTransaction`, which updates the player list and the HUD. |
| The client sends the price: `Net.InvokeServer("SimBuyUpgrade", 100)` | Send nothing; the server reads `SimConfig.UpgradePrice` | A cheater can send any price. |
| No ownership check before `Shop.Purchase` | Keep the `GetMultiplier(player) == 2` check in `SimShop` | Shop sells the same upgrade again and again, taking Coins each time. |
| Coins column stays empty, label stays `Coins: ...` | Check that `SimStats` exists and has no red error in Output | `SimStats` creates the column and the HUD values after the data loads. |
| `Toast.Show("Bought!")` | `Toast.Show({ Title = "Shop", Text = "Bought!" })` | `Show` takes one table. |
| Expecting Coins from a coin touched in the first seconds after Play | Wait for the line `[SimStats] <YourName> loaded` | Before the data loads, `Economy.Add` returns false; the coin stays for later. |
| `SpawnRadius = 40.5` | Whole numbers: `SpawnRadius = 40` | `math.random` errors with `number has no integer representation`. |
| `coin.Anchored = false` | Keep `coin.Anchored = true` | Unanchored balls fall and roll away. |
| Testing the real coin loop while `StudioTestCoins` exists | Delete the Script `StudioTestCoins` first | It tops you up to 500 Coins on every Play in Studio. It never gives Coins in a live game. |

## Change it

- Coin value, number of coins, spawn speed, area or upgrade price: change the numbers in `SimConfig`. Nothing else.
- After [simulator-extras](simulator-extras.md) Step 2, `SimConfig.CoinValue` is not used anymore: change the coin value in `BaseCoinValue` of `SimMultiplier`.
- To put the coins somewhere else: set `SpawnCenter` to the middle of that area (Y = floor height + 3).
- A 3x upgrade instead: change `return 2` to `return 3` in `GetMultiplier`, and the text in `SimShop` and `SimHud`.
- More items in the shop (Tools, boosts): [shop](shop.md). Sell the upgrade for Robux: [robux-purchases](robux-purchases.md).
- A "click to earn" button instead of coin parts: a client button that calls `Net.FireServer`, and a server `Net.OnServer` handler that checks a cooldown, then `Economy.Add` ([04-client-server](../start/04-client-server-communication.md)).
- Spinning coins, sounds and particles on pickup: [effects-and-feel](effects-and-feel.md). Levels and quests: [progression](progression.md). A global top-10 board: [live-ops](live-ops.md).

## See also

- Next: [rebirths, upgrades, timed boosts and auto-collect](simulator-extras.md)
- [Install packages](../start/01-install-packages.md) · [Server script](../start/02-server-script.md) · [Client script](../start/03-client-script.md) · [Client ↔ server](../start/04-client-server-communication.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Shop](shop.md) · [Show values on screen](show-values-on-screen.md) · [UI](ui.md) · [Player data](player-data.md)
- [API: Economy](../api/Economy.md) · [API: Shop](../api/Shop.md) · [API: State](../api/Core.ReplicatedState.md) · [API: UI.Toast](../api/UI.Toast.md) · [Troubleshooting](../troubleshooting.md)
