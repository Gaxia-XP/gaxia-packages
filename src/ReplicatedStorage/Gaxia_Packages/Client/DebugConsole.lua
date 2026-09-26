--!strict
-- ─────────────────────────────────────────────────────────────
-- Module : DebugConsole
-- Location: ReplicatedStorage/Gaxia_Packages/Client/DebugConsole
-- Purpose : Toggleable on-screen developer overlay (F3 by default)
--           showing FPS, memory, ping, humanoid state, and any
--           user-registered panel.
-- ─────────────────────────────────────────────────────────────

export type DebugConsole = {
	Show         : () -> (),
	Hide         : () -> (),
	Toggle       : () -> (),
	AddPanel     : (name: string, getValue: () -> string) -> (),
	RemovePanel  : (name: string) -> (),
	SetToggleKey : (keyCode: Enum.KeyCode) -> (),
}

local RunService = game:GetService("RunService")

-- ── Server guard: no-op stub on server ──
if not RunService:IsClient() then
	return ({} :: any) :: DebugConsole
end

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local Stats             = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer

-- ── State ──
local toggleKey   : Enum.KeyCode = Enum.KeyCode.F3
local visible     : boolean = false
local screenGui   : ScreenGui? = nil
local rootFrame   : Frame? = nil
local panelOrder  : { string } = {}
local panels      : { [string]: { getValue: () -> string, label: TextLabel? } } = {}

-- ── FPS rolling buffer ──
local FPS_BUFFER_SIZE = 60
local frameDts : { number } = {}
local frameIdx = 0
local frameCount = 0

RunService.Heartbeat:Connect(function(dt: number)
	frameIdx = (frameIdx % FPS_BUFFER_SIZE) + 1
	frameDts[frameIdx] = dt
	if frameCount < FPS_BUFFER_SIZE then frameCount += 1 end
end)

local function getFPS(): number
	if frameCount == 0 then return 0 end
	local sum = 0
	for i = 1, frameCount do sum += frameDts[i] end
	if sum <= 0 then return 0 end
	return math.floor((frameCount / sum) + 0.5)
end

local function getMemMB(): number
	return math.floor(Stats:GetTotalMemoryUsageMb() + 0.5)
end

local function getPingMS(): number
	-- WHY two paths: GetNetworkPing works in live games but may be 0 in Studio;
	-- Stats.Network ServerStatsItem is more reliable while in Studio play.
	local ok, ping = pcall(function()
		return LocalPlayer:GetNetworkPing() * 1000
	end)
	if ok and typeof(ping) == "number" and ping > 0 then
		return math.floor(ping + 0.5)
	end
	local ok2, val = pcall(function()
		local net = Stats.Network
		local server = net:FindFirstChild("ServerStatsItem")
		if not server then return 0 end
		local item = (server :: any):FindFirstChild("Data Ping")
		if not item then return 0 end
		return tonumber((item :: any):GetValueString()) or 0
	end)
	if ok2 and typeof(val) == "number" then return math.floor(val + 0.5) end
	return 0
end

local function getHumanoidState(): string
	local char = LocalPlayer.Character
	if not char then return "—" end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return "—" end
	return tostring(hum:GetState().Name)
end

-- ── UI construction (lazy) ──
local function ensureUI(): ()
	if screenGui then return end
	local playerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local gui = Instance.new("ScreenGui")
	gui.Name = "GaxiaDebugConsole"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.Enabled = false
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Root"
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = UDim2.new(0, 8, 0, 8)
	frame.Size = UDim2.new(0, 220, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 0.35
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local pad = Instance.new("UIPadding")
	pad.PaddingTop    = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft   = UDim.new(0, 8)
	pad.PaddingRight  = UDim.new(0, 8)
	pad.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = frame

	screenGui = gui
	rootFrame = frame
end

local function ensurePanelLabel(name: string): TextLabel?
	local p = panels[name]
	if not p then return nil end
	if p.label then return p.label end
	ensureUI()
	if not rootFrame then return nil end
	local lbl = Instance.new("TextLabel")
	lbl.Name = `Panel_{name}`
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, 0, 0, 16)
	lbl.Font = Enum.Font.Code
	lbl.TextSize = 14
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = `{name}: …`
	lbl.LayoutOrder = #panelOrder
	lbl.Parent = rootFrame
	p.label = lbl
	return lbl
end

-- ── Public API ──
local DebugConsole = {}

function DebugConsole.AddPanel(name: string, getValue: () -> string): ()
	if panels[name] then
		panels[name].getValue = getValue
		return
	end
	panels[name] = { getValue = getValue, label = nil }
	table.insert(panelOrder, name)
	if visible then ensurePanelLabel(name) end
end

function DebugConsole.RemovePanel(name: string): ()
	local p = panels[name]
	if not p then return end
	if p.label then p.label:Destroy() end
	panels[name] = nil
	for i, n in panelOrder do
		if n == name then table.remove(panelOrder, i); break end
	end
end

function DebugConsole.Show(): ()
	ensureUI()
	if screenGui then screenGui.Enabled = true end
	visible = true
	for _, name in panelOrder do ensurePanelLabel(name) end
end

function DebugConsole.Hide(): ()
	if screenGui then screenGui.Enabled = false end
	visible = false
end

function DebugConsole.Toggle(): ()
	if visible then DebugConsole.Hide() else DebugConsole.Show() end
end

function DebugConsole.SetToggleKey(keyCode: Enum.KeyCode): ()
	toggleKey = keyCode
end

-- ── Register built-in panels ──
DebugConsole.AddPanel("FPS",   function(): string return `FPS:   {getFPS()}` end)
DebugConsole.AddPanel("Mem",   function(): string return `Mem:   {getMemMB()} MB` end)
DebugConsole.AddPanel("Ping",  function(): string return `Ping:  {getPingMS()} ms` end)
DebugConsole.AddPanel("State", function(): string return `State: {getHumanoidState()}` end)

-- ── Input + render loop ──
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then return end
	if input.KeyCode == toggleKey then
		DebugConsole.Toggle()
	end
end)

-- WHY RenderStepped not Heartbeat for label refresh: panel text is purely
-- visual; updating in-step with the frame avoids 1-frame staleness.
RunService.RenderStepped:Connect(function(_dt: number)
	if not visible then return end
	for _, name in panelOrder do
		local p = panels[name]
		if p and p.label then
			local ok, txt = pcall(p.getValue)
			p.label.Text = ok and tostring(txt) or `{name}: <err>`
		end
	end
end)

return DebugConsole :: DebugConsole
