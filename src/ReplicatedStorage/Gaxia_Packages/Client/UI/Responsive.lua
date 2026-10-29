--!strict
-- ─────────────────────────────────────────────────────────────
-- Responsive.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/Responsive
-- Purpose : Make UI fit phones / tablets / console / desktop. Templates size in
--           raw pixels (UDim2.fromOffset) with no scaling — modals overflow
--           phones and shrink on a TV, and most Roblox sessions are mobile.
--           Apply() drops a viewport-fitted UIScale onto a ScreenGui and keeps
--           it updated until that UI is destroyed; on touch screens the scale
--           never drops below MIN_TOUCH_SCALE so buttons stay tappable.
--           GetDeviceClass()/SafeArea() drive layout decisions.
--
-- Access  : Gaxia.UI.Responsive  (client)
--   Gaxia.UI.Responsive.Apply(screenGui)
--   if Gaxia.UI.Responsive.GetDeviceClass() == "Phone" then ... end
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")

-- Device class; "Server" only from the server stub of GetDeviceClass.
export type DeviceClass = "Phone" | "Tablet" | "Desktop" | "Console" | "Server"
-- Safe-area insets in pixels (topbar / notch), from GuiService:GetGuiInset().
export type SafeAreaInsets = { top: number, bottom: number, left: number, right: number }

local REF_RESOLUTION : Vector2 = Vector2.new(1280, 720)
local MIN_SCALE : number = 0.5
-- Touch screens: below this, 40-44 px buttons get too small to tap.
local MIN_TOUCH_SCALE : number = 0.75
local MAX_SCALE : number = 1.6

local Responsive = {}

-- ── Pure helpers (available on every context, so they're unit-testable) ──

-- Uniform scale that fits `viewport` to the reference resolution (1280x720), clamped to 0.5-1.6. Pass `touch = true` for a touch screen: the scale is then at least 0.75 so buttons stay big enough to tap.
function Responsive.ComputeScale(viewport: Vector2, ref: Vector2?, touch: boolean?): number
	local r = ref or REF_RESOLUTION
	if viewport.X <= 0 or viewport.Y <= 0 then
		return 1
	end
	local s = math.min(viewport.X / r.X, viewport.Y / r.Y)
	return math.clamp(s, if touch then MIN_TOUCH_SCALE else MIN_SCALE, MAX_SCALE)
end

-- Classify a device from viewport width + input capabilities.
function Responsive.ClassifyDevice(viewportX: number, touch: boolean, tenFoot: boolean): DeviceClass
	if tenFoot then
		return "Console"
	end
	if touch then
		return if viewportX <= 800 then "Phone" else "Tablet"
	end
	return "Desktop"
end

-- ── Server stub (the viewport-bound methods are meaningless off the client) ──
if not RunService:IsClient() then
	Responsive.GetViewport = function(): Vector2 return Vector2.zero end
	Responsive.GetDeviceClass = function(): DeviceClass return "Server" end
	Responsive.GetScale = function(): number return 1 end
	-- Returns nil on the server (typed as the client signature for autocomplete).
	Responsive.Apply = function(_: Instance): UIScale return nil :: any end
	Responsive.OnChanged = function(_: () -> ()): RBXScriptConnection? return nil end
	Responsive.SafeArea = function(): SafeAreaInsets return { top = 0, bottom = 0, left = 0, right = 0 } end
	return Responsive
end

-- ── Client implementation ──
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local Trove = require(script.Parent.Parent.Parent.Shared.Trove)
-- The value Trove.new() returns (see TooltipSystem for why not Trove.Trove).
type TroveObject = typeof(Trove.new())

function Responsive.GetViewport(): Vector2
	local cam = Workspace.CurrentCamera
	return (cam and cam.ViewportSize) or REF_RESOLUTION
end

function Responsive.GetDeviceClass(): DeviceClass
	return Responsive.ClassifyDevice(Responsive.GetViewport().X, UserInputService.TouchEnabled, GuiService:IsTenFootInterface())
end

-- The scale for this device right now: ComputeScale of the current viewport, with the touch minimum (0.75) on touch screens.
function Responsive.GetScale(): number
	return Responsive.ComputeScale(Responsive.GetViewport(), nil, UserInputService.TouchEnabled)
end

-- Live Apply listeners, one Trove per UIScale (weak: a destroyed UIScale is not kept alive).
local applied: { [UIScale]: TroveObject } = setmetatable({}, { __mode = "k" }) :: any

-- Attach (or reuse) a UIScale on `gui` fitted to the viewport (GetScale), auto-updating while the viewport or camera changes. The listeners are disconnected when `gui` or the UIScale is destroyed, so it is safe on UI that closes (Router screens). Calling it again on the same gui replaces the old listeners.
function Responsive.Apply(gui: Instance): UIScale
	local scale = gui:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	local old = applied[scale]
	if old then
		old:Destroy()
	end
	local trove = Trove.new()
	applied[scale] = trove

	local function update()
		scale.Scale = Responsive.GetScale()
	end
	-- Follows the current camera: a new CurrentCamera gets the listener instead.
	local camTrove = trove:Extend()
	local function bindCamera()
		camTrove:Clean()
		local cam = Workspace.CurrentCamera
		if cam then
			camTrove:Connect(cam:GetPropertyChangedSignal("ViewportSize"), update)
		end
		update()
	end
	bindCamera()
	trove:Connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), bindCamera)
	local function release()
		trove:Destroy()
		if applied[scale] == trove then
			applied[scale] = nil
		end
	end
	trove:Connect(gui.Destroying, release)
	trove:Connect(scale.Destroying, release)
	scale.Parent = gui
	return scale
end

function Responsive.OnChanged(fn: () -> ()): RBXScriptConnection?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	return cam:GetPropertyChangedSignal("ViewportSize"):Connect(fn)
end

-- Safe-area insets (top/bottom/left/right) from the topbar / notch via GuiInset.
function Responsive.SafeArea(): SafeAreaInsets
	local a, b = GuiService:GetGuiInset()
	return { top = a.Y, bottom = b.Y, left = a.X, right = b.X }
end

return Responsive
