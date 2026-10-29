local Players = game:GetService("Players")
Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		-- a ForceField with any name protects the character (Roblox checks the class)
		local shield = Instance.new("ForceField")
		shield.Name = "SpawnShield"
		shield.Parent = character
		humanoid:TakeDamage(30)
		print(`[Shield] shielded health {humanoid.Health}`)
		shield:Destroy()
		-- a Part named "ForceField" is not a force field
		local fake = Instance.new("Part")
		fake.Name = "ForceField"
		fake.Parent = character
		humanoid:TakeDamage(30)
		print(`[Shield] fake-shield health {humanoid.Health}`)
	end)
end)
