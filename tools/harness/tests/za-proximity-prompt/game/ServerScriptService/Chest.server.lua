local ProximityPromptService = game:GetService("ProximityPromptService")
local chest = workspace:WaitForChild("Chest")
local opens = 0
local openPrompt = chest:WaitForChild("OpenPrompt") :: ProximityPrompt
openPrompt.Triggered:Connect(function(player: Player)
	opens += 1
	print(`[Chest] server opened #{opens} by {player.Name}`)
end)
local lockedPrompt = chest:WaitForChild("LockedPrompt") :: ProximityPrompt
lockedPrompt.Triggered:Connect(function()
	print("[Chest] server locked prompt triggered")
end)
local holdPrompt = chest:WaitForChild("HoldPrompt") :: ProximityPrompt
holdPrompt.PromptButtonHoldBegan:Connect(function(player: Player)
	print(`[Chest] hold began by {player.Name}`)
end)
holdPrompt.Triggered:Connect(function(player: Player)
	print(`[Chest] hold done at {string.format("%.1f", workspace.DistributedGameTime)}`)
end)
ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
	print(`[Service] {prompt.Name} triggered by {player.Name}`)
end)
