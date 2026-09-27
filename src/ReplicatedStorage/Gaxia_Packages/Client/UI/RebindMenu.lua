--!strict
-- ─────────────────────────────────────────────────────────────
-- RebindMenu.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/RebindMenu
-- Purpose : The settings-menu side of input rebinding. InputManager already
--           does Bind/Rebind/IsHeld over ContextActionService, but there was no
--           way to (a) capture "press any key" from the player and (b) render
--           the action↔key list with a live re-bind button. CaptureNext() grabs
--           the next key/mouse/gamepad press (Esc cancels); Build() renders one
--           themed row per bound action and re-binds through InputManager on
--           capture, calling OnRebind so the game can persist it.
--
-- Access  : Gaxia.UI.RebindMenu  (client)
--   local menu = Gaxia.UI.RebindMenu.Build({ Parent = gui,
--       OnRebind = function(action, key) saveKeybind(action, key) end })
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")

export type RebindHandle = { Instance: GuiObject, Refresh: () -> () }
-- A bindable input (same shape as InputManager.InputKey).
export type RebindKey = Enum.KeyCode | Enum.UserInputType

local RebindMenu = {}

local MOUSE_NAMES: { [string]: string } = {
	MouseButton1 = "Mouse1",
	MouseButton2 = "Mouse2",
	MouseButton3 = "Mouse3",
}

-- PURE: friendly display name for a bound key (KeyCode or UserInputType).
function RebindMenu.KeyName(key: (RebindKey | EnumItem)?): string
	if typeof(key) == "EnumItem" then
		return MOUSE_NAMES[key.Name] or key.Name
	end
	return "—"
end

-- ── Server stub (typed as the client module so Gaxia.UI.RebindMenu autocompletes) ──
if not RunService:IsClient() then
	return ({
		KeyName = RebindMenu.KeyName,
		CaptureNext = function(): any return function() end end,
		Build = function(): any return nil end,
	} :: any) :: typeof(RebindMenu)
end

-- ── Client implementation ──
local UserInputService = game:GetService("UserInputService")
local Components = require(script.Parent.Components)
local InputManager = require(script.Parent.Parent.InputManager)
local Theme = require(script.Parent.Parent.Parent.Shared.Theme)

local CAPTURE_MOUSE: { [Enum.UserInputType]: boolean } = {
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.UserInputType.MouseButton2] = true,
	[Enum.UserInputType.MouseButton3] = true,
}

-- Listen for the next key / mouse / gamepad-button press; Esc cancels.
-- Returns a cancel function. onCaptured(key, cancelled) fires exactly once;
-- key is nil when cancelled.
function RebindMenu.CaptureNext(onCaptured: (key: RebindKey?, cancelled: boolean) -> ()): () -> ()
	local conn: RBXScriptConnection? = nil
	local function stop(): ()
		if conn then
			conn:Disconnect()
			conn = nil
		end
	end
	conn = UserInputService.InputBegan:Connect(function(input: InputObject, _processed: boolean)
		local t = input.UserInputType
		if t == Enum.UserInputType.Keyboard then
			if input.KeyCode == Enum.KeyCode.Escape then
				stop()
				onCaptured(nil, true)
			else
				stop()
				onCaptured(input.KeyCode, false)
			end
		elseif CAPTURE_MOUSE[t] then
			stop()
			onCaptured(t, false)
		elseif string.find(t.Name, "Gamepad") ~= nil then
			if input.KeyCode.Name ~= "Unknown" then -- Enum.KeyCode.Unknown (absent from the type definitions)
				stop()
				onCaptured(input.KeyCode, false)
			end
		end
	end)
	return stop
end

export type BuildOpts = {
	Actions: { string }?, -- restrict/order; default = all bound actions, sorted
	Parent: Instance?, Size: UDim2?, Position: UDim2?,
	OnRebind: ((action: string, key: RebindKey) -> ())?,
}

function RebindMenu.Build(opts: BuildOpts?): RebindHandle
	local o: BuildOpts = opts or {}

	local root = Instance.new("Frame")
	root.Name = "GaxRebindMenu"
	root.Size = o.Size or UDim2.fromOffset(340, 280)
	root.Position = o.Position or UDim2.new()
	root.BackgroundColor3 = Theme.Color("Background")
	local cr = Instance.new("UICorner")
	cr.CornerRadius = UDim.new(0, Theme.Radius("L"))
	cr.Parent = root
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, Theme.Spacing("S"))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = root
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, Theme.Spacing("M"))
	p.PaddingLeft = UDim.new(0, Theme.Spacing("M"))
	p.PaddingRight = UDim.new(0, Theme.Spacing("M"))
	p.Parent = root

	local rowButtons: { [string]: TextButton } = {}
	local cancelCapture: (() -> ())? = nil

	local function currentKey(action: string): RebindKey?
		local keys = InputManager.GetBindings()[action]
		return keys and keys[1]
	end
	local function setLabel(action: string): ()
		local btn = rowButtons[action]
		if btn then
			btn.Text = RebindMenu.KeyName(currentKey(action))
		end
	end

	local handle = {} :: RebindHandle
	handle.Instance = root
	handle.Refresh = function(): ()
		for action in pairs(rowButtons) do
			setLabel(action)
		end
	end

	-- Default: every bound action, sorted.
	local function allActions(): { string }
		local all: { string } = {}
		for a in pairs(InputManager.GetBindings()) do
			table.insert(all, a)
		end
		table.sort(all)
		return all
	end
	local actions: { string } = o.Actions or allActions()

	for i, action in ipairs(actions) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 36)
		row.BackgroundTransparency = 1
		row.LayoutOrder = i
		row.Parent = root

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0.5, -6, 1, 0)
		label.BackgroundTransparency = 1
		label.Text = action
		label.Font = Theme.Get().Font.Medium
		label.TextSize = 16
		label.TextColor3 = Theme.Color("Text")
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = row

		local btn = Components.Button({
			Text = RebindMenu.KeyName(currentKey(action)),
			Size = UDim2.new(0.5, 0, 1, 0),
			Position = UDim2.new(0.5, 0, 0, 0),
			Variant = "surface",
			Parent = row,
		})
		rowButtons[action] = btn

		btn.Activated:Connect(function()
			if cancelCapture then
				cancelCapture()
			end
			btn.Text = "Press a key…"
			cancelCapture = RebindMenu.CaptureNext(function(key: RebindKey?, cancelled: boolean)
				cancelCapture = nil
				if not cancelled and key ~= nil then
					InputManager.Rebind(action, { key })
					if o.OnRebind then
						o.OnRebind(action, key)
					end
				end
				setLabel(action)
			end)
		end)
	end

	root.Parent = o.Parent
	return handle
end

return RebindMenu
