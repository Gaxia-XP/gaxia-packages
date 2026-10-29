local player = game:GetService("Players").LocalPlayer
local coins = player:WaitForChild("leaderstats"):WaitForChild("Coins") :: IntValue
coins.Value = 999999
player:SetAttribute("Gems", 500)
print("client sees", coins.Value, player:GetAttribute("Gems"))
task.wait(5)
print("client later sees", coins.Value)
