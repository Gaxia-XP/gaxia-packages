local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Data = GaxiaServer.Data

Players.PlayerAdded:Connect(function(player)
	local visits = Data.Get(player, "Visits") + 1 -- BUG: data is not loaded yet
	Data.Set(player, "Visits", visits)
end)
