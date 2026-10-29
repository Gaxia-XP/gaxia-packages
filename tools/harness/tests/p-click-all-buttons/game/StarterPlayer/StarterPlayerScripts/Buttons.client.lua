local Players = game:GetService("Players")

local gui = Instance.new("ScreenGui")
gui.Name = "ShopGui"
local ok = Instance.new("TextButton")
ok.Name = "Ok"
ok.Text = "Ok"
ok.Parent = gui
ok.Activated:Connect(function()
	print("[Buttons] ok clicked")
end)
local broken = Instance.new("TextButton")
broken.Name = "Broken"
broken.Text = "Broken"
broken.Parent = gui
broken.MouseButton1Click:Connect(function()
	local item = nil
	print(item.Price) -- the bug a click finds
end)
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
