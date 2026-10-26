# Give, take and track items (and tools, trading)

> Players own saved items (apples, swords), see a count on screen, hold a real Tool for each owned tool item, and can trade safely.

**Use this when** the user asks for: "items", "inventory", "give the player an item", "remove an item", "how many X does the player have", "give a tool / sword", "equip", "trading" (ไทย: "ไอเทม", "กระเป๋า", "ให้ไอเทมผู้เล่น", "ลบไอเทม", "นับไอเทม", "ให้ดาบ", "ให้ tool", "สวมใส่", "เทรด", "แลกของ").
**Packages:** `Item` (it also installs `Data`), `Tool` (Step 3), `Trade` (Step 4, it also installs `Economy`). Each script stops with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/ItemManager`, `ServerScriptService/ToolGiver`, `ServerScriptService/TradeHandler` and a LocalScript `StarterPlayer/StarterPlayerScripts/ItemCounter`.

Pick the package:

| You need | Use | Saved? |
|---|---|---|
| A count per item name: 5 Apple, 1 WoodenSword (**default: start here**) | `GaxiaServer.Item` | yes |
| Unique items with their own stats, stacks and equip slots (RPG gear) | `GaxiaServer.Inventory` | yes |
| A catalogue that describes items (rarity, category, sell price) | `GaxiaServer.ItemDef` | no (register it at boot) |
| A Roblox `Tool` in the hotbar, safe from duplication | `GaxiaServer.Tool`, with `Item` saving who owns it | no (rebuilt on spawn) |
| Two players swap `Item` counts and Coins | `GaxiaServer.Trade` | yes (through `Item` / `Economy`) |

Rules of `Item`: before the player's data is loaded, `Item.Give` and `Item.Remove` return `false` and change nothing.
`Item.Remove` also returns `false` when the player has too few. Name items with letters and digits only (`WoodenSword`, not `Wooden Sword`).

## Step 1 — Give, take and count items on the server

Create a **Script** in **ServerScriptService** named **ItemManager**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/ItemManager
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Item"), "ItemManager needs the Item package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local Item = GaxiaServer.Item

-- Items every new player gets once.
local STARTER_ITEMS: { [string]: number } = { Apple = 3, WoodenSword = 1 }

-- Copy a count to a player attribute ("Item_Apple"), so LocalScripts can read it.
local function showCount(player: Player, itemId: string, count: number)
	player:SetAttribute(`Item_{itemId}`, count)
end

local function onPlayerAdded(player: Player)
	if Data.WaitFor(player) == nil then
		return -- the player left before the data loaded
	end
	-- Give starter items only once: remember it in a saved field.
	if Data.Get(player, "GotStarterItems") ~= true then
		for itemId, count in STARTER_ITEMS do
			Item.Give(player, itemId, count)
		end
		Data.Set(player, "GotStarterItems", true)
	end
	local counts: { [string]: number } = Item.GetInventory(player) or {}
	for itemId, count in counts do
		showCount(player, itemId, count)
	end
	print(`[ItemManager] {player.Name} has {Item.Count(player, "Apple")} Apple, sword: {Item.Has(player, "WoodenSword")}`)
end

-- Fires after every Give / Remove / Clear (also from the shop and trades).
Item.OnItemChanged:Connect(function(player: Player, itemId: string, newCount: number, delta: number)
	print(`[ItemManager] {player.Name} {itemId}: {newCount} (change {delta})`)
	showCount(player, itemId, newCount)
end)

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[ItemManager] ready")
```

What it does: a new player gets 3 Apple and 1 WoodenSword once. Every count is copied to an attribute for the screen.
Anywhere else on the server use `Item.Give(player, "Apple", 5)`, `Item.Remove(player, "Apple", 1)`, `Item.Has(player, "Apple", 2)` and `Item.Count(player, "Apple")`.

## Step 2 — Show a count on the screen

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **ItemCounter**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/ItemCounter
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local ATTRIBUTE = "Item_Apple" -- "Item_" + the item name

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ItemCounterGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(200, 50)
label.Position = UDim2.new(0, 20, 0.5, -25)
label.TextScaled = true
label.Parent = screenGui

local function refresh()
	local count = player:GetAttribute(ATTRIBUTE)
	label.Text = `Apple: {typeof(count) == "number" and count or 0}`
end

player:GetAttributeChangedSignal(ATTRIBUTE):Connect(refresh)
refresh()

print("[ItemCounter] ready")
```

What it does: the label shows `Apple: 3` and updates by itself. The client only reads; only the server changes counts.

## Step 3 — Give real Tools for owned items

`Item` saves who owns a sword. `Tool` builds the hotbar Tool on every spawn (the Backpack empties on respawn).
Tools made by `GaxiaServer.Tool` carry a UID: the AntiCheat accepts them and destroys copies.

Create a **Script** in **ServerScriptService** named **ToolGiver**:

```lua
-- Script: ServerScriptService/ToolGiver
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Item"), "ToolGiver needs the Item package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Tool"), "ToolGiver needs the Tool package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local Item = GaxiaServer.Item
local Tool = GaxiaServer.Tool

local TOOL_ITEMS: { [string]: boolean } = { WoodenSword = true } -- item names that are Tools
local spawnConnections: { [Player]: RBXScriptConnection } = {}

-- The Tool with this name in the Backpack or in the character's hand, if any.
local function findTool(player: Player, itemId: string): Instance?
	local backpack = player:FindFirstChildOfClass("Backpack")
	return (backpack and backpack:FindFirstChild(itemId)) or (player.Character and player.Character:FindFirstChild(itemId))
end

local function giveTool(player: Player, itemId: string)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack == nil or findTool(player, itemId) then
		return -- no Backpack yet, or the player already has this Tool
	end
	local tool = Tool.Create(itemId, { CanBeDropped = false }) -- tracked, not parented yet
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, 4, 0.4)
	handle.CanCollide = false
	handle.Parent = tool
	tool.Parent = backpack
	print(`[ToolGiver] gave {itemId} to {player.Name}`)
end

local function giveOwnedTools(player: Player)
	for itemId in TOOL_ITEMS do
		if Item.Has(player, itemId) then
			giveTool(player, itemId)
		end
	end
end

local function onPlayerAdded(player: Player)
	if Data.WaitFor(player) == nil then
		return
	end
	spawnConnections[player] = player.CharacterAdded:Connect(function()
		task.wait() -- let Roblox finish the new Backpack
		giveOwnedTools(player)
	end)
	giveOwnedTools(player)
end

-- Keep Tools in sync with the saved counts (shop, trades, admin commands).
Item.OnItemChanged:Connect(function(player: Player, itemId: string, newCount: number)
	if not TOOL_ITEMS[itemId] then
		return
	end
	if newCount > 0 then
		giveTool(player, itemId)
	else
		local tool = findTool(player, itemId)
		if tool then
			tool:Destroy()
		end
	end
end)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player: Player)
	local connection = spawnConnections[player]
	if connection then
		connection:Disconnect()
	end
	spawnConnections[player] = nil
end)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[ToolGiver] ready")
```

What it does: a player who owns `WoodenSword` gets a sword Tool on every spawn. It is removed when the count drops to 0.

## Step 4 — (Optional) Trade items and Coins between players

`Trade` swaps `Item` counts and `Economy` currencies. Both players must confirm; any change un-confirms both.
The swap re-checks ownership and rolls back if any part fails. `Trade` has no remotes and no invites: this script adds them.

Create a **Script** in **ServerScriptService** named **TradeHandler**:

```lua
-- Script: ServerScriptService/TradeHandler
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Trade"), "TradeHandler needs the Trade package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Item = GaxiaServer.Item
local Economy = GaxiaServer.Economy
local Trade = GaxiaServer.Trade

local TRADABLE: { [string]: boolean } = { Apple = true, WoodenSword = true }
local invites: { [Player]: Player } = {} -- invited player -> who invited them

local function isCount(n: any): boolean
	return typeof(n) == "number" and n == math.floor(n) and n >= 1 and n <= 1000
end

-- One remote for every trade action. The server checks each one.
Net.OnInvoke("TradeAction", function(player: Player, action: any, a: any, b: any): (boolean, string)
	local tradeId = Trade.GetActiveTrade(player)
	if action == "invite" then -- a = the other player's UserId
		local target = if typeof(a) == "number" then Players:GetPlayerByUserId(a) else nil
		if not target or target == player then return false, "Player not found" end
		invites[target] = player
		Net.FireClient(target, "TradeInvited", player.UserId, player.Name)
		return true, `Invited {target.Name}`
	elseif action == "accept" then -- a = the inviter's UserId
		local from = invites[player]
		if not from or from.UserId ~= a or from.Parent == nil then return false, "No invite" end
		invites[player] = nil
		local id, err = Trade.Request(from, player)
		return id ~= nil, if id then "Trade started" else tostring(err)
	elseif tradeId == nil then
		return false, "You are not in a trade"
	elseif action == "item" then -- a = item name, b = count
		if typeof(a) ~= "string" or not TRADABLE[a] or not isCount(b) then return false, "Bad item" end
		if not Item.Has(player, a, b) then return false, "You do not have that many" end
		return Trade.AddItem(player, tradeId, a, b)
	elseif action == "coins" then -- a = amount
		if not isCount(a) or Economy.Get(player, "Coins") < a then return false, "Not enough Coins" end
		return Trade.AddCurrency(player, tradeId, "Coins", a)
	elseif action == "confirm" then
		local ok, done, message = Trade.Confirm(player, tradeId)
		print(`[TradeHandler] {player.Name} confirmed: ok={ok} done={done} {message}`)
		return ok, message
	elseif action == "cancel" then
		return Trade.Cancel(player, tradeId), "Cancelled"
	end
	return false, "Unknown action"
end, { rate = 5, burst = 10 })

-- Send both offers to both players after every change, so they see what they get.
Trade.OnUpdate:Connect(function(tradeId: string)
	local t = Trade.GetTrade(tradeId)
	if t == nil then return end
	for _, side in { t.a, t.b } do
		local offer = t.offers[side.UserId]
		for _, viewer in { t.a, t.b } do
			Net.FireClient(viewer, "TradeUpdated", side.Name, offer.items, offer.currencies, offer.confirmed)
		end
	end
end)
Trade.OnComplete:Connect(function(tradeId: string, success: boolean)
	print(`[TradeHandler] {tradeId} finished, success = {success}`)
end)

Net.OnServer("TradeInvited", function() end) -- create the server -> client remotes now
Net.OnServer("TradeUpdated", function() end)

-- Trade does NOT cancel a trade when a player leaves: do it here.
Players.PlayerRemoving:Connect(function(player: Player)
	invites[player] = nil
	local tradeId = Trade.GetActiveTrade(player)
	if tradeId then
		Trade.Cancel(player, tradeId)
	end
end)

print("[TradeHandler] ready")
```

What it does: A invites B, B accepts, both add items or Coins, both confirm. A client calls for example `Net.InvokeServer("TradeAction", "item", "Apple", 2)`.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[ItemManager] ready`, `[ToolGiver] ready`, `[TradeHandler] ready`, `[ItemCounter] ready`, and no red errors.
3. Output shows `[ItemManager] <YourName> has 3 Apple, sword: true`. On the first Play it also shows `[ItemManager] <YourName> Apple: 3 (change 3)`.
4. Output shows `[ToolGiver] gave WoodenSword to <YourName>`. The sword is in the hotbar. The label shows `Apple: 3`.
5. Trading needs 2 players: **Test → Clients and Servers → 2 Players → Start**.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Item.Give` in `PlayerAdded` right away | `Data.WaitFor(player)` first | Before the data loads, `Give` returns `false` and gives nothing. |
| `Data.Set(player, "Inventory", ...)` | `Item.Give` / `Item.Remove` | Only `Item` fires `OnItemChanged` (screen, Tools) and clamps bad counts. |
| `Instance.new("Tool")` or `:Clone()` put in the Backpack | `Tool.Create(...)`, then `tool.Parent = backpack` | Untracked Tools are flagged **hard** by the AntiCheat `Backpack` detector. |
| `Tool.Track(template)` on a template in ServerStorage | Clone first, then `Tool.Track(clone)` | The template's UID is copied to every clone; each clone is destroyed as a duplicate. |
| Giving the Tool only once | Save the count with `Item`; give the Tool on every spawn | The Backpack is emptied when the character respawns. |
| The client sends `"Give", "Apple", 99` | The client asks; the server checks names and counts | A cheater can send any value. |
| Trading `Inventory` items, Pets or Tools directly | Trade `Item` counts and currencies only | `Trade` checks and moves nothing else. `ToolGiver` updates the Tools. |
| No `Trade.Cancel` when a player leaves | Cancel in `Players.PlayerRemoving` | Otherwise that player stays "already trading" until the server restarts. |

## Change it

- To remove all of one item: `Item.Clear(player, "Apple")`. `Item.Give` returns `ok, delivered`. The cap per item is 999999 (`MaxItemCount` in `GaxiaServer.Config.Inventory`).
- To describe items in one place, add at the top of `ItemManager` (check `GaxiaServer.IsInstalled("ItemDef")` first):
  ```lua
  -- fragment
  GaxiaServer.ItemDef.RegisterMany({ Apple = { rarity = "common", sellPrice = 2 }, WoodenSword = { rarity = "rare", category = "Tool" } })
  local applePrice = GaxiaServer.ItemDef.GetField("Apple", "sellPrice", 0)
  ```
- For unique items with stats and slots: `GaxiaServer.Inventory.DefineItem("Sword", { EquipSlot = "Weapon" })`, `local uid = GaxiaServer.Inventory.Add(player, "Sword", { Props = { damage = 12 } })`, `GaxiaServer.Inventory.Equip(player, uid)`. Call them only after `Data.WaitFor(player)`: Inventory does not check that data is loaded.
- To use your own sword model: put a Tool named `WoodenSword` (with a part named `Handle`) in **ServerStorage**. In `giveTool`, replace the lines from `local tool = Tool.Create(...)` to `handle.Parent = tool` with:
  ```lua
  -- fragment
  local template = game:GetService("ServerStorage"):WaitForChild(itemId) :: Tool
  local tool = template:Clone()
  Tool.Track(tool) -- gives the clone its own UID, so the AntiCheat accepts it
  ```
- To sell items for Coins: [shop](shop.md).

## See also

- [API: Item](../api/Item.md) · [API: Inventory](../api/Inventory.md) · [API: ItemDef](../api/ItemDef.md) · [API: Tool](../api/Tool.md) · [API: Trade](../api/Trade.md)
- [Player data](player-data.md) · [Coins and leaderstats](currency-and-leaderstats.md) · [Shop](shop.md) · [Client ↔ server](../start/04-client-server-communication.md)
- [Show values on screen](show-values-on-screen.md) · [Anti-cheat and bans](anticheat-and-bans.md) · [Troubleshooting](../troubleshooting.md)
