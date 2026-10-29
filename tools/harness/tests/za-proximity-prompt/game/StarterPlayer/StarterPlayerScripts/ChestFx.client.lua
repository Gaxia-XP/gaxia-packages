local chest = workspace:WaitForChild("Chest")
local openPrompt = chest:WaitForChild("OpenPrompt") :: ProximityPrompt
openPrompt.Triggered:Connect(function(player: Player)
	print(`[ChestFx] client saw {player.Name}`)
end)
