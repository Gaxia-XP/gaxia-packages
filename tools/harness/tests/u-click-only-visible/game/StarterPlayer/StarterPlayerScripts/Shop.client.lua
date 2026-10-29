local pg = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local gui = Instance.new("ScreenGui")
gui.Name = "Shop"
gui.Parent = pg
local confirm = Instance.new("Frame")
confirm.Name = "Confirm"
confirm.Visible = false
confirm.Parent = gui
local yes = Instance.new("TextButton")
yes.Name = "Yes"
yes.Parent = confirm
local open = Instance.new("TextButton")
open.Name = "Open"
open.Parent = gui
local never = Instance.new("TextButton")
never.Name = "Never"
never.Visible = false
never.Parent = gui
local selected = nil
open.Activated:Connect(function(input, clicks)
	print("open by", input.UserInputType.Name, clicks)
	selected = { price = 10 }
	confirm.Visible = true
end)
yes.MouseButton1Click:Connect(function()
	print("buy", selected.price)
end)
never.MouseButton1Click:Connect(function()
	error("a hidden button was clicked")
end)
