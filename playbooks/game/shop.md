# Make a shop that sells items for coins

> A shop window lists items with prices. A click buys on the server: it checks the price, takes the Coins and gives the item.

**Use this when** the user asks for: "shop", "store", "buy items with coins", "sell items", "buy button", "item shop", "upgrade shop" (ไทย: "ร้านค้า", "ซื้อของด้วยเหรียญ", "ปุ่มซื้อ", "ขายไอเทม", "ร้านขายของ", "ซื้ออัปเกรด").
**Packages:** `Shop` (it also installs `Economy`, `Level`, `Monetization` and `Data`) and `Item`. The script below stops with a clear message if one is missing.
**You will create:** a Script `ServerScriptService/CoinShop` and a LocalScript `StarterPlayer/StarterPlayerScripts/CoinShopUI`.

How it works:

- `GaxiaServer.Shop` keeps the catalogue **on the server**: price, currency and a `grant` function per item.
- `Shop.Purchase(player, itemId)` checks the item, the level and game-pass gates, takes the Coins with `Economy.Spend`, then runs `grant`.
  If `grant` errors, the Coins are given back.
- `Shop` creates **no remotes**. Your script adds two with `Net`: one to read the catalogue, one to buy.
- `Shop.Purchase` returns `true, nil` on success, or `false, reason`. Reasons: `"unknown_item"`, `"requires_gamepass"`, `"level_too_low"`, `"prompted_robux"`, `"insufficient_funds"`, `"grant_failed"`.

## Step 1 — Create the shop on the server

Create a **Script** in **ServerScriptService** named **CoinShop**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/CoinShop
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Shop"), "CoinShop needs the Shop package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Item"), "CoinShop needs the Item package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local Item = GaxiaServer.Item
local Shop = GaxiaServer.Shop

-- Studio only: Coins each tester gets on join, so you can test buying. Has no effect in a live game.
local STUDIO_TEST_COINS = 500

-- Gives `count` of an item. error() makes Shop give the Coins back.
local function giveItem(itemId: string, count: number): (player: Player) -> ()
	return function(player: Player)
		local ok = Item.Give(player, itemId, count)
		if not ok then
			error(`Item.Give failed for {itemId}`)
		end
	end
end

-- The catalogue. Prices live ONLY here, on the server. `name` is the text on the button.
Shop.RegisterItem("Apple", { id = "Apple", name = "Apple", cost = 10, currency = "Coins", grant = giveItem("Apple", 1) })
Shop.RegisterItem("AppleBox", { id = "AppleBox", name = "Box of 10 Apples", cost = 80, currency = "Coins", grant = giveItem("Apple", 10) })
Shop.RegisterItem("WoodenSword", { id = "WoodenSword", name = "Wooden Sword", cost = 150, currency = "Coins", grant = giveItem("WoodenSword", 1) })

-- Text the player sees for each failure reason.
local MESSAGES: { [string]: string } = {
	unknown_item = "That item is not for sale",
	requires_gamepass = "You need a game pass for this",
	level_too_low = "Your level is too low",
	insufficient_funds = "Not enough Coins",
	grant_failed = "Something went wrong, your Coins were returned",
	prompted_robux = "Finish the Robux purchase in the window",
}

-- The client asks for the list to show. Send only plain values: never the grant functions.
type CatalogEntry = { id: string, name: string, cost: number, currency: string }
Net.OnInvoke("ShopGetCatalog", function(_player: Player)
	local list: { CatalogEntry } = {}
	for _, shopItem in Shop.GetCatalog() do
		table.insert(list, { id = shopItem.id, name = shopItem.name, cost = shopItem.cost or 0, currency = shopItem.currency or "Coins" })
	end
	table.sort(list, function(x: CatalogEntry, y: CatalogEntry) return x.cost < y.cost end)
	return list
end)

local lastBuyTime: { [Player]: number } = {}

-- The client asks to buy one item by id. The server checks everything.
Net.OnInvoke("ShopBuy", function(player: Player, itemId: any): (boolean, string)
	if typeof(itemId) ~= "string" or Shop.Get(itemId) == nil then
		return false, MESSAGES.unknown_item
	end
	local now = os.clock()
	if now - (lastBuyTime[player] or 0) < 0.5 then
		return false, "Too fast, wait a moment"
	end
	lastBuyTime[player] = now
	if not Data.IsLoaded(player) then
		return false, "Your data is still loading"
	end
	local ok, reason = Shop.Purchase(player, itemId)
	if not ok then
		print(`[CoinShop] {player.Name} could not buy {itemId}: {reason}`)
		return false, MESSAGES[reason or ""] or "Purchase failed"
	end
	local coins = Economy.Get(player, "Coins")
	print(`[CoinShop] {player.Name} bought {itemId}, Coins left: {coins}`)
	return true, `Bought! Coins left: {coins}`
end, { rate = 4, burst = 8 })

local function onPlayerAdded(player: Player)
	if RunService:IsStudio() and STUDIO_TEST_COINS > 0 and Data.WaitFor(player) ~= nil then
		Economy.Add(player, "Coins", STUDIO_TEST_COINS)
		print(`[CoinShop] Studio test: gave {player.Name} {STUDIO_TEST_COINS} Coins`)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player: Player)
	lastBuyTime[player] = nil
end)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[CoinShop] ready")
```

What it does: it registers 3 items and answers two requests: `ShopGetCatalog` (the list) and `ShopBuy` (buy one).
Each item needs `id` (the same text as the first argument) and a `grant` function.

## Step 2 — Show the shop buttons on the client

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **CoinShopUI**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/CoinShopUI
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

local Net = Gaxia.Net
local player = Players.LocalPlayer

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CoinShopGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(260, 300)
frame.Position = UDim2.new(1, -280, 0.5, -150)
frame.Parent = screenGui

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = frame

-- Shows the server's answer for 2 seconds.
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 40)
status.TextScaled = true
status.Text = "Shop"
status.LayoutOrder = 1000
status.Parent = frame

local busy = false

local function addButton(shopItem: { [string]: any }, order: number)
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, 0, 0, 50)
	button.TextScaled = true
	button.LayoutOrder = order
	button.Text = `{shopItem.name} - {shopItem.cost} {shopItem.currency}`
	button.Parent = frame
	button.Activated:Connect(function()
		if busy then
			return -- wait for the answer before asking again
		end
		busy = true
		-- Send only WHICH item. The server knows the price.
		local ok, message = Net.InvokeServer("ShopBuy", shopItem.id)
		if ok == nil then
			message = "No answer, try again" -- dropped by the rate limit
		end
		print(`[CoinShopUI] buy {shopItem.id}: {tostring(ok)} {tostring(message)}`)
		status.Text = tostring(message)
		task.wait(2)
		status.Text = "Shop"
		busy = false
	end)
end

local catalog = Net.InvokeServer("ShopGetCatalog")
if typeof(catalog) == "table" then
	for index, shopItem in catalog do
		addButton(shopItem, index)
	end
end

print("[CoinShopUI] ready")
```

What it does: it asks the server for the list once, makes one button per item, and shows each answer for 2 seconds.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[CoinShop] ready` and `[CoinShopUI] ready`, and no red errors.
3. Within a few seconds Output shows `[CoinShop] Studio test: gave <YourName> 500 Coins`.
4. Click **Apple - 10 Coins**. Output shows `[CoinShop] <YourName> bought Apple, Coins left: <number>` and `[CoinShopUI] buy Apple: true Bought! Coins left: <number>`. On the first Play the number is `490`.
5. Keep clicking **Wooden Sword - 150 Coins** until the Coins run out. That click shows `Not enough Coins`, and Output shows `[CoinShop] <YourName> could not buy WoodenSword: insufficient_funds`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Client sends `"ShopBuy", "Apple", 10` (a price) | Client sends only the item id | The server reads the price from the catalogue. A cheater can send any price. |
| `Economy.Spend` and `Item.Give` in your own remote | `Shop.Purchase(player, itemId)` | Shop checks the gates and gives the Coins back when the grant fails. |
| `grant = function(player) Item.Give(player, "Apple", 1) end` | `giveItem("Apple", 1)`, which calls `error()` when `Give` fails | Without an error the Coins are taken and nothing is given. |
| `Shop.RegisterItem("Apple", { cost = 10, grant = ... })` | Add `id = "Apple"` to the table | The type of the table needs `id`; Script Analysis shows an error without it. |
| Returning `Shop.GetCatalog()` to the client | Copy plain fields (`id`, `name`, `cost`, `currency`) | Functions cannot be sent through a remote. |
| `Shop.RegisterItem` inside `PlayerAdded` or after `task.wait` | At the top level of `CoinShop` | The catalogue must exist before the first click. |
| Leaving `STUDIO_TEST_COINS` as the way players get Coins | Give Coins from gameplay ([currency-and-leaderstats](currency-and-leaderstats.md)) | It only works in Studio. |

## Change it

- To add an item: one more `Shop.RegisterItem("Id", { id = "Id", name = "...", cost = 100, currency = "Coins", grant = giveItem("Id", 1) })`.
- To sell for Gems: `currency = "Gems"`. Any saved number works as a currency.
- To give something other than an item, write your own `grant`. Call `error("...")` when it fails, so the Coins come back:
  ```lua
  -- fragment
  Shop.RegisterItem("Gems50", { id = "Gems50", name = "50 Gems", cost = 1000, currency = "Coins", grant = function(player: Player)
  	if not Economy.Add(player, "Gems", 50) then error("Economy.Add failed") end
  end })
  ```
- To need a level: add `levelReq = 5` (uses `GaxiaServer.Level`). To need a game pass: add `gamePassReq = 123456789`.
  Note: `gamePassReq` uses `Monetization.OwnsGamePass`, which is cached. A pass bought after a `false` check counts only after the player rejoins.
- To sell an item for Robux: add `devProductId = <your product id>`. `Shop.Purchase` then opens the Robux window and returns `false, "prompted_robux"`.
  The item is given by `Monetization.RegisterProduct`, not by `grant` (still required). See [robux-purchases](robux-purchases.md).
- To hide the shop until the player opens it: set `screenGui.Enabled = false` and toggle it from a button ([ui](ui.md)).

## See also

- [API: Shop](../api/Shop.md) · [API: Economy](../api/Economy.md) · [API: Item](../api/Item.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Items and inventory](items-and-inventory.md) · [Robux purchases](robux-purchases.md)
- [Client ↔ server](../start/04-client-server-communication.md) · [Troubleshooting](../troubleshooting.md)
