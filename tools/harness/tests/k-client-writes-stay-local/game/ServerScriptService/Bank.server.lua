-- The server owns the coin value. A client that changes it changes only its own copy.
local Players = game:GetService("Players")
Players.PlayerAdded:Connect(function(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = 10
	coins.Parent = leaderstats
	leaderstats.Parent = player
	player:SetAttribute("Gems", 1)
	task.wait(3)
	print("server sees", coins.Value, player:GetAttribute("Gems"))
	coins.Value = 20 -- a server write replicates over the client's copy
end)
