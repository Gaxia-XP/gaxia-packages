local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Pet = GaxiaServer.Pet -- BUG: the Pet package was not picked

Players.PlayerAdded:Connect(function(player)
	Pet.Hatch(player, "BasicEgg")
end)
