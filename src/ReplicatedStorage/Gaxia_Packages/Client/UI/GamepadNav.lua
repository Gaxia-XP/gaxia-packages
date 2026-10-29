--!strict
-- ─────────────────────────────────────────────────────────────
-- GamepadNav.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/GamepadNav
-- Purpose : Make a screen navigable by gamepad/console without hand-wiring
--           every NextSelectionUp/Down/Left/Right link. Roblox's built-in GUI
--           navigation needs each GuiObject's four NextSelection* properties
--           set manually — tedious and wrong after any layout tweak. AutoLink()
--           reads the elements' on-screen centers and wires the nearest
--           neighbour in each direction (off-axis penalized). SolveLinks() is a
--           pure geometry function (headless-testable). Focus()/IsGamepadActive
--           drive the selection + focus-highlight gating.
--
-- Access  : Gaxia.UI.GamepadNav  (client)
--   Gaxia.UI.GamepadNav.AutoLink({ btnPlay, btnShop, btnSettings })
--   Gaxia.UI.GamepadNav.Focus(btnPlay)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")

export type Links = { Up: number?, Down: number?, Left: number?, Right: number? }

local GamepadNav = {}

local OFF_AXIS_PENALTY : number = 2

-- ── PURE solver (available on every context, so it's unit-testable) ──
-- Given element centers, return for each index the index to move to in each
-- direction: nearest candidate strictly in that direction, off-axis distance
-- weighted so a same-row/column neighbour beats a diagonal one.
function GamepadNav.SolveLinks(centers: { Vector2 }): { Links }
	local out: { Links } = {}
	for i, c in ipairs(centers) do
		local best: Links = {}
		local score = { Up = math.huge, Down = math.huge, Left = math.huge, Right = math.huge }
		for j, o in ipairs(centers) do
			if i ~= j then
				local dx = o.X - c.X
				local dy = o.Y - c.Y
				if dx > 0 then
					local s = dx + OFF_AXIS_PENALTY * math.abs(dy)
					if s < score.Right then score.Right = s; best.Right = j end
				elseif dx < 0 then
					local s = -dx + OFF_AXIS_PENALTY * math.abs(dy)
					if s < score.Left then score.Left = s; best.Left = j end
				end
				if dy > 0 then
					local s = dy + OFF_AXIS_PENALTY * math.abs(dx)
					if s < score.Down then score.Down = s; best.Down = j end
				elseif dy < 0 then
					local s = -dy + OFF_AXIS_PENALTY * math.abs(dx)
					if s < score.Up then score.Up = s; best.Up = j end
				end
			end
		end
		out[i] = best
	end
	return out
end

-- ── Server stub (focus/input live only on the client; typed as the client
-- module so Gaxia.UI.GamepadNav autocompletes) ──
if not RunService:IsClient() then
	return ({
		SolveLinks = GamepadNav.SolveLinks,
		AutoLink = function() end,
		Focus = function() end,
		Clear = function() end,
		Current = function(): any return nil end,
		IsGamepadActive = function(): boolean return false end,
		OnInputTypeChanged = function(): any return nil end,
	} :: any) :: typeof(GamepadNav)
end

-- ── Client implementation ──
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local GAMEPAD_TYPES: { [Enum.UserInputType]: boolean } = {
	[Enum.UserInputType.Gamepad1] = true,
	[Enum.UserInputType.Gamepad2] = true,
	[Enum.UserInputType.Gamepad3] = true,
	[Enum.UserInputType.Gamepad4] = true,
}

local function centerOf(g: GuiObject): Vector2
	return g.AbsolutePosition + g.AbsoluteSize / 2
end

-- Mark elements Selectable + wire NextSelection* from their on-screen positions.
function GamepadNav.AutoLink(elements: { GuiObject }): ()
	local centers: { Vector2 } = {}
	for i, e in ipairs(elements) do
		e.Selectable = true
		centers[i] = centerOf(e)
	end
	local links = GamepadNav.SolveLinks(centers)
	for i, e in ipairs(elements) do
		local l = links[i]
		e.NextSelectionUp = if l.Up then elements[l.Up] else nil
		e.NextSelectionDown = if l.Down then elements[l.Down] else nil
		e.NextSelectionLeft = if l.Left then elements[l.Left] else nil
		e.NextSelectionRight = if l.Right then elements[l.Right] else nil
	end
end

function GamepadNav.Focus(e: GuiObject): ()
	GuiService.SelectedObject = e
end

function GamepadNav.Clear(): ()
	GuiService.SelectedObject = nil
end

function GamepadNav.Current(): GuiObject?
	return GuiService.SelectedObject
end

function GamepadNav.IsGamepadActive(): boolean
	return GAMEPAD_TYPES[UserInputService:GetLastInputType()] == true
end

-- Fires when the active input device changes; arg is true if it's now a gamepad
-- (use it to show/hide the focus highlight).
function GamepadNav.OnInputTypeChanged(fn: (isGamepad: boolean) -> ()): RBXScriptConnection
	return UserInputService.LastInputTypeChanged:Connect(function(t: Enum.UserInputType)
		fn(GAMEPAD_TYPES[t] == true)
	end)
end

return GamepadNav
