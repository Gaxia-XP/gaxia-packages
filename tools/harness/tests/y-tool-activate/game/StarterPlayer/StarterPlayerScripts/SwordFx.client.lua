local player = game:GetService("Players").LocalPlayer
local backpack = player:WaitForChild("Backpack")
local sword = backpack:WaitForChild("Sword") :: Tool
sword.Activated:Connect(function()
	print("[SwordFx] client swing")
end)
sword.Deactivated:Connect(function()
	print("[SwordFx] client release")
end)
local wand = backpack:WaitForChild("Wand") :: Tool
wand.Activated:Connect(function()
	print("[SwordFx] client wand activated")
end)
