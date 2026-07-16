--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   InventoryController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/InventoryController
-- Purpose:  Open a grid-based inventory UI from InventoryTemplate.
--           Populates Grid with one ImageButton slot per item.
-- ─────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- WHY this explicit type:
-- The early-return guard below needs to match the module's real return shape
-- so Luau collapses the (server-return | client-return) union into a single
-- typed value. Without this, `Gaxia.UI.InventoryController.<method>` does not
-- autocomplete because the union resolves to `any`.
export type InventoryItem = {
	name: string,
	icon: string,
	count: number?,
}
export type InventoryController = {
	Open: (items: { InventoryItem }) -> Frame?,
	Close: () -> (),
}

-- Client-only module.
if not RunService:IsClient() then
	return ({} :: any) :: InventoryController
end

local UIController = require(script.Parent:WaitForChild("UIController"))

-- ── Constants ──
local function getConstants(): { [string]: any }
	local pkg = ReplicatedStorage:FindFirstChild("Gaxia_Packages")
	if not pkg then return {} end
	local shared = pkg:FindFirstChild("Shared")
	if not shared then return {} end
	local constMod = shared:FindFirstChild("Constants")
	if not constMod or not constMod:IsA("ModuleScript") then return {} end
	local ok, data = pcall(require, constMod)
	if ok and typeof(data) == "table" then
		return data
	end
	return {}
end

local CONST = getConstants()
local ANIM_TIME: number = (CONST.UI_ANIMATION_TIME :: number?) or 0.25

local TEMPLATE_NAME: string = "InventoryTemplate"
local SLOT_BG_COLOR: Color3 = Color3.fromRGB(45, 50, 60)
local SLOT_CORNER: UDim = UDim.new(0, 6)
local SLOT_SIZE: UDim2 = UDim2.new(0, 64, 0, 64)   -- fallback if no UIGridLayout
local ICON_PADDING: number = 6
local BADGE_SIZE: UDim2 = UDim2.new(0, 22, 0, 18)

-- ── State ──
local activeInventory: Frame? = nil

local InventoryController = {}

-- ── Internal: build one slot ──
local function buildSlot(item: InventoryItem, parent: Instance): ImageButton
	local btn = Instance.new("ImageButton")
	btn.Name = item.name
	btn.Size = SLOT_SIZE
	btn.BackgroundColor3 = SLOT_BG_COLOR
	btn.BackgroundTransparency = 0
	btn.AutoButtonColor = true
	btn.BorderSizePixel = 0
	btn.Image = ""  -- icon lives in inner ImageLabel for layering with badge

	local corner = Instance.new("UICorner")
	corner.CornerRadius = SLOT_CORNER
	corner.Parent = btn

	-- Icon
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Image = item.icon
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, 0)
	icon.Size = UDim2.new(1, -ICON_PADDING * 2, 1, -ICON_PADDING * 2)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = btn

	-- Count badge (bottom-right) — only if count > 1
	local count = item.count or 1
	if count > 1 then
		local badge = Instance.new("TextLabel")
		badge.Name = "Count"
		badge.AnchorPoint = Vector2.new(1, 1)
		badge.Position = UDim2.new(1, -4, 1, -4)
		badge.Size = BADGE_SIZE
		badge.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
		badge.BorderSizePixel = 0
		badge.Text = tostring(count)
		badge.TextColor3 = Color3.fromRGB(240, 240, 240)
		badge.TextScaled = true
		badge.Font = Enum.Font.GothamBold
		local badgeCorner = Instance.new("UICorner")
		badgeCorner.CornerRadius = UDim.new(0, 4)
		badgeCorner.Parent = badge
		badge.Parent = btn
	end

	btn.Parent = parent
	return btn
end

-- ── Close ──
function InventoryController.Close(): ()
	local frame = activeInventory
	if not frame then
		return
	end
	activeInventory = nil

	if not frame.Parent then
		return
	end

	pcall(function()
		local tween = TweenService:Create(
			frame,
			TweenInfo.new(ANIM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		tween:Play()
		tween.Completed:Wait()
		frame:Destroy()
	end)
end

-- ── Open ──
function InventoryController.Open(items: { InventoryItem }): Frame?
	-- WHY: only one inventory open at a time — close existing first.
	if activeInventory then
		InventoryController.Close()
	end

	local overlays = UIController.Overlays() or UIController.GetActiveScreen()
	local frame = UIController.CloneTemplate(TEMPLATE_NAME, overlays)
	if not frame or not frame:IsA("Frame") then
		warn("[InventoryController] failed to clone InventoryTemplate")
		return nil
	end

	-- Wire close button if present.
	pcall(function()
		local closeBtn = frame:FindFirstChild("CloseButton", true)
		if closeBtn and closeBtn:IsA("GuiButton") then
			closeBtn.Activated:Connect(function()
				InventoryController.Close()
			end)
		end
	end)

	-- Locate Grid container; fall back to the frame itself if absent.
	local grid: Instance = frame
	pcall(function()
		local found = frame:FindFirstChild("Grid", true)
		if found then
			grid = found
		end
	end)

	-- Clear any prior slots that might live in the template.
	for _, child in ipairs(grid:GetChildren()) do
		if child:IsA("ImageButton") or child:IsA("Frame") then
			-- Preserve layout helpers (UIGridLayout, UIPadding).
			child:Destroy()
		end
	end

	-- Build slots.
	for _, item in ipairs(items) do
		pcall(buildSlot, item, grid)
	end

	activeInventory = frame
	return frame
end

return InventoryController :: InventoryController
