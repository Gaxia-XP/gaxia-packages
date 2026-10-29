local Players = game:GetService("Players")

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(function()
		local backpack = player:WaitForChild("Backpack")
		local sword = backpack:WaitForChild("Sword") :: Tool
		sword.Equipped:Connect(function()
			print(`[Swords] server equipped by {player.Name}`)
		end)
		local swings = 0
		sword.Activated:Connect(function()
			swings += 1
			print(`[Swords] server swing #{swings} by {player.Name}`)
		end)
		local wand = backpack:WaitForChild("Wand") :: Tool
		wand.Activated:Connect(function()
			print("[Swords] server wand activated")
		end)
	end)
end)
