--!strict
-- ─────────────────────────────────────────────────────────────
-- GuildPanel.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/GuildPanel
-- Purpose : Minimal Guild UI — renders the player's current guild header
--           ({Name} [{Tag}]) followed by the member roster, both fetched from
--           the logical Guild.Get and Guild.Members gateway RPCs. Same skeleton as
--           FriendListPanel — only the action calls + row format differ. Tab
--           splits (Overview / Vault / Invites) are layered on top by the host
--           game's UI; the MVP just renders everything in one scroll.
--
-- Access  : Gaxia.UI.GuildPanel  (client)
--   Gaxia.UI.GuildPanel.Open()
--   Gaxia.UI.GuildPanel.Close()
--   Gaxia.UI.GuildPanel.Toggle()
-- ─────────────────────────────────────────────────────────────
local Players = game:GetService("Players")
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
local SharedPkg = require(script.Parent.Parent.Parent) :: any
local Net = SharedPkg.Net

local screenGui: ScreenGui? = nil

-- Keeps the UI's existing (ok, data) call convention while the gateway adds
-- its outer transport result ({ ok, data | code }).
local function invoke(name: string, payload: any): (boolean, any)
	local called, response = pcall(function()
		return Net.Client.Invoke(name, payload)
	end)
	if not called or typeof(response) ~= "table" then
		return false, "guild service offline"
	end
	if response.ok ~= true then
		return false, response.code or "guild request rejected"
	end
	local result = response.data
	if typeof(result) ~= "table" or typeof(result.ok) ~= "boolean" then
		return false, "guild service returned an invalid response"
	end
	return result.ok, result.data
end

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

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 0, 32)
	title.Position = UDim2.new(0, 8, 0, 6)
	title.BackgroundTransparency = 1
	title.TextColor3 = accent
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.Parent = frame

	local ok, g = invoke("Guild.Get", {})
	if ok and typeof(g) == "table" then
		title.Text = `{g.Name or "Guild"} [{g.Tag or "?"}]`
	else
		title.Text = "No Guild"
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

	local membersOk, members = invoke("Guild.Members", {})
	if membersOk and typeof(members) == "table" then
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
