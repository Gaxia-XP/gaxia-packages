-- A kill brick: the classic Touched pattern.
local lava = workspace:WaitForChild("Lava") :: BasePart
lava.Touched:Connect(function(hit: BasePart)
	local model = hit.Parent
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")
	if model and humanoid then
		print(`[Lava] server touched by {model.Name}'s {hit.Name}`)
		humanoid.Health = 0
	else
		print(`[Lava] server touched by part {hit.Name}`)
	end
end)
lava.TouchEnded:Connect(function(hit: BasePart)
	print(`[Lava] touch ended by {hit.Name}`)
end)
local ball = workspace:WaitForChild("Ball") :: BasePart
ball.Touched:Connect(function(hit: BasePart)
	print(`[Ball] touched {hit.Name}`)
end)
local ghost = workspace:WaitForChild("Ghost") :: BasePart
ghost.Touched:Connect(function(hit: BasePart)
	print(`[Ghost] touched {hit.Name}`)
end)
