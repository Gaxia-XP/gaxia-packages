--!strict
-- ──────────────────────────────────────────────────────────────────
--  TooltipSystem.lua
--  Location: ReplicatedStorage/Gaxia_Packages/Client/TooltipSystem
--  Purpose:  Hover-triggered tooltips with delay + cursor follow.
--            Single global tooltip moved between targets.
-- ──────────────────────────────────────────────────────────────────

export type TooltipSystem = {
	Attach: (target: GuiObject, text: string | () -> string) -> (),
	Detach: (target: GuiObject) -> (),
	SetDelay: (seconds: number) -> (),
}

local RunService = game:GetService("RunService")
if not RunService:IsClient() then return ({} :: any) :: TooltipSystem end

local CollectionService = game:GetService("CollectionService")

-- ── Services ──
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local StarterGui        = game:GetService("StarterGui")

local LocalPlayer : Player = Players.LocalPlayer
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Maid = SharedPkg.Maid

-- ── Constants ──
local DEFAULT_DELAY : number = 0.5
local CURSOR_OFFSET : Vector2 = Vector2.new(16, 16)
local UI_ROOT_NAME : string = "Gaxia_UI"
local OVERLAY_FOLDER_NAME : string = "Overlays"

-- ── State ──
local Module = {}

type Entry = {
	target : GuiObject,
	getText : () -> string,
	maid : any,
}

local _entries : { [GuiObject]: Entry } = {}
local _delay : number = DEFAULT_DELAY
local _tooltipFrame : Frame? = nil
local _tooltipLabel : TextLabel? = nil
local _activeTarget : GuiObject? = nil
local _hoverToken : number = 0
local _moveConn : RBXScriptConnection? = nil

-- ── Helpers ──

local function getOverlays(): Instance
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local uiRoot = pg:FindFirstChild(UI_ROOT_NAME)
	if not uiRoot then
		local sg = Instance.new("ScreenGui")
		sg.Name = UI_ROOT_NAME
		sg.ResetOnSpawn = false
		sg.IgnoreGuiInset = true
		sg.DisplayOrder = 1000
		sg.Parent = pg
		uiRoot = sg
	end
	local overlays = uiRoot:FindFirstChild(OVERLAY_FOLDER_NAME)
	if not overlays then
		local f = Instance.new("Folder")
		f.Name = OVERLAY_FOLDER_NAME
		f.Parent = uiRoot
		overlays = f
	end
	return overlays :: Instance
end

local function findTemplate(): GuiObject?
	local sg = StarterGui:FindFirstChild(UI_ROOT_NAME)
	if not sg then return nil end
	local templates = sg:FindFirstChild("Templates")
	if not templates then return nil end
	local tmpl = templates:FindFirstChild("TooltipTemplate")
	if tmpl and tmpl:IsA("GuiObject") then
		return tmpl
	end
	return nil
end

local function buildFallback(): Frame
	local frame = Instance.new("Frame")
	frame.Name = "TooltipTemplate"
	frame.Size = UDim2.new(0, 200, 0, 40)
	frame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.ZIndex = 100

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 140, 200)
	stroke.Thickness = 1
	stroke.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(0, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(240, 240, 240)
	label.Font = Enum.Font.Gotham
	label.TextSize = 14
	label.TextWrapped = false
	label.RichText = false
	label.Text = ""
	label.ZIndex = 101
	label.Parent = frame

	return frame
end

-- WHY: lazily build the global tooltip instance
local function ensureTooltip(): (Frame, TextLabel)
	if _tooltipFrame and _tooltipFrame.Parent and _tooltipLabel then
		return _tooltipFrame, _tooltipLabel
	end
	local tmpl = findTemplate()
	local frame : GuiObject
	if tmpl then
		frame = tmpl:Clone()
	else
		frame = buildFallback()
	end
	frame.Visible = false
	frame.Parent = getOverlays()

	local label = frame:FindFirstChild("Label")
	if not (label and label:IsA("TextLabel")) then
		-- fallback: find first TextLabel descendant
		for _, d in ipairs(frame:GetDescendants()) do
			if d:IsA("TextLabel") then
				label = d
				break
			end
		end
	end
	if not (label and label:IsA("TextLabel")) then
		-- inject one
		local nl = Instance.new("TextLabel")
		nl.Name = "Label"
		nl.BackgroundTransparency = 1
		nl.AutomaticSize = Enum.AutomaticSize.XY
		nl.TextColor3 = Color3.fromRGB(240, 240, 240)
		nl.Font = Enum.Font.Gotham
		nl.TextSize = 14
		nl.Parent = frame
		label = nl
	end

	_tooltipFrame = frame :: Frame
	_tooltipLabel = label :: TextLabel
	return _tooltipFrame :: Frame, _tooltipLabel :: TextLabel
end

-- WHY: reposition while keeping tooltip on-screen
local function repositionTo(frame: Frame, mousePos: Vector2): ()
	local cam = workspace.CurrentCamera
	local viewport = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	local absSize = frame.AbsoluteSize
	local x = mousePos.X + CURSOR_OFFSET.X
	local y = mousePos.Y + CURSOR_OFFSET.Y
	if x + absSize.X > viewport.X then
		x = mousePos.X - absSize.X - CURSOR_OFFSET.X
	end
	if y + absSize.Y > viewport.Y then
		y = mousePos.Y - absSize.Y - CURSOR_OFFSET.Y
	end
	if x < 0 then x = 0 end
	if y < 0 then y = 0 end
	frame.Position = UDim2.new(0, x, 0, y)
end

local function hideTooltip(): ()
	_activeTarget = nil
	_hoverToken += 1
	if _moveConn then
		_moveConn:Disconnect()
		_moveConn = nil
	end
	if _tooltipFrame then
		_tooltipFrame.Visible = false
	end
end

local function showFor(target: GuiObject, entry: Entry): ()
	local frame, label = ensureTooltip()
	local text = entry.getText()
	if text == "" then return end
	label.Text = text
	frame.Visible = true
	_activeTarget = target

	local mousePos = UserInputService:GetMouseLocation()
	-- WHY: defer one frame so AutomaticSize updates AbsoluteSize before repositioning
	task.defer(function()
		if _activeTarget == target and _tooltipFrame then
			repositionTo(_tooltipFrame, UserInputService:GetMouseLocation())
		end
	end)
	repositionTo(frame, mousePos)

	if _moveConn then _moveConn:Disconnect() end
	_moveConn = UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			if _tooltipFrame and _activeTarget == target then
				repositionTo(_tooltipFrame, UserInputService:GetMouseLocation())
			end
		end
	end)
end

-- ── Public API ──

function Module.SetDelay(seconds: number): ()
	_delay = math.max(0, seconds)
end

function Module.Attach(target: GuiObject, text: string | () -> string): ()
	-- WHY: replace any previous attachment cleanly
	if _entries[target] then
		Module.Detach(target)
	end

	local getText : () -> string
	if type(text) == "function" then
		getText = text :: () -> string
	else
		local s : string = text :: string
		getText = function(): string return s end
	end

	local maid = Maid.new()
	local entry : Entry = {
		target = target,
		getText = getText,
		maid = maid,
	}
	_entries[target] = entry

	local enterConn = target.MouseEnter:Connect(function()
		_hoverToken += 1
		local token = _hoverToken
		local waitFor = _delay
		task.spawn(function()
			task.wait(waitFor)
			if token == _hoverToken and _entries[target] then
				showFor(target, entry)
			end
		end)
	end)
	maid:GiveTask(enterConn)

	local leaveConn = target.MouseLeave:Connect(function()
		if _activeTarget == target then
			hideTooltip()
		else
			_hoverToken += 1
		end
	end)
	maid:GiveTask(leaveConn)

	local destroyConn = target.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			Module.Detach(target)
		end
	end)
	maid:GiveTask(destroyConn)
end

function Module.Detach(target: GuiObject): ()
	local entry = _entries[target]
	if not entry then return end
	if _activeTarget == target then
		hideTooltip()
	end
	entry.maid:Destroy()
	_entries[target] = nil
end

return Module :: TooltipSystem
