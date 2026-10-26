# Make a shop that sells items for coins

> A shop window lists items with prices. A click buys on the server: it checks the price, takes the Coins and gives the item.

**Use this when** the user asks for: "shop", "store", "buy items with coins", "sell items", "buy button", "item shop", "upgrade shop" (ไทย: "ร้านค้า", "ซื้อของด้วยเหรียญ", "ปุ่มซื้อ", "ขายไอเทม", "ร้านขายของ", "ซื้ออัปเกรด").
**Packages:** pick `Shop` **and** `Item` in the installer. `Shop` brings `Economy`, `Level`, `Monetization` and `Data`; it does **not** bring `Item`. The script stops with a clear message if one is missing.
**You will create:** a Script `ServerScriptService/CoinShop` and a LocalScript `StarterPlayer/StarterPlayerScripts/CoinShopUI`.

How it works: `GaxiaServer.Shop` keeps the catalogue **on the server** (price, currency, a `grant` function per item).
`Shop.Purchase(player, itemId)` checks the gates, takes the Coins with `Economy.Spend`, then runs `grant`. If `grant` errors, the Coins come back.
`Shop` creates **no remotes** and never checks if the player already owns an item. `CoinShop` adds both with `Net`.

## Step 1 — Create the shop on the server

Create a **Script** in **ServerScriptService** named **CoinShop**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/CoinShop
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Shop"), "CoinShop needs the Shop package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Item"), "CoinShop needs the Item package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local Item = GaxiaServer.Item
local Shop = GaxiaServer.Shop

local STUDIO_TEST_COINS = 500 -- Studio only: Coins each tester gets on join, to test buying. No effect in a live game.

-- Gives `count` of an item. error() makes Shop give the Coins back.
local function giveItem(itemId: string, count: number): (player: Player) -> ()
	return function(player: Player)
		if not Item.Give(player, itemId, count) then
			error(`Item.Give failed for {itemId}`)
		end
	end
end

-- The catalogue. Prices live ONLY here, on the server. `name` is the text on the button.
Shop.RegisterItem("Apple", { id = "Apple", name = "Apple", cost = 10, currency = "Coins", grant = giveItem("Apple", 1) })
Shop.RegisterItem("AppleBox", { id = "AppleBox", name = "Box of 10 Apples", cost = 80, currency = "Coins", grant = giveItem("Apple", 10) })
Shop.RegisterItem("WoodenSword", { id = "WoodenSword", name = "Wooden Sword", cost = 150, currency = "Coins", grant = giveItem("WoodenSword", 1) })

local ONE_TIME: { [string]: boolean } = { WoodenSword = true } -- owned once at most (Tools, upgrades)

-- Text the player sees for each failure reason from Shop.Purchase.
local MESSAGES: { [string]: string } = {
	unknown_item = "That item is not for sale", requires_gamepass = "You need a game pass for this",
	level_too_low = "Your level is too low", insufficient_funds = "Not enough Coins",
	grant_failed = "Something went wrong, your Coins were returned", prompted_robux = "Finish the Robux purchase in the window",
}

-- The client asks for the list to show. Send only plain values: never the grant functions.
type CatalogEntry = { id: string, name: string, cost: number, currency: string }
Net.OnInvoke("ShopGetCatalog", function(_player: Player)
	local list: { CatalogEntry } = {}
	for _, shopItem in Shop.GetCatalog() do
		local currency = if shopItem.devProductId then "Robux" else shopItem.currency or "Coins"
		table.insert(list, { id = shopItem.id, name = shopItem.name, cost = shopItem.cost or 0, currency = currency })
	end
	table.sort(list, function(x: CatalogEntry, y: CatalogEntry) return x.cost < y.cost end)
	return list
end)

-- The client asks to buy one item by id. The server checks everything. The rate limit stops spam clicks.
Net.OnInvoke("ShopBuy", function(player: Player, itemId: any): (boolean, string)
	if typeof(itemId) ~= "string" or Shop.Get(itemId) == nil then
		return false, MESSAGES.unknown_item
	end
	if not Data.IsLoaded(player) then
		return false, "Your data is still loading" -- Shop would say "Not enough Coins"
	end
	if ONE_TIME[itemId] and Item.Has(player, itemId) then
		return false, "You already own it"
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
	if RunService:IsStudio() and STUDIO_TEST_COINS > 0 and Data.WaitFor(player, 120) ~= nil then
		Economy.Add(player, "Coins", STUDIO_TEST_COINS)
		print(`[CoinShop] Studio test: gave {player.Name} {STUDIO_TEST_COINS} Coins`)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[CoinShop] ready")
```

## Step 2 — Show the shop buttons on the client

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **CoinShopUI**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/CoinShopUI
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

local Net = Gaxia.Net
local player = Players.LocalPlayer
local busy = false -- true while waiting for the server's answer

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CoinShopGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(260, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y -- grows with the number of buttons
frame.Position = UDim2.new(1, -280, 0.3, 0)
frame.Parent = screenGui

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = frame

local status = Instance.new("TextLabel") -- shows the server's answer for 2 seconds
status.Size = UDim2.new(1, 0, 0, 40)
status.TextScaled = true
status.Text = "Shop"
status.LayoutOrder = 1000
status.Parent = frame

local function addButton(shopItem: { [string]: any }, order: number)
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, 0, 0, 50)
	button.TextScaled = true
	button.LayoutOrder = order
	button.Text = if shopItem.currency == "Robux" then `{shopItem.name} - Robux` else `{shopItem.name} - {shopItem.cost} {shopItem.currency}`
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

1. Press **Play** in Studio. Output shows `[CoinShop] ready` and `[CoinShopUI] ready`, and no red errors.
2. Within a few seconds Output shows `[CoinShop] Studio test: gave <YourName> 500 Coins`.
3. Click **Apple - 10 Coins**. Output shows `[CoinShop] <YourName> bought Apple, Coins left: <number>` and `[CoinShopUI] buy Apple: true Bought! Coins left: <number>`.
   The number is `490` on the first Play. Coins are kept between Plays only with **Enable Studio Access to API Services** ([player-data](player-data.md)).
4. Click **Wooden Sword - 150 Coins** twice (wait 2 seconds between). The second click shows `You already own it` (the first one too if you already had a sword).
5. Click **Box of 10 Apples - 80 Coins** until the Coins run out. That click shows `Not enough Coins`, and Output shows `[CoinShop] <YourName> could not buy AppleBox: insufficient_funds`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Client sends `"ShopBuy", "Apple", 10` (a price) | Client sends only the item id | The server reads the price from the catalogue. A cheater can send any price. |
| `Economy.Spend` and `Item.Give` in your own remote | `Shop.Purchase(player, itemId)` | Shop checks the gates and gives the Coins back when the grant fails. |
| `grant = function(player) Item.Give(player, "Apple", 1) end` | `giveItem("Apple", 1)`, which calls `error()` when `Give` fails | Without an error the Coins are taken and nothing is given. |
| Selling a Tool or upgrade with no ownership check | Add it to `ONE_TIME` (the script checks `Item.Has` first) | Shop sells it again and again: each click takes Coins and only raises the count. |
| `Shop.RegisterItem("Apple", { cost = 10, grant = ... })` | Add `id = "Apple"` to the table | The type of the table needs `id`; Script Analysis shows an error without it. |

## Change it

- To add an item: one more `Shop.RegisterItem("Id", { id = "Id", name = "...", cost = 100, currency = "Coins", grant = giveItem("Id", 1) })`. The frame grows by itself.
- To sell for Gems: `currency = "Gems"`. To give something other than an item, write your own `grant` and call `error("...")` when it fails (the Coins come back).
- To need a level: add `levelReq = 5`. Players gain levels from `GaxiaServer.Level.AddXP(player, 50)` ([progression](progression.md)).
- To need a game pass: add `gamePassReq = 123456789`. A pass bought in this server counts only after the player rejoins (the check is cached, see [robux-purchases](robux-purchases.md)).
- To sell an item for Robux: add `devProductId = <your product id>`. The button shows `Robux` and `Shop.Purchase` opens the Robux window. Keep a `grant` (required, not used): `Monetization.RegisterProduct` gives the item ([robux-purchases](robux-purchases.md)).
- To hide the shop behind a button: add these lines at the end of `CoinShopUI`, above the `print`:
  ```lua
  -- fragment
  frame.Visible = false
  local openButton = Instance.new("TextButton")
  openButton.Size, openButton.Position, openButton.Text = UDim2.fromOffset(120, 40), UDim2.new(1, -140, 0, 20), "Shop"
  openButton.Parent = screenGui
  openButton.Activated:Connect(function() frame.Visible = not frame.Visible end)
  ```

## See also

- [API: Shop](../api/Shop.md) · [API: Economy](../api/Economy.md) · [API: Item](../api/Item.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Items and inventory](items-and-inventory.md) · [Robux purchases](robux-purchases.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Troubleshooting](../troubleshooting.md)
