-- Client side: GUI building, remotes, input services. No errors expected.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
assert(Shared.loadedOn == "client" and Shared.counter == 0, "the client has its own copy of the module")

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "Hud"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.fromScale(0.3, 0.1)
frame.Position = UDim2.new(0.5, 0, 0, 10)
frame.AnchorPoint = Vector2.new(0.5, 0)
frame.BackgroundColor3 = Color3.fromHex("#202020")
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke")
stroke.Thickness = 2
stroke.Parent = frame
local list = Instance.new("UIListLayout")
list.FillDirection = Enum.FillDirection.Horizontal
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = frame

local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(1, 1)
label.BackgroundTransparency = 1
label.Font = Enum.Font.GothamBold
label.TextColor3 = Color3.new(1, 1, 1)
label.TextScaled = true
label.Text = "Coins: ..."
label.Parent = frame

local button = Instance.new("TextButton")
button.Text = "Refresh"
button.Parent = frame

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local getCoins = remotes:WaitForChild("GetCoins") :: RemoteFunction
local notify = remotes:WaitForChild("Notify") :: RemoteEvent

notify.OnClientEvent:Connect(function(kind, data)
	assert(kind == "welcome" and data.list[3] == 3)
	label.Text = "Coins: " .. tostring(data.coins)
	TweenService:Create(label, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
end)

button.Activated:Connect(function()
	label.Text = "Coins: " .. tostring(getCoins:InvokeServer())
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.E then
		print("pressed E")
	end
end)

local camera = workspace.CurrentCamera
local frames = 0
RunService.RenderStepped:Connect(function()
	frames += 1
end)

local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid") :: Humanoid
humanoid.Died:Connect(function() end)
task.wait(2)
assert(frames > 60, "RenderStepped runs on the client")
assert(camera.ViewportSize.X > 0)
assert(player.leaderstats.Coins.Value == 50)
assert(player:GetAttribute("Level") == 3)
print("client ok", label.Text, frame.AbsoluteSize.X > 0)
