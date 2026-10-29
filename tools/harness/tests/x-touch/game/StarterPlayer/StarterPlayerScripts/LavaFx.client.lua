local lava = workspace:WaitForChild("Lava") :: BasePart
lava.Touched:Connect(function(hit: BasePart)
	print(`[LavaFx] client saw {hit.Name}`)
end)
