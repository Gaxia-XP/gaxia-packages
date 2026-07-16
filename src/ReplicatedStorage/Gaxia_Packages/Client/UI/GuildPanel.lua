--!strict
-- ─────────────────────────────────────────────────────────────
-- GuildPanel.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/GuildPanel
-- Purpose : Minimal Guild UI — renders the player's current guild header
--           ({Name} [{Tag}]) followed by the member roster, both fetched from
--           the server Guild RemoteFunction (`Events/Guild/Action`, envelopes
--           { type = "get" } and { type = "members" }). Same skeleton as
--           FriendListPanel — only the action calls + row format differ. Tab
--           splits (Overview / Vault / Invites) are layered on top by the host
--           game's UI; the MVP just renders everything in one scroll.
--
-- Access  : Gaxia.UI.GuildPanel  (client)
--   Gaxia.UI.GuildPanel.Open()
--   Gaxia.UI.GuildPanel.Close()
--   Gaxia.UI.GuildPanel.Toggle()
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Panel = {}

if not RunService:IsClient() then
	return (
		{
			Open = function() end,
			Close = function() end,
			Toggle = function() end,
		} :: any
	) :: typeof(Panel)
end

local Theme = require(script.Parent.Parent.Parent.Shared.Theme)

local screenGui: ScreenGui? = nil

local function ensureGui(): ScreenGui
	if screenGui and screenGui.Parent then
		return screenGui
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "GaxiaGuildPanel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	screenGui = gui
	return gui
end

local function rebuild(): ()
	local gui = ensureGui()
	for _, child in ipairs(gui:GetChildren()) do
		child:Destroy()
	end

	local tokens = Theme.Get()
	local surface = tokens.Color.Surface
	local accent = tokens.Color.Primary

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(0, 360, 0, 460)
	frame.Position = UDim2.new(0.5, -180, 0.5, -230)
	frame.BackgroundColor3 = surface
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local events = ReplicatedStorage:WaitForChild("Events", 10)
	local guildFolder = events and events:WaitForChild("Guild", 10)
	local action = guildFolder and guildFolder:WaitForChild("Action", 10) :: RemoteFunction?

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 0, 32)
	title.Position = UDim2.new(0, 8, 0, 6)
	title.BackgroundTransparency = 1
	title.TextColor3 = accent
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.Parent = frame

	if action then
		local ok, g = (action :: RemoteFunction):InvokeServer({ type = "get" })
		if ok and typeof(g) == "table" then
			title.Text = `{g.Name or "Guild"} [{g.Tag or "?"}]`
		else
			title.Text = "No Guild"
		end
	else
		title.Text = "Guild service offline"
	end

	local list = Instance.new("ScrollingFrame")
	list.Size = UDim2.new(1, -16, 1, -52)
	list.Position = UDim2.new(0, 8, 0, 44)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.Parent = list

	if action then
		local ok, members = (action :: RemoteFunction):InvokeServer({ type = "members" })
		if ok and typeof(members) == "table" then
			for _, rec in ipairs(members) do
				local row = Instance.new("TextLabel")
				row.Size = UDim2.new(1, 0, 0, 28)
				row.BackgroundTransparency = 0.85
				row.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
				row.BorderSizePixel = 0
				row.Text = `[{rec.Role or "?"}] {rec.Name or rec.UserId or "?"}`
				row.TextColor3 = Color3.fromRGB(230, 230, 230)
				row.TextXAlignment = Enum.TextXAlignment.Left
				row.Font = Enum.Font.Gotham
				row.TextSize = 14
				row.Parent = list
			end
		end
	end

	local close = Instance.new("TextButton")
	close.Size = UDim2.new(0, 60, 0, 28)
	close.Position = UDim2.new(1, -68, 0, 8)
	close.Text = "Close"
	close.TextColor3 = Color3.fromRGB(240, 240, 240)
	close.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
	close.BorderSizePixel = 0
	close.Font = Enum.Font.Gotham
	close.TextSize = 14
	close.Parent = frame
	close.MouseButton1Click:Connect(function()
		if screenGui then
			screenGui:Destroy()
			screenGui = nil
		end
	end)
end

function Panel.Open(): ()
	rebuild()
end

function Panel.Close(): ()
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
end

function Panel.Toggle(): ()
	if screenGui and screenGui.Parent then
		Panel.Close()
	else
		Panel.Open()
	end
end

return Panel
