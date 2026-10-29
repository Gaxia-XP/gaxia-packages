-- Kicks every player who joins.
local Players = game:GetService("Players")
Players.PlayerAdded:Connect(function(player)
	task.wait(1)
	player:Kick("Server is full")
end)
Players.PlayerRemoving:Connect(function(player)
	print("removing", player.Name)
end)
