local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Economy = GaxiaServer.Economy

Gaxia.Net.OnInvoke("GetCoins", function(player)
	local stats = player:FindFirstChild("leaderstat") -- BUG: typo, stats is nil
	return stats.Coins.Value
end)
