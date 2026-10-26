# Sell game passes and developer products (Robux)

> Players buy Gems with Robux (a developer product, can be bought many times) and a VIP game pass (bought once), and get them safely every time.

**Use this when** the user asks for: "Robux", "developer product", "dev product", "game pass", "gamepass", "VIP", "sell for Robux", "ProcessReceipt", "MarketplaceService" (ไทย: "ขายของด้วย Robux", "เติม Robux", "เกมพาส", "ดีเวลอปเปอร์โปรดักต์", "ซื้อ VIP", "ขายเพชร", "ระบบเติมเงิน").
**Packages:** pick `Monetization` **and** `Economy` in the installer. `Monetization` brings `Data`; it does **not** bring `Economy`. The script below stops with a clear message if one is missing.
**You will create:** a Script `ServerScriptService/RobuxStore` and a LocalScript `StarterPlayer/StarterPlayerScripts/RobuxButtons`.

How it works:

- A **developer product** can be bought many times (100 Gems). A **game pass** is bought once and owned forever (VIP).
- `Monetization.RegisterProduct(productId, grantFn)` says what a product gives. Monetization owns `MarketplaceService.ProcessReceipt` (it binds it when the server boots).
- Each purchase runs `grantFn(player, receipt)` **once**: the purchase id is saved in the player's data (`ProcessedReceipts`).
- If the player left, the data is not loaded, or `grantFn` errors, the purchase is not lost. Roblox retries later (for example when the player rejoins).
- Game passes have no receipt. Check `Monetization.OwnsGamePass` on join, and apply the perk again right after a purchase.

## Step 1 — Create the product and the pass on Roblox

1. Publish the place (**File → Publish to Roblox**). Products and passes belong to a published experience.
2. Open **create.roblox.com → Creations**, pick your experience, open **Monetization → Developer Products**, click **Create**. Name it `100 Gems`, set a price, save. Copy its **Product ID** (a number).
3. Open **Monetization → Passes**, click **Create a Pass**. Name it `VIP`, add an image, create it. Open it, turn on **Item for Sale**, set a price. Copy its **Pass ID** (a number).

## Step 2 — Grant purchases on the server

Create a **Script** in **ServerScriptService** named **RobuxStore**. Paste this whole block into it, then paste your two IDs on the `PRODUCTS` and `GAME_PASSES` lines.
`0` is fine until you paste them: the script starts without errors, and a click on a button only warns.

```lua
-- Script: ServerScriptService/RobuxStore
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Monetization"), "RobuxStore needs the Monetization package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "RobuxStore needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Economy = GaxiaServer.Economy
local Monetization = GaxiaServer.Monetization

-- Your IDs from Step 1. 0 = not set yet. The client only sends the name ("Gems100", "VIP").
local PRODUCTS: { [string]: number } = { Gems100 = 0 }
local GAME_PASSES: { [string]: number } = { VIP = 0 }

-- ── Developer products: what each one gives ──
-- Runs once per purchase. error() means "not given yet": Roblox retries later.
Monetization.RegisterProduct(PRODUCTS.Gems100, function(player: Player, receipt)
	if not Economy.Add(player, "Gems", 100) then
		error("Economy.Add failed")
	end
	print(`[RobuxStore] gave {player.Name} 100 Gems (purchase {receipt.PurchaseId})`)
end)

Monetization.OnPurchase:Connect(function(player: Player, productId: number)
	print(`[RobuxStore] {player.Name} bought product {productId}, Gems now {Economy.Get(player, "Gems")}`)
end)

-- ── Game passes: apply the perk on join and right after a purchase ──
local function applyVip(player: Player)
	if player:GetAttribute("VIP") == true then
		return
	end
	-- Other scripts check: player:GetAttribute("VIP") == true
	player:SetAttribute("VIP", true)
	print(`[RobuxStore] {player.Name} is VIP`)
end

local function onPlayerAdded(player: Player)
	if GAME_PASSES.VIP ~= 0 and Monetization.OwnsGamePass(player, GAME_PASSES.VIP) then
		applyVip(player)
	end
end

-- Fires on the server when a game pass window closes. wasPurchased = the player paid.
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, gamePassId: number, wasPurchased: boolean)
	if wasPurchased and gamePassId == GAME_PASSES.VIP then
		applyVip(player)
	end
end)

-- ── The client asks to open a purchase window by name ──
Net.OnServer("RobuxBuy", function(player: Player, name: any)
	if typeof(name) ~= "string" then
		return
	end
	local productId = PRODUCTS[name]
	local gamePassId = GAME_PASSES[name]
	if productId and productId ~= 0 then
		Monetization.PromptProduct(player, productId)
	elseif gamePassId and gamePassId ~= 0 then
		if name == "VIP" and player:GetAttribute("VIP") == true then
			print(`[RobuxStore] {player.Name} already owns VIP`)
			return
		end
		Monetization.PromptGamePass(player, gamePassId)
	else
		warn(`[RobuxStore] no ID for "{name}": paste it into PRODUCTS / GAME_PASSES in RobuxStore`)
	end
end, { rate = 2, burst = 4 })

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[RobuxStore] ready")
```

What it does: the server opens the Robux window, gives 100 Gems once per paid receipt, and marks VIP players.
The button uses `FireServer` + `Net.OnServer` because it needs no answer (Roblox shows the window). Use `InvokeServer` + `Net.OnInvoke` when a button needs an answer, as in [shop](shop.md).
Register every product at the **top level** of a Script, before any `task.wait`.

## Step 3 — Add buy buttons on the client

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **RobuxButtons**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/RobuxButtons
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

local Net = Gaxia.Net
local player = Players.LocalPlayer

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RobuxButtonsGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local function makeButton(text: string, y: number, productName: string)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(220, 50)
	button.Position = UDim2.new(0, 20, 0, y)
	button.TextScaled = true
	button.Text = text
	button.Parent = screenGui
	button.Activated:Connect(function()
		-- Send only the NAME. The server knows the IDs and opens the window.
		Net.FireServer("RobuxBuy", productName)
		print(`[RobuxButtons] asked to buy {productName}`)
	end)
	return button
end

makeButton("Buy 100 Gems", 120, "Gems100")
local vipButton = makeButton("Buy VIP", 180, "VIP")

-- The server sets the VIP attribute. Show it on the button.
local function showVip()
	if player:GetAttribute("VIP") == true then
		vipButton.Text = "VIP owned"
	end
end
player:GetAttributeChangedSignal("VIP"):Connect(showVip)
showVip()

print("[RobuxButtons] ready")
```

What it does: two buttons ask the server to open the Robux window. The VIP button changes to `VIP owned`.

## Check that it works

1. In **Home → Game Settings → Security**, turn on **Enable Studio Access to API Services**.
2. Press **Play**. Output shows `[RobuxStore] ready` and `[RobuxButtons] ready`, and no red errors.
3. Click **Buy 100 Gems**. A test purchase window opens (Studio purchases are free). Click **Buy**.
4. Output shows `[RobuxStore] gave <YourName> 100 Gems (purchase ...)` and `[RobuxStore] <YourName> bought product <id>, Gems now <number>`.
5. Click **Buy VIP** and buy. Output shows `[RobuxStore] <YourName> is VIP`, and the button shows `VIP owned`. Click it again: Output shows `[RobuxStore] <YourName> already owns VIP`.
   Studio test passes are not kept: on the next Play you are not VIP. That is normal.
6. Output shows `no ID for "Gems100"`? Paste the ID from Step 1 into `PRODUCTS` (or `GAME_PASSES`).

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `MarketplaceService.ProcessReceipt = function ... end` | `Monetization.RegisterProduct(id, grantFn)` | Only one ProcessReceipt can exist. Yours replaces Monetization's, and purchases can be lost or given twice. |
| Giving the Gems in `PromptProductPurchaseFinished` | Give them only in `grantFn` | That event only says the window closed. It is not retried, so a failed grant is lost. |
| `grantFn` ignores `Economy.Add` returning `false` | `if not Economy.Add(...) then error("...") end` | Without the error the purchase is recorded as given, and the player gets nothing. |
| `grantFn` gives Gems, then an item whose `Give` can fail | Give one thing per product, or check everything before you give | After an `error()` the whole `grantFn` runs again: the Gems would be given twice. |
| `grantFn` saves to your own DataStore | Change the player's data (`Economy`, `Item`, `Data.Set`) | The receipt record is saved in the same profile, so both save together. |
| `RegisterProduct` inside `PlayerAdded` or after `task.wait` | At the top level of `RobuxStore` | Until it is registered, receipts for it wait (they are retried later). |
| Client sends a product ID or "give me Gems" | Client sends a name; the server looks up the ID | A cheater can send any value. |
| Perk applied only after `OwnsGamePass` on join | Also use `PromptGamePassPurchaseFinished` | `OwnsGamePass` is cached: once it returned `false` (also when the Roblox check failed), it keeps returning `false` until the player rejoins. |
| Other scripts call `Monetization.OwnsGamePass` for VIP | They read `player:GetAttribute("VIP") == true` | The attribute turns on right after a purchase; the cached `OwnsGamePass` stays `false` this session. |
| VIP perk saved in player data | Check the pass on every join | Passes can be refunded or removed; the pass is the truth. |

## Change it

- To sell another product: add it to `PRODUCTS` (`Gems500 = 1234567`) and add one more `Monetization.RegisterProduct(PRODUCTS.Gems500, function(player, receipt) ... end)`.
  Then add its button in `RobuxButtons`, under the other two: `makeButton("Buy 500 Gems", 240, "Gems500")`.
- To give an item instead of Gems: in `grantFn`, `local ok = GaxiaServer.Item.Give(player, "Sword", 1)` and `if not ok then error("Item.Give failed") end` ([items-and-inventory](items-and-inventory.md)).
- To open the window from server code (a Robux door, an NPC): `Monetization.PromptProduct(player, PRODUCTS.Gems100)` or `Monetization.PromptGamePass(player, GAME_PASSES.VIP)`.
- To give VIP double Coins in `CoinPayout` ([currency-and-leaderstats](currency-and-leaderstats.md) Step 2): replace the line `if Economy.Add(player, "Coins", COINS_PER_PAYOUT) then` with:
  ```lua
  -- fragment
  local amount = if player:GetAttribute("VIP") == true then COINS_PER_PAYOUT * 2 else COINS_PER_PAYOUT
  if Economy.Add(player, "Coins", amount) then
  ```
- To sell a shop item for Robux: give the `Shop` item `devProductId = PRODUCTS.Gems100` ([shop](shop.md)). Its reward still comes from `RegisterProduct`.
- Monetization starts at server boot whenever it is installed with picked packages. In a full install it starts the first time a script uses `GaxiaServer.Monetization`; `RobuxStore` does that at the top. Never assign `ProcessReceipt` anywhere else.

## See also

- [API: Monetization](../api/Monetization.md) · [API: Economy](../api/Economy.md)
- [Shop](shop.md) · [Coins and leaderstats](currency-and-leaderstats.md) · [Player data](player-data.md)
- [Client ↔ server](../start/04-client-server-communication.md) · [Troubleshooting](../troubleshooting.md)
