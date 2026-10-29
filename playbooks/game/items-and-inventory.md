# Give, take and track items (and tools, trading)

> Players own saved items (apples, swords), see the counts on screen, and hold a real Tool for each owned tool item.

**Use this when** the user asks for: "items", "inventory", "give the player an item", "remove an item", "how many X does the player have", "give a tool / sword", "equip", "trading" (ไทย: "ไอเทม", "กระเป๋า", "ให้ไอเทมผู้เล่น", "ลบไอเทม", "นับไอเทม", "ให้ดาบ", "ให้ tool", "สวมใส่", "เทรด", "แลกของ").
**Packages:** pick `Item` and `Tool` in the installer before Step 1 (`Item` brings `Data`). Only the Simulator row in start/01 lists `Item`, and only the Fighting row lists `Tool`: pick them by name. Each script stops with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/ItemManager` and `ServerScriptService/ToolGiver`, and a LocalScript `StarterPlayer/StarterPlayerScripts/ItemCounter`.

| You need | Use |
|---|---|
| A saved count per item name: 5 Apple, 1 WoodenSword (**default: this playbook**) | `GaxiaServer.Item` (Steps 1–2) |
| A Roblox `Tool` in the hotbar, safe from duplication | `GaxiaServer.Tool` (Step 3) |
| Unique items with their own stats, stacks and equip slots (RPG gear) | `GaxiaServer.Inventory` (Change it) |
| A catalogue that describes items (rarity, category, sell price) | `GaxiaServer.ItemDef` (Change it) |
| Two players swap `Item` counts and Coins | `GaxiaServer.Trade` (Change it) |

## Step 1 — Give, take and count items on the server

Create a **Script** in **ServerScriptService** named **ItemManager**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/ItemManager
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Item"), "ItemManager needs the Item package: install it (playbooks/start/01-install-packages.md)")
local Data = GaxiaServer.Data
local Item = GaxiaServer.Item

local STARTER_ITEMS: { [string]: number } = { Apple = 3, WoodenSword = 1 } -- every new player gets these once

local function onPlayerAdded(player: Player)
	if Data.WaitFor(player, 120) == nil then
		return -- the player left before the data loaded
	end
	-- Give starter items only once: remember it in a saved field.
	if Data.Get(player, "GotStarterItems") ~= true then
		for itemId, count in STARTER_ITEMS do
			Item.Give(player, itemId, count)
		end
		Data.Set(player, "GotStarterItems", true)
	end
	-- Copy every count to a player attribute ("Item_Apple"), so LocalScripts can read it.
	local counts: { [string]: number } = Item.GetInventory(player) or {}
	for itemId, count in counts do
		player:SetAttribute(`Item_{itemId}`, count)
	end
	print(`[ItemManager] {player.Name} has {Item.Count(player, "Apple")} Apple, sword: {Item.Has(player, "WoodenSword")}`)
end

Item.OnItemChanged:Connect(function(player: Player, itemId: string, newCount: number, delta: number) -- every Give / Remove / Clear
	print(`[ItemManager] {player.Name} {itemId}: {newCount} (change {delta})`)
	player:SetAttribute(`Item_{itemId}`, newCount)
end)
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[ItemManager] ready")
```

What it does: a new player gets 3 Apple and 1 WoodenSword once. `Data.Set` may create a new key like `GotStarterItems` (never a taken name: [player-data](player-data.md)).
Name items with letters and digits only (`WoodenSword`, not `Wooden Sword`). Each count goes to a player attribute `Item_<name>`, and a space makes `SetAttribute` error.
Anywhere else on the server use `Item.Give(player, "Apple", 5)`, `Item.Remove(player, "Apple", 1)`, `Item.Has(player, "Apple", 2)`, `Item.Count(player, "Apple")` and `Item.Clear(player, "Apple")`.
Before the data loads, `Give` and `Remove` return `false` and change nothing. `Remove` also returns `false` when the player has too few. The cap per item is 999999.

## Step 2 — Show the counts on the screen

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **ItemCounter**. It shows one label per name in `SHOWN_ITEMS` (`Apple: 3`). The client only reads counts.

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/ItemCounter
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local SHOWN_ITEMS = { "Apple", "WoodenSword" } -- item names to show, top to bottom

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ItemCounterGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")
for index, itemId in SHOWN_ITEMS do
	local attribute = `Item_{itemId}` -- set by ItemManager
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(220, 40)
	label.Position = UDim2.new(0, 20, 0.5, (index - 1) * 45)
	label.TextScaled = true
	label.Parent = screenGui
	local function refresh()
		local count = player:GetAttribute(attribute)
		label.Text = `{itemId}: {if typeof(count) == "number" then count else 0}`
	end
	player:GetAttributeChangedSignal(attribute):Connect(refresh)
	refresh()
end

print("[ItemCounter] ready")
```

## Step 3 — Give real Tools for owned items

`Item` saves who owns a sword. ToolGiver rebuilds the Tool on every spawn, because Roblox empties the Backpack on respawn. Tools made by `GaxiaServer.Tool.Create` carry a tracked UID, so the AntiCheat `Backpack` detector accepts them. Untracked Tools are flagged (and destroyed once AntiCheat `Enforce` is on).

Create a **Script** in **ServerScriptService** named **ToolGiver**. An owner of `WoodenSword` gets the sword on every spawn; it goes away when the count is 0.

```lua
-- Script: ServerScriptService/ToolGiver
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Item"), "ToolGiver needs the Item package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Tool"), "ToolGiver needs the Tool package: install it (playbooks/start/01-install-packages.md)")
local Data = GaxiaServer.Data
local Item = GaxiaServer.Item
local Tool = GaxiaServer.Tool
local Trove = Gaxia.Trove

local TOOL_ITEMS: { [string]: boolean } = { WoodenSword = true } -- item names that are Tools

local function syncTools(player: Player, backpack: Instance) -- give or remove Tools to match the saved counts
	for itemId in TOOL_ITEMS do
		local character = player.Character
		local existing = backpack:FindFirstChild(itemId) or (if character then character:FindFirstChild(itemId) else nil)
		if Item.Has(player, itemId) and existing == nil then
			-- Create (not Give): the new Tool is empty, so add the Handle (the part the player holds) before parenting.
			local tool = Tool.Create(itemId, { CanBeDropped = false })
			local handle = Instance.new("Part")
			handle.Name = "Handle"
			handle.Size = Vector3.new(0.4, 4, 0.4)
			handle.CanCollide = false
			handle.Parent = tool
			tool.Parent = backpack
			print(`[ToolGiver] gave {itemId} to {player.Name}`)
		elseif existing and not Item.Has(player, itemId) then
			existing:Destroy()
		end
	end
end

local function onPlayerAdded(player: Player)
	if Data.WaitFor(player, 120) == nil then
		return
	end
	local function onSpawn()
		task.wait() -- let Roblox finish the new Backpack
		local backpack: Instance? = player:WaitForChild("Backpack", 5)
		if backpack then
			syncTools(player, backpack)
		end
	end
	local trove = Trove.new()
	trove:AttachToInstance(player) -- cleans up (disconnects) when the player leaves
	trove:Connect(player.CharacterAdded, onSpawn) -- every respawn
	onSpawn() -- the character that is already there
end

Item.OnItemChanged:Connect(function(player: Player, itemId: string) -- a count changed (shop, trades, admin)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if TOOL_ITEMS[itemId] and backpack then
		syncTools(player, backpack)
	end
end)

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[ToolGiver] ready")
```

## Check that it works

1. Press **Play** in Studio. Output shows `[ItemManager] ready`, `[ToolGiver] ready`, `[ItemCounter] ready`, and no red errors.
2. Output shows `[ItemManager] <YourName> has 3 Apple, sword: true`. The labels show `Apple: 3` and `WoodenSword: 1`.
3. Output shows `[ToolGiver] gave WoodenSword to <YourName>`. The sword is in the hotbar.
4. Reset the character (**Esc → Reset Character → Reset**). Output shows `[ToolGiver] gave WoodenSword to <YourName>` again.
5. The first Play ever also shows `[ItemManager] <YourName> Apple: 3 (change 3)`. Data is kept between Plays only with **Enable Studio Access to API Services** ([player-data](player-data.md)).

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Item.Give` in `PlayerAdded` right away | `Data.WaitFor(player, 120)` first | Before the data loads, `Give` returns `false` and gives nothing. |
| `Data.Set(player, "Inventory", ...)` | `Item.Give` / `Item.Remove` | Only `Item` fires `OnItemChanged` (screen, Tools) and clamps bad counts. |
| `Instance.new("Tool")` or `:Clone()` put in the Backpack | `Tool.Create(...)`, then `tool.Parent = backpack` | Untracked Tools are flagged **hard** by the AntiCheat `Backpack` detector. |
| `Tool.Track(template)` on a template in ServerStorage | Clone first, then `Tool.Track(clone)` | Every clone copies the template's UID and is destroyed as a duplicate. |

## Change it

- To show another item: add its name to `SHOWN_ITEMS` in `ItemCounter`. To make another item a Tool: add it to `TOOL_ITEMS` in `ToolGiver`.
- To describe items in one place: pick `ItemDef` in the installer. It only describes items, never changes counts. In `ItemManager`, under `local Item = ...`, add:
  ```lua
  -- fragment
  if GaxiaServer.IsInstalled("ItemDef") then
  	GaxiaServer.ItemDef.RegisterMany({ Apple = { rarity = "common", sellPrice = 2 }, WoodenSword = { rarity = "rare" } })
  end
  ```
  Read a field with `GaxiaServer.ItemDef.GetField("Apple", "sellPrice", 0)`.
- For unique items with stats, use `Inventory` instead of `Item`. Its fields are capitalised (`Stackable`, `MaxStack`, `EquipSlot`), unlike ItemDef's. Call it after `Data.WaitFor` returned data: before that, `Add` returns `nil, "data not loaded"`, `Equip` returns `false, "data not loaded"` and reads are empty.
  `GaxiaServer.Inventory.DefineItem("Sword", { EquipSlot = "Weapon" })`, `local uid = GaxiaServer.Inventory.Add(player, "Sword", { Props = { damage = 12 } })`, `if uid then GaxiaServer.Inventory.Equip(player, uid) end`.
- To use your own sword model: put a Tool named `WoodenSword` (with a part named `Handle`) in **ServerStorage**. In `syncTools`, replace the lines from `local tool = Tool.Create(...)` to `handle.Parent = tool` with:
  ```lua
  -- fragment
  local tool = (game:GetService("ServerStorage"):WaitForChild(itemId) :: Tool):Clone()
  tool.CanBeDropped = false
  Tool.Track(tool) -- gives the clone its own UID, so the AntiCheat accepts it
  ```
- To trade: pick `Trade` (it brings `Economy`). This playbook has no trade script: tell the user it needs a server script and a trade window. The flow is `local tradeId = Trade.Request(a, b)`, then `Trade.AddItem(player, tradeId, "Apple", 2)` / `Trade.AddCurrency(player, tradeId, "Coins", 50)`, then `Trade.Confirm(player, tradeId)` by both. Rules:
  - `Trade` has no remotes and no invites, and `Request` does not ask `b`: let `b` accept first through a `Net` remote. A trade is cancelled by itself when either player leaves (`OnComplete` fires with `false`). Only the two players in a trade can `Trade.Cancel(player, tradeId)` it.
  - Check every client value (item name in an allow-list, whole count 1 to 1000). `AddItem` adds to the offer: check `Item.Has(player, item, alreadyOffered + count)`.
  - Any `AddItem`, `RemoveItem`, `AddCurrency` or `RemoveCurrency` un-confirms **both** players (`Trade.IsConfirmed` is `false` again), so nobody can change the offer after the other one confirmed. Both must `Confirm` again after a change: show "Confirm" again in the trade window on `OnUpdate`.
  - `OnComplete` fires after the trade is removed (`GetTrade` is `nil` there): remember both players in `OnUpdate` to tell them it ended.
- To sell items for Coins: [shop](shop.md).

## See also

- [API: Item](../api/Item.md) · [API: Tool](../api/Tool.md) · [API: Inventory](../api/Inventory.md) · [API: ItemDef](../api/ItemDef.md) · [API: Trade](../api/Trade.md) · [Player data](player-data.md) · [Shop](shop.md) · [Sword combat and enemy NPCs](combat-and-npcs.md) · [Signals and cleanup](signals-cleanup-and-timing.md) · [Anti-cheat and bans](anticheat-and-bans.md) · [Troubleshooting](../troubleshooting.md)
