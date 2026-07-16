--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   HUDController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/HUDController
-- Purpose:  Persistent HUD text labels (timers, score, etc.)
--           Polls a getValue closure on a fixed interval.
-- ─────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- WHY this explicit type:
-- The early-return guard below needs to match the module's real return shape
-- so Luau collapses the (server-return | client-return) union into a single
-- typed value. Without this, `Gaxia.UI.HUDController.<method>` does not
-- autocomplete because the union resolves to `any`.
export type HUDController = {
	AddText: (name: string, getValue: () -> string, position: UDim2) -> TextLabel?,
	Remove: (name: string) -> (),
	SetVisible: (visible: boolean) -> (),
}

-- Client-only module.
if not RunService:IsClient() then
	return ({} :: any) :: HUDController
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

local _CONST = getConstants()

local DEFAULT_SIZE: UDim2 = UDim2.new(0, 200, 0, 36)
local DEFAULT_TEXT_COLOR: Color3 = Color3.fromRGB(240, 240, 240)
local DEFAULT_STROKE_COLOR: Color3 = Color3.fromRGB(0, 0, 0)
local UPDATE_INTERVAL: number = 0.2  -- WHY: 0.2s is plenty for HUD text, cheaper than Heartbeat.

-- ── State ──
type HudEntry = {
	label: TextLabel,
	getValue: () -> string,
	thread: thread,
	alive: boolean,
}
local entries: { [string]: HudEntry } = {}

local HUDController = {}

-- ── AddText ──
function HUDController.AddText(
	name: string,
	getValue: () -> string,
	position: UDim2
): TextLabel?
	-- Replace if name already exists.
	if entries[name] then
		HUDController.Remove(name)
	end

	local hud = UIController.HUD() or UIController.GetActiveScreen()
	if not hud then
		warn(`[HUDController] no HUD parent for '{name}'`)
		return nil
	end

	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = DEFAULT_SIZE
	label.Position = position
	label.BackgroundTransparency = 1
	label.TextColor3 = DEFAULT_TEXT_COLOR
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""

	-- Crisp outline so text reads over any background.
	local stroke = Instance.new("UIStroke")
	stroke.Color = DEFAULT_STROKE_COLOR
	stroke.Thickness = 1.5
	stroke.Parent = label

	label.Parent = hud

	local entry: HudEntry = {
		label = label,
		getValue = getValue,
		thread = (nil :: any) :: thread,
		alive = true,
	}

	-- Polling loop — task.wait avoids per-frame cost of Heartbeat.
	entry.thread = task.spawn(function()
		while entry.alive and label.Parent do
			local ok, value = pcall(getValue)
			if ok and typeof(value) == "string" then
				label.Text = value
			end
			task.wait(UPDATE_INTERVAL)
		end
	end)

	entries[name] = entry
	return label
end

-- ── Remove ──
function HUDController.Remove(name: string): ()
	local entry = entries[name]
	if not entry then
		return
	end
	entry.alive = false
	entries[name] = nil
	if entry.label and entry.label.Parent then
		entry.label:Destroy()
	end
end

-- ── SetVisible ──
function HUDController.SetVisible(visible: boolean): ()
	local hud = UIController.HUD()
	if not hud then
		return
	end
	-- Folders have no Visible; toggle each child GuiObject instead.
	for _, child in ipairs(hud:GetChildren()) do
		if child:IsA("GuiObject") then
			child.Visible = visible
		end
	end
end

return HUDController :: HUDController
