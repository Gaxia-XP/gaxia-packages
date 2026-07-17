--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   PetController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/PetController
-- Purpose:  Client UI for the stat-boost pet system (server: Gaxia.Pet).
--           Shows owned pets in a grid, lets the player buy an egg and
--           equip/unequip up to N pets, and displays the live Coins
--           multiplier. State is server-authoritative: every action fires a
--           remote and the panel rebuilds from the server's PetSync snapshot
--           (the client never decides ownership or the multiplier itself).
--           Toggle with the P key, or call PetController.Open() from game code.
-- ─────────────────────────────────────────────────────────────

local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")

export type PetController = {
	Open: () -> (),
	Close: () -> (),
	Toggle: () -> (),
}

-- Client-only module; return a typed stub on the server so the union collapses.
if not RunService:IsClient() then
	return ({
		Open = function() end,
		Close = function() end,
		Toggle = function() end,
	} :: any) :: PetController
end

local UIController = require(script.Parent:WaitForChild("UIController"))
local Toast        = require(script.Parent:WaitForChild("Toast"))
-- Net via the shared package (Gaxia_Packages/init), same as every server service
-- consumes it — survives a Shared/ folder move that a hand-counted path would not.
local SharedPkg    = require(script.Parent.Parent.Parent) :: any
local Net          = SharedPkg.Net

-- ── Constants ──
local TEMPLATE_NAME    : string = "MenuTemplate"
local TOGGLE_KEY       : Enum.KeyCode = Enum.KeyCode.P
local PLACEHOLDER_ICON : string = "rbxasset://textures/ui/GuiImagePlaceholder.png" -- provisional; swap real pet art server-side
local SLOT_SIZE        : UDim2 = UDim2.fromOffset(78, 92)
local EQUIPPED_COLOR   : Color3 = Color3.fromRGB(80, 200, 120)
local NEUTRAL_TEXT     : Color3 = Color3.fromRGB(235, 238, 245)
local MUTED_TEXT       : Color3 = Color3.fromRGB(190, 195, 205)

local RARITY_COLOR: { [string]: Color3 } = {
	common    = Color3.fromRGB(150, 155, 165),
	uncommon  = Color3.fromRGB(95, 195, 110),
	rare      = Color3.fromRGB(70, 140, 245),
	epic      = Color3.fromRGB(180, 110, 240),
	legendary = Color3.fromRGB(255, 200, 80),
}

-- ── State ──
local snapshot   : { [string]: any }? = nil
local panel      : Frame? = nil
local multLabel  : TextLabel? = nil
local equipLabel : TextLabel? = nil
local buyButton  : TextButton? = nil
local grid       : Frame? = nil

local PetController = {}

-- ── Helpers ──

local function rarityColor(rarity: string?): Color3
	return RARITY_COLOR[rarity or "common"] or RARITY_COLOR.common
end

local function equippedSet(): { [string]: boolean }
	local set: { [string]: boolean } = {}
	if snapshot then
		for _, uid in ipairs(snapshot.equipped) do
			set[uid] = true
		end
	end
	return set
end

-- ── One owned-pet slot (clickable: toggles equip/unequip) ──

local function buildSlot(inst: { [string]: any }, def: { [string]: any }?, isEquipped: boolean, parent: Instance): ()
	local displayName: string = (def and def.displayName) or inst.petId
	local rarity: string = (def and def.rarity) or "common"
	local iconId: string = (def and typeof(def.icon) == "string" and def.icon ~= "" and def.icon) or PLACEHOLDER_ICON

	local btn = Instance.new("ImageButton")
	btn.Name = inst.uid
	btn.Size = SLOT_SIZE
	btn.BackgroundColor3 = Color3.fromRGB(38, 42, 52)
	btn.AutoButtonColor = true
	btn.BorderSizePixel = 0
	btn.Selectable = false -- don't capture gamepad/keyboard nav focus, so the P toggle keeps working after a card click
	btn.Image = ""

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn

	-- Rarity (or equipped) border.
	local strokeColor = if isEquipped then EQUIPPED_COLOR else rarityColor(rarity)
	local stroke = Instance.new("UIStroke")
	stroke.Color = strokeColor
	stroke.Thickness = if isEquipped then 3 else 2
	stroke.Parent = btn

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Image = iconId
	icon.ScaleType = Enum.ScaleType.Fit
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.new(0.5, 0, 0, 6)
	icon.Size = UDim2.new(1, -16, 0, 48)
	icon.Parent = btn

	-- Name label (ALWAYS shown, so a slot is never blank even if the icon fails).
	local name = Instance.new("TextLabel")
	name.Name = "PetName"
	name.BackgroundTransparency = 1
	name.AnchorPoint = Vector2.new(0.5, 1)
	name.Position = UDim2.new(0.5, 0, 1, -16)
	name.Size = UDim2.new(1, -6, 0, 18)
	name.Text = displayName
	name.TextColor3 = NEUTRAL_TEXT
	name.Font = Enum.Font.GothamBold
	name.TextScaled = true
	name.Parent = btn

	-- Equip-state caption.
	local state = Instance.new("TextLabel")
	state.Name = "State"
	state.BackgroundTransparency = 1
	state.AnchorPoint = Vector2.new(0.5, 1)
	state.Position = UDim2.new(0.5, 0, 1, -2)
	state.Size = UDim2.new(1, -6, 0, 14)
	state.Text = if isEquipped then "✓ Equipped" else "Tap to equip"
	state.TextColor3 = if isEquipped then EQUIPPED_COLOR else MUTED_TEXT
	state.Font = Enum.Font.Gotham
	state.TextScaled = true
	state.Parent = btn

	btn.Activated:Connect(function()
		if isEquipped then
			Net.FireServer("PetUnequip", { uid = inst.uid })
		else
			Net.FireServer("PetEquip", { uid = inst.uid })
		end
	end)

	btn.Parent = parent
end

-- ── Rebuild the panel body from the latest snapshot ──

local function rebuild(): ()
	if not panel or not snapshot then
		return
	end

	local mult: number = tonumber(snapshot.multiplier) or 1
	if multLabel then
		multLabel.Text = `Coin Multiplier: x{string.format("%.2f", mult)}`
	end
	if equipLabel then
		equipLabel.Text = `Equipped {#snapshot.equipped}/{snapshot.slots or 0}`
	end
	if buyButton then
		buyButton.Text = `Buy Egg ({snapshot.eggCost or 0} Coins)`
	end

	if not grid then
		return
	end
	for _, child in ipairs(grid:GetChildren()) do
		if child:IsA("ImageButton") then
			child:Destroy()
		end
	end

	local equipped = equippedSet()
	local defs = snapshot.defs or {}

	-- Stable display order: sort owned pets by their index in snapshot.order
	-- (rarity ascending), tie-broken by uid — GetOwned returns hash-iteration
	-- order, so without this the grid reshuffles on every equip/unequip.
	local orderIdx: { [string]: number } = {}
	for i, id in ipairs(snapshot.order or {}) do
		orderIdx[id] = i
	end
	local owned = table.clone(snapshot.owned)
	table.sort(owned, function(a: any, b: any): boolean
		local ra = orderIdx[a.petId] or math.huge
		local rb = orderIdx[b.petId] or math.huge
		if ra ~= rb then
			return ra < rb
		end
		return tostring(a.uid) < tostring(b.uid)
	end)

	for _, inst in ipairs(owned) do
		if typeof(inst) == "table" then
			pcall(buildSlot, inst, defs[inst.petId], equipped[inst.uid] == true, grid)
		end
	end
end

-- ── Request fresh state (RemoteFunction) ──

local function requestState(): ()
	local ok, snap = pcall(function()
		return Net.InvokeServer("PetGetState")
	end)
	if ok and typeof(snap) == "table" then
		snapshot = snap
		rebuild()
	end
end

-- ── Open / Close / Toggle ──

function PetController.Close(): ()
	if panel then
		panel:Destroy()
	end
	panel, multLabel, equipLabel, buyButton, grid = nil, nil, nil, nil, nil
end

function PetController.Open(): ()
	if panel then
		PetController.Close()
	end

	local overlays = UIController.Overlays() or UIController.GetActiveScreen()
	local frame = UIController.CloneTemplate(TEMPLATE_NAME, overlays)
	if not frame or not frame:IsA("Frame") then
		warn("[PetController] failed to clone MenuTemplate")
		return
	end
	panel = frame

	-- Title.
	local title = frame:FindFirstChild("Title", true)
	if title and title:IsA("TextLabel") then
		title.Text = "Pets"
	end
	-- Close button.
	local closeBtn = frame:FindFirstChild("CloseButton", true)
	if closeBtn and closeBtn:IsA("GuiButton") then
		closeBtn.Activated:Connect(function()
			PetController.Close()
		end)
	end

	local content = frame:FindFirstChild("Content", true)
	if not content then
		content = frame
	end

	-- Stack: info bar → grid (vertical list).
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 8)
	list.Parent = content

	-- Info bar (multiplier + equipped count + buy button).
	local info = Instance.new("Frame")
	info.Name = "InfoBar"
	info.LayoutOrder = 1
	info.BackgroundTransparency = 1
	info.Size = UDim2.new(1, 0, 0, 64)
	info.Parent = content

	local ml = Instance.new("TextLabel")
	ml.Name = "Multiplier"
	ml.BackgroundTransparency = 1
	ml.Position = UDim2.fromOffset(0, 0)
	ml.Size = UDim2.new(1, 0, 0, 26)
	ml.Text = "Coin Multiplier: x1.00"
	ml.TextColor3 = RARITY_COLOR.legendary
	ml.Font = Enum.Font.GothamBold
	ml.TextSize = 20
	ml.TextXAlignment = Enum.TextXAlignment.Left
	ml.Parent = info
	multLabel = ml

	local el = Instance.new("TextLabel")
	el.Name = "EquipCount"
	el.BackgroundTransparency = 1
	el.Position = UDim2.fromOffset(0, 28)
	el.Size = UDim2.new(0.5, 0, 0, 20)
	el.Text = "Equipped 0/0"
	el.TextColor3 = MUTED_TEXT
	el.Font = Enum.Font.Gotham
	el.TextSize = 15
	el.TextXAlignment = Enum.TextXAlignment.Left
	el.Parent = info
	equipLabel = el

	local bb = Instance.new("TextButton")
	bb.Name = "BuyEgg"
	bb.AnchorPoint = Vector2.new(1, 0)
	bb.Position = UDim2.new(1, 0, 0, 18)
	bb.Size = UDim2.fromOffset(190, 38)
	bb.BackgroundColor3 = RARITY_COLOR.rare
	bb.BorderSizePixel = 0
	bb.Selectable = false
	bb.Text = "Buy Egg"
	bb.TextColor3 = NEUTRAL_TEXT
	bb.Font = Enum.Font.GothamBold
	bb.TextSize = 16
	local bbCorner = Instance.new("UICorner")
	bbCorner.CornerRadius = UDim.new(0, 8)
	bbCorner.Parent = bb
	bb.Parent = info
	buyButton = bb
	bb.Activated:Connect(function()
		Net.FireServer("PetBuyEgg", { egg = "BasicEgg" })
	end)

	-- Grid of owned pets.
	local g = Instance.new("Frame")
	g.Name = "PetGrid"
	g.LayoutOrder = 2
	g.BackgroundTransparency = 1
	g.AutomaticSize = Enum.AutomaticSize.Y
	g.Size = UDim2.new(1, 0, 0, 0)
	local gl = Instance.new("UIGridLayout")
	gl.CellPadding = UDim2.fromOffset(8, 8)
	gl.CellSize = SLOT_SIZE
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = g
	g.Parent = content
	grid = g

	-- Pull fresh state (also covers the case where no PetSync has fired yet).
	requestState()
end

function PetController.Toggle(): ()
	if panel then
		PetController.Close()
	else
		PetController.Open()
	end
end

-- ── Live updates from the server ──

pcall(function()
	Net.OnClient("PetSync", function(snap: any)
		if typeof(snap) == "table" then
			snapshot = snap
			rebuild()
		end
	end)
end)

pcall(function()
	Net.OnClient("PetHatch", function(res: any)
		if typeof(res) ~= "table" then
			return
		end
		if res.ok then
			local defs = (snapshot and snapshot.defs) or {}
			local def = defs[res.petId]
			local nm: string = (def and def.displayName) or res.petId or "a pet"
			Toast.Show({ Title = "Egg Hatched!", Text = `You got {nm}!`, Variant = "success" })
		else
			Toast.Show({ Title = "Hatch Failed", Text = tostring(res.reason or "try again"), Variant = "error" })
		end
	end)
end)

-- ── Keybind: P toggles the panel (ignored while typing in a TextBox) ──

UserInputService.InputBegan:Connect(function(input: InputObject)
	if input.KeyCode ~= TOGGLE_KEY then
		return
	end
	-- Gate only on a focused TextBox (chat), NOT gameProcessed — gameProcessed is
	-- true right after clicking the panel's own buttons and would swallow the next
	-- P press (the focus papercut the playtest surfaced).
	if UserInputService:GetFocusedTextBox() then
		return
	end
	PetController.Toggle()
end)

return PetController :: PetController
