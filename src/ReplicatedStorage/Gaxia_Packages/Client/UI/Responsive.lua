--!strict
-- ─────────────────────────────────────────────────────────────
-- Responsive.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/Responsive
-- Purpose : Make UI fit phones / tablets / console / desktop. Templates size in
--           raw pixels (UDim2.fromOffset) with no scaling — modals overflow
--           phones and shrink on a TV, and most Roblox sessions are mobile.
--           Apply() drops a viewport-fitted UIScale onto a ScreenGui and keeps
--           it updated; GetDeviceClass()/SafeArea() drive layout decisions.
--
-- Access  : Gaxia.UI.Responsive  (client)
--   Gaxia.UI.Responsive.Apply(screenGui)
--   if Gaxia.UI.Responsive.GetDeviceClass() == "Phone" then ... end
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")

local REF_RESOLUTION : Vector2 = Vector2.new(1280, 720)
local MIN_SCALE : number = 0.5
local MAX_SCALE : number = 1.6

local Responsive = {}

-- ── Pure helpers (available on every context, so they're unit-testable) ──

-- Uniform scale that fits `viewport` to the reference resolution, clamped.
function Responsive.ComputeScale(viewport: Vector2, ref: Vector2?): number
	local r = ref or REF_RESOLUTION
	if viewport.X <= 0 or viewport.Y <= 0 then
		return 1
	end
	local s = math.min(viewport.X / r.X, viewport.Y / r.Y)
	return math.clamp(s, MIN_SCALE, MAX_SCALE)
end

-- Classify a device from viewport width + input capabilities.
function Responsive.ClassifyDevice(viewportX: number, touch: boolean, tenFoot: boolean): string
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
	Responsive.GetDeviceClass = function(): string return "Server" end
	Responsive.Apply = function(_: Instance): any return nil end
	Responsive.OnChanged = function(_: () -> ()): any return nil end
	Responsive.SafeArea = function() return { top = 0, bottom = 0, left = 0, right = 0 } end
	return Responsive
end

-- ── Client implementation ──
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

function Responsive.GetViewport(): Vector2
	local cam = Workspace.CurrentCamera
	return (cam and cam.ViewportSize) or REF_RESOLUTION
end

function Responsive.GetDeviceClass(): string
	return Responsive.ClassifyDevice(Responsive.GetViewport().X, UserInputService.TouchEnabled, GuiService:IsTenFootInterface())
end

-- Attach (or reuse) a UIScale on `gui` fitted to the viewport, auto-updating.
function Responsive.Apply(gui: Instance): UIScale
	local scale = gui:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	local function update()
		scale.Scale = Responsive.ComputeScale(Responsive.GetViewport())
	end
	update()
	scale.Parent = gui
	local cam = Workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(update)
	end
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
function Responsive.SafeArea(): { top: number, bottom: number, left: number, right: number }
	local a, b = GuiService:GetGuiInset()
	return { top = a.Y, bottom = b.Y, left = a.X, right = b.X }
end

return Responsive
