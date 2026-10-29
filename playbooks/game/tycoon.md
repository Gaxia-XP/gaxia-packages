# Make a tycoon (plots, droppers, buy buttons, saved progress)

> Each player gets their own plot. Droppers make glowing parts that slide into a collector and turn into Cash. Buy buttons cost Cash and unlock the next item. Bought items are saved and rebuilt when the player comes back.

**Use this when** the user asks for: "tycoon", "tycoon game", "claim a plot", "one plot per player", "dropper", "collector", "conveyor that makes money", "buy buttons", "unlock the next button", "save what I bought in my tycoon" (ไทย: "เกมไทคูน", "ทำไทคูน", "จองพล็อต", "พื้นที่ของผู้เล่นแต่ละคน", "ดรอปเปอร์", "ที่เก็บเงิน", "ปุ่มซื้อ", "ซื้อแล้วปลดล็อกปุ่มถัดไป", "เซฟของที่ซื้อในไทคูน").
**Packages:** `Economy` (it also installs `Data`) and `Player`. `Net` and `Trove` are Core: always installed. The Script stops with a clear message if one is missing.
**You will create:** a ModuleScript `ServerStorage/GameModules/TycoonItems`, a Script `ServerScriptService/Tycoon` and a LocalScript `StarterPlayer/StarterPlayerScripts/TycoonShopUI`.

How it works (it runs in an empty Baseplate: the Script builds the plots by itself):

- **TycoonItems** lists what can be bought, in order. Each item has a price in `Cash` and the item it `needs` first.
- **Tycoon** (server) builds 4 plots. A player gets the first free plot when their data loads, and the plot is free again when they leave.
- A dropper makes a part every few seconds. The part slides to the plot's collector with a tween, and the collector gives its value as `Cash` (`GaxiaServer.Economy`).
- **TycoonShopUI** shows one button per item the player can buy now. A click only sends the item id. The server checks the plot, the order, the price and the Cash.
- Bought items are saved in the player's data as `TycoonOwned` (`GaxiaServer.Data`). On rejoin, the server builds them again on the new plot.

## Step 1 — List the items to buy

In **ServerStorage**, insert a **Folder** named **GameModules** (skip if it exists). In it, insert a **ModuleScript** named **TycoonItems** and paste:

```lua
-- ModuleScript: ServerStorage/GameModules/TycoonItems
-- Everything a player can buy on their plot, in shop order.
-- price: Cash (a whole number, 0 = free). needs: the id that must be bought first.
-- offset: where the item stands, measured from the middle of the plot floor.
export type TycoonItem = {
	id: string,
	name: string,
	price: number,
	needs: string?,
	offset: Vector3,
	size: Vector3,
	color: Color3,
	dropValue: number?, -- droppers only: Cash per drop
	dropEvery: number?, -- droppers only: seconds between drops
}

local TycoonItems = {}

TycoonItems.LIST = {
	{ id = "Dropper1", name = "Dropper 1", price = 0, offset = Vector3.new(-12, 6, 10), size = Vector3.new(3, 3, 3), color = Color3.fromRGB(90, 90, 100), dropValue = 2, dropEvery = 2 },
	{ id = "Dropper2", name = "Dropper 2", price = 25, needs = "Dropper1", offset = Vector3.new(-4, 6, 10), size = Vector3.new(3, 3, 3), color = Color3.fromRGB(90, 90, 100), dropValue = 3, dropEvery = 2 },
	{ id = "BackWall", name = "Back Wall", price = 60, needs = "Dropper2", offset = Vector3.new(0, 5, 19), size = Vector3.new(40, 8, 1), color = Color3.fromRGB(200, 180, 140) },
	{ id = "Dropper3", name = "Dropper 3", price = 120, needs = "BackWall", offset = Vector3.new(4, 6, 10), size = Vector3.new(3, 3, 3), color = Color3.fromRGB(60, 120, 200), dropValue = 6, dropEvery = 2 },
	{ id = "Dropper4", name = "Golden Dropper", price = 300, needs = "Dropper3", offset = Vector3.new(12, 6, 10), size = Vector3.new(3, 3, 3), color = Color3.fromRGB(230, 190, 40), dropValue = 15, dropEvery = 2 },
} :: { TycoonItem }

-- The same items by id, for quick lookups: TycoonItems.BY_ID.Dropper2
TycoonItems.BY_ID = {} :: { [string]: TycoonItem }
for _, item in TycoonItems.LIST do
	TycoonItems.BY_ID[item.id] = item
end

return TycoonItems
```

What it does: the server reads prices only from here. The client never sees this module (ServerStorage).

## Step 2 — Create the plots, droppers and buy logic on the server

Create a **Script** in **ServerScriptService** named **Tycoon**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/Tycoon
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Economy"), "Tycoon needs the Economy package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Player"), "Tycoon needs the Player package: install it (playbooks/start/01-install-packages.md)")

local TycoonItems = require(ServerStorage:WaitForChild("GameModules"):WaitForChild("TycoonItems"))
local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local PlayerService = GaxiaServer.Player -- the Gaxia "Player" package (Players above is Roblox's service)

local PLOT_COUNT = 4 -- set Max Players (Game Settings → Places) to this number
local CURRENCY = "Cash"
local DROP_SECONDS = 2 -- how long a drop takes to slide to the collector

-- Saved field: the ids the player bought, for example { Dropper1 = true, Dropper2 = true }.
Data.SetDefaults({ TycoonOwned = {} })

type Plot = { name: string, floor: Part, collector: Part, items: Folder, sign: TextLabel, owner: Player? }
local plots: { Plot } = {}
local plotOf: { [Player]: Plot } = {}
local troves: { [Player]: typeof(Gaxia.Trove.new()) } = {}

local function makePart(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Anchored = true
	part.Color = color
	part.Parent = parent
	return part
end

-- Build the plots in a row, 80 studs from the middle of the Baseplate.
local plotsFolder = Instance.new("Folder")
plotsFolder.Name = "TycoonPlots"
plotsFolder.Parent = Workspace
for index = 1, PLOT_COUNT do
	local model = Instance.new("Model")
	model.Name = `Plot{index}`
	model.Parent = plotsFolder
	local center = Vector3.new((index - (PLOT_COUNT + 1) / 2) * 70, 0.5, 80)
	local floor = makePart("Floor", Vector3.new(40, 1, 40), center, Color3.fromRGB(110, 160, 90), model)
	local collector = makePart("Collector", Vector3.new(6, 2, 6), center + Vector3.new(0, 1.5, 0), Color3.fromRGB(40, 200, 90), model)
	local signPart = makePart("Sign", Vector3.new(8, 4, 1), center + Vector3.new(0, 2.5, -19), Color3.fromRGB(240, 240, 240), model)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front -- the side that faces the Baseplate middle
	gui.Parent = signPart
	local sign = Instance.new("TextLabel")
	sign.Size = UDim2.fromScale(1, 1)
	sign.TextScaled = true
	sign.Text = `Plot {index}: free`
	sign.Parent = gui
	local items = Instance.new("Folder")
	items.Name = "Items"
	items.Parent = model
	table.insert(plots, { name = model.Name, floor = floor, collector = collector, items = items, sign = sign, owner = nil })
end

local function getOwned(player: Player): { [string]: boolean }
	local owned = Data.Get(player, "TycoonOwned")
	return if typeof(owned) == "table" then owned else {}
end

-- One drop: a small part that slides from the dropper to the collector, then becomes Cash.
local function spawnDrop(plot: Plot, player: Player, from: Vector3, value: number)
	local drop = makePart("Drop", Vector3.new(1, 1, 1), from, Color3.fromRGB(255, 220, 80), plot.items)
	drop.CanCollide = false
	drop.Material = Enum.Material.Neon
	local target = plot.collector.Position + Vector3.new(0, plot.collector.Size.Y / 2 + 0.5, 0)
	local tween = TweenService:Create(drop, TweenInfo.new(DROP_SECONDS, Enum.EasingStyle.Linear), { Position = target })
	tween.Completed:Connect(function()
		-- The collector: pay only if the drop still exists and the plot still belongs to this player.
		if drop.Parent ~= nil and plot.owner == player then
			Economy.Add(player, CURRENCY, value)
		end
		drop:Destroy()
	end)
	tween:Play()
end

-- Put one bought item on the plot. A dropper also starts its drop loop.
local function buildItem(plot: Plot, player: Player, item: TycoonItems.TycoonItem)
	local part = makePart(item.id, item.size, plot.floor.Position + item.offset, item.color, plot.items)
	local dropValue, dropEvery = item.dropValue, item.dropEvery
	if dropValue and dropEvery then
		task.spawn(function()
			-- Stops by itself when the part is destroyed (the player left).
			while true do
				task.wait(dropEvery)
				if part.Parent == nil then
					break
				end
				spawnDrop(plot, player, part.Position - Vector3.new(0, item.size.Y / 2 + 0.5, 0), dropValue)
			end
		end)
	end
end

local function spawnCFrame(plot: Plot): CFrame
	local position = plot.floor.Position + Vector3.new(0, 4, -14)
	return CFrame.lookAt(position, plot.floor.Position + Vector3.new(0, 4, 0))
end

-- Gives the player a plot once their data is loaded. Safe to call many times. nil = no free plot (or they left).
local function ensurePlot(player: Player): Plot?
	if Data.WaitFor(player, 60) == nil or player.Parent == nil then
		return nil
	end
	local existing = plotOf[player]
	if existing then
		return existing
	end
	local plot: Plot? = nil
	for _, candidate in plots do
		if candidate.owner == nil then
			plot = candidate
			break
		end
	end
	if plot == nil then
		warn(`[Tycoon] no free plot for {player.Name}: raise PLOT_COUNT or lower Max Players`)
		return nil
	end
	plot.owner = player
	plotOf[player] = plot
	plot.sign.Text = `{plot.name}: {player.DisplayName}`
	-- Rebuild everything the player bought before, in shop order.
	local owned = getOwned(player)
	local rebuilt = 0
	for _, item in TycoonItems.LIST do
		if owned[item.id] then
			buildItem(plot, player, item)
			rebuilt += 1
		end
	end
	-- Send the player to their plot now and after every respawn.
	local trove = Gaxia.Trove.new()
	troves[player] = trove
	local function sendHome(character: Model)
		character:WaitForChild("HumanoidRootPart", 5)
		task.wait(0.2) -- let Roblox finish placing the new character first
		if plotOf[player] == plot then
			PlayerService.Teleport(player, spawnCFrame(plot))
		end
	end
	trove:Connect(player.CharacterAdded, sendHome)
	if player.Character then
		task.spawn(sendHome, player.Character)
	end
	print(`[Tycoon] {player.Name} claimed {plot.name} ({rebuilt} items rebuilt)`)
	return plot
end

local function releasePlot(player: Player)
	local trove = troves[player]
	if trove then
		trove:Destroy()
		troves[player] = nil
	end
	local plot = plotOf[player]
	if plot == nil then
		return
	end
	plotOf[player] = nil
	plot.owner = nil
	plot.items:ClearAllChildren() -- removes the items and the drops; the drop loops stop
	plot.sign.Text = `{plot.name}: free`
	print(`[Tycoon] {player.Name} left, {plot.name} is free`)
end

-- What the player can buy right now: not owned yet, and the needed item is owned.
type ShopEntry = { id: string, name: string, price: number }
local function shopFor(player: Player): { ShopEntry }
	local owned = getOwned(player)
	local list: { ShopEntry } = {}
	for _, item in TycoonItems.LIST do
		if not owned[item.id] and (item.needs == nil or owned[item.needs]) then
			table.insert(list, { id = item.id, name = item.name, price = item.price })
		end
	end
	return list
end

local function buy(player: Player, itemId: any): (boolean, string)
	local item = if typeof(itemId) == "string" then TycoonItems.BY_ID[itemId] else nil
	if item == nil then
		return false, "That item does not exist"
	end
	local plot = plotOf[player]
	if plot == nil or not Data.IsLoaded(player) then
		return false, "Your plot is still loading"
	end
	local owned = getOwned(player)
	if owned[item.id] then
		return false, "You already own it"
	end
	local needs = item.needs
	if needs and not owned[needs] then
		return false, `Buy {TycoonItems.BY_ID[needs].name} first`
	end
	if item.price > 0 and not Economy.Spend(player, CURRENCY, item.price) then
		return false, `Not enough {CURRENCY}: it costs {item.price}`
	end
	local newOwned = table.clone(owned)
	newOwned[item.id] = true
	if not Data.Set(player, "TycoonOwned", newOwned) then
		if item.price > 0 then
			Economy.Add(player, CURRENCY, item.price) -- could not save: give the Cash back
		end
		return false, "Could not save, try again"
	end
	buildItem(plot, player, item)
	print(`[Tycoon] {player.Name} bought {item.id} for {item.price} {CURRENCY}`)
	return true, `Bought {item.name}!`
end

-- The client asks for its plot and buy list. It waits until the data is loaded.
Net.OnInvoke("TycoonGetShop", function(player: Player): (string, { ShopEntry })
	if ensurePlot(player) == nil then
		return "No free plot. Try another server.", {}
	end
	local list = shopFor(player)
	return if #list > 0 then "Your tycoon" else "You bought everything!", list
end)

-- The client asks to buy one item by id. The rate limit stops spam clicks.
Net.OnInvoke("TycoonBuy", function(player: Player, itemId: any): (boolean, string, { ShopEntry })
	local ok, message = buy(player, itemId)
	return ok, message, shopFor(player)
end, { rate = 4, burst = 8 })

-- Cash on the leaderboard: set it up on load, then copy every change.
Economy.OnTransaction:Connect(function(player: Player, currency: string, _delta: number, newBalance: number)
	if currency == CURRENCY then
		PlayerService.SetLeaderstat(player, CURRENCY, newBalance)
	end
end)

local function onPlayerAdded(player: Player)
	if ensurePlot(player) ~= nil then
		PlayerService.SetupLeaderstats(player, { [CURRENCY] = Economy.Get(player, CURRENCY) })
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(releasePlot)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[Tycoon] ready")
```

What it does: it builds 4 plots, gives each joining player one, and rebuilds what they own. Drops turn into Cash. `TycoonBuy` checks everything on the server.
Drops slide with a tween, not physics: they never fall off or get stuck, and players cannot push them.

## Step 3 — Show the buy buttons on the client

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **TycoonShopUI**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/TycoonShopUI
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

local Net = Gaxia.Net
local player = Players.LocalPlayer
local busy = false -- true while waiting for the server's answer
local buttons: { TextButton } = {}

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TycoonShopGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(260, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y -- grows with the number of buttons
frame.Position = UDim2.new(0, 20, 0.3, 0)
frame.Parent = screenGui

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = frame

local status = Instance.new("TextLabel") -- the server's last answer
status.Size = UDim2.new(1, 0, 0, 40)
status.TextScaled = true
status.Text = "Loading your plot..."
status.LayoutOrder = 0
status.Parent = frame

local showShop: (list: any) -> ()

local function onBuyClicked(itemId: string)
	if busy then
		return -- wait for the answer before asking again
	end
	busy = true
	-- Send only WHICH item. The server knows the price. pcall: the button keeps working if the call errors.
	local called, ok, message, list = pcall(Net.InvokeServer, "TycoonBuy", itemId)
	if not called or ok == nil then
		ok, message = false, "No answer, try again" -- the call failed, or the server dropped it (too many requests)
	end
	print(`[TycoonShopUI] buy {itemId}: {tostring(ok)} {tostring(message)}`)
	status.Text = tostring(message)
	if typeof(list) == "table" then
		showShop(list)
	end
	busy = false
end

-- One button per item the server says we can buy now.
showShop = function(list: any)
	for _, old in buttons do
		old:Destroy()
	end
	table.clear(buttons)
	for index, entry in list do
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, 0, 0, 50)
		button.TextScaled = true
		button.LayoutOrder = index
		button.Text = if entry.price > 0 then `{entry.name} - {entry.price} Cash` else `{entry.name} - Free`
		button.Parent = frame
		button.Activated:Connect(function()
			onBuyClicked(entry.id)
		end)
		table.insert(buttons, button)
	end
end

local called, title, list = pcall(Net.InvokeServer, "TycoonGetShop")
if called and typeof(list) == "table" then
	status.Text = tostring(title)
	showShop(list)
else
	status.Text = "Could not load the shop. Rejoin."
end

print("[TycoonShopUI] ready")
```

What it does: it asks the server for the buy list once, then shows the new list after every click.

## Check that it works

1. Press **Play** in Studio. Output shows `[Tycoon] ready`, `[TycoonShopUI] ready`, and no red errors.
2. Within a few seconds Output shows `[Tycoon] <YourName> claimed Plot1 (0 items rebuilt)`. You stand on a green plot. Its white sign says `Plot1: <YourName>`.
3. The left of the screen shows one button: **Dropper 1 - Free**. Click it. Output shows `[Tycoon] <YourName> bought Dropper1 for 0 Cash`. A grey box appears, and yellow drops slide into the green collector.
4. The player list (top right) has a **Cash** column. It goes up by 2 every 2 seconds.
5. The button now says **Dropper 2 - 25 Cash**. Click it before you have 25 Cash: the screen says `Not enough Cash: it costs 25`. Click it again with 25 Cash or more: it is bought and **Back Wall - 60 Cash** appears.
6. Stop, then press **Play** again. With **Enable Studio Access to API Services** on ([player-data](player-data.md)), Output shows `[Tycoon] <YourName> claimed Plot1 (2 items rebuilt)` and both droppers are back. Without it, data resets on every Play.
7. (Two players) In the **Test** tab, set **Clients and Servers** to 2 players and click **Start**. Each player gets a different plot. Close one player window: Output shows `[Tycoon] Player1 left, Plot1 is free` and its items disappear.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Client sends `"TycoonBuy", "Dropper2", 25` (a price) | Client sends only the item id | The server reads the price from TycoonItems. A cheater can send any price. |
| Checking the order only on the client (which buttons it shows) | The server checks `needs` in `buy` | A cheater can call `TycoonBuy` with any id. The server answers `Buy Dropper 2 first`. |
| `drop.Touched:Connect(...)` on the collector to pay | The tween's `Completed` pays (Step 2) | Touched fires many times per drop, and physics drops fall off or get stuck. |
| `player.leaderstats.Cash.Value += 2` | `Economy.Add(player, "Cash", 2)` | The saved balance does not change, and AntiCheat flags `StatTamper`. |
| Saving the item Parts or a `Vector3` | Save ids: `{ Dropper1 = true }` | DataStores save only numbers, strings, booleans and tables. Rebuild the parts from TycoonItems. |
| `Data.Get(player, "TycoonOwned")` in `PlayerAdded` right away | `ensurePlot` calls `Data.WaitFor` first | Data loads after the player joins. Before that `Get` returns `nil`. |
| `character.HumanoidRootPart.CFrame = ...` to send a player home | `PlayerService.Teleport(player, cframe)` | A big jump without it is a `Teleport` cheat flag. |
| More players than plots | Set **Max Players** to `PLOT_COUNT` (Game Settings → Places) | A player with no plot gets `No free plot` and Output warns `[Tycoon] no free plot`. |
| A price like `12.5` or `-10` | Whole numbers from 0 | `Economy.Spend` refuses other amounts: the buy fails with `Not enough Cash`. |

## Change it

- To add an item: add one line to `TycoonItems.LIST` with a new `id` and `needs` set to the item before it. Saved items keep working: ids are saved, not positions.
- To make two items unlock after the same one: give both the same `needs`. Both buttons appear together.
- To make drops worth more: change `dropValue`. To make them faster: lower `dropEvery` (seconds).
- To give new players starting Cash: in `onPlayerAdded`, after `SetupLeaderstats`, add `if Economy.Get(player, CURRENCY) == 0 and next(getOwned(player)) == nil then Economy.Add(player, CURRENCY, 50) end`.
- To show the Cash on screen as a big number: [show-values-on-screen](show-values-on-screen.md).

## See also

- [API: Economy](../api/Economy.md) · [API: Data](../api/Data.md) · [API: Player](../api/Player.md) · [API: Trove](../api/Core.Trove.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Player data](player-data.md) · [Shop](shop.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Troubleshooting](../troubleshooting.md)
